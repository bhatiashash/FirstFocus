import FirstFocusApp
import FirstFocusCore
import Foundation
import SQLite3

private func feedbackSQL(_ app: HistoryApp, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(app.correctionsPath, &database) == SQLITE_OK, let database else {
        throw TestFailure(message: "Cannot open fixture database")
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw TestFailure(message: String(cString: sqlite3_errmsg(database)))
    }
}

@MainActor
private func feedbackFixture() throws -> (HistoryApp, HistoryBatch, Signal) {
    let app = makeHistoryApp()
    let suggestion = Signal(
        id: "feedback-one", source: .messages, sourceRef: "feedback-batch", label: "Call dentist",
        originalText: "Call dentist", createdAt: Date(), provenance: .inferred
    )
    let second = Signal(
        id: "feedback-two", source: .messages, sourceRef: "feedback-batch", label: "Book taxi",
        originalText: "Book taxi", createdAt: Date(), provenance: .inferred
    )
    let other = Signal(
        id: "feedback-other", source: .messages, sourceRef: "other-batch", label: "Other task",
        originalText: "Other task", createdAt: Date(), provenance: .inferred
    )
    try app.signals.recordOneMessageBatch("feedback-batch", signals: [suggestion, second])
    try app.signals.recordOneMessageBatch("other-batch", signals: [other])
    let row = HistoryEntry(
        sourceRawText: "Call dentist", rawOutput: "Call dentist", modelUsed: "Test", signalCount: 1,
        chatId: 42, renderedContext: "Call dentist", sourceRef: "feedback-batch"
    )
    try app.history.record(row)
    _ = app.corrections.correctionTypes(forSourceRefs: ["feedback-batch"])
    return (app, historyBatch(row), suggestion)
}

func registerFeedbackPersistenceTests(_ runner: TestRunner) {
    runner.suite("Durable feedback through AppModel and History") { suite in
        for caller in ["Inbox", "History"] {
            for failure in ["correction", "dismissal", "second-dismissal"] {
                suite.run("\(caller) rolls back \(failure) failure without an Undo offer") {
                    let (app, batch, suggestion) = try await MainActor.run { try feedbackFixture() }
                    await app.model.start()
                    let trigger: String
                    switch failure {
                    case "correction": trigger = "BEFORE INSERT ON corrections"
                    case "dismissal": trigger = "BEFORE UPDATE OF state ON signals WHEN NEW.state = 'dismissed'"
                    default: trigger = "BEFORE UPDATE OF state ON signals WHEN NEW.state = 'dismissed' AND NEW.id = 'feedback-two'"
                    }
                    try feedbackSQL(app, "CREATE TRIGGER fail_feedback \(trigger) BEGIN SELECT RAISE(ABORT, 'injected'); END")
                    try await MainActor.run {
                        let before = app.model.rankedList.suggested.map(\.id).sorted()
                        if caller == "Inbox" { app.model.notForMe(suggestion) }
                        else { app.actions.notForMe(batch) }
                        try expect(app.model.corrections.types(forBatches: ["feedback-batch"]).isEmpty)
                        try expect(app.signals.openSignals().count == 3)
                        try expect(app.model.rankedList.suggested.map(\.id).sorted() == before)
                        try expect(app.model.undoOffer == nil)
                        try expect(app.model.failures.count == 1)
                    }
                    try feedbackSQL(app, "DROP TRIGGER fail_feedback")
                    try await MainActor.run {
                        app.model.retryFailure(app.model.failures[0].id)
                        try expect(app.model.failures.isEmpty)
                        try expect(app.signals.openSignals().map(\.id) == ["feedback-other"])
                        if caller == "Inbox" { try expect(app.model.undoOffer?.action == .notForMe) }
                    }
                }
            }
        }
        suite.run("Undo reopen failure rolls back the Correction delete") {
            let (app, batch, suggestion) = try await MainActor.run { try feedbackFixture() }
            await app.model.start()
            await MainActor.run { app.model.notForMe(suggestion) }
            try feedbackSQL(app, "CREATE TRIGGER fail_reopen BEFORE UPDATE OF state ON signals WHEN NEW.state = 'open' BEGIN SELECT RAISE(ABORT, 'injected'); END")
            try await MainActor.run {
                app.actions.undoNotForMe(batch)
                try expect(app.model.corrections.types(forBatches: ["feedback-batch"]) == ["feedback-batch": [.falsePositive]])
                try expect(app.signals.openSignals().map(\.id) == ["feedback-other"])
            }
            try feedbackSQL(app, "DROP TRIGGER fail_reopen")
            await app.undoAlarm.fire()
            try await MainActor.run {
                app.model.retryFailure(app.model.failures[0].id)
                try expect(app.model.failures.isEmpty)
                try expect(app.signals.openSignals().count == 3)
                try expect(app.model.corrections.types(forBatches: ["feedback-batch"]).isEmpty)
            }
        }
        for intent in ["approval", "checkoff", "dismissal", "reopen-redismiss", "reextraction", "new-feedback"] {
            suite.run("Undo preserves later \(intent), including across reload") {
                let (app, batch, suggestion) = try await MainActor.run { try feedbackFixture() }
                await app.model.start()
                try await MainActor.run {
                    app.model.notForMe(suggestion)
                    switch intent {
                    case "approval": try app.signals.approve(signalId: suggestion.id, reminderId: "new-reminder")
                    case "checkoff": try app.signals.checkOff(signalId: suggestion.id)
                    case "dismissal": try app.signals.dismiss(signalId: suggestion.id)
                    case "reopen-redismiss":
                        try app.signals.reopen(signalId: suggestion.id)
                        try app.signals.dismissByNotForMe(signalId: suggestion.id)
                    case "reextraction":
                        try app.signals.recordReExtractedSignals(sourceRef: suggestion.sourceRef, signals: [Signal(
                            id: "new-suggestion", source: .messages, sourceRef: suggestion.sourceRef, label: "New task",
                            originalText: "New task", createdAt: Date(), provenance: .inferred
                        )])
                    default:
                        try app.corrections.replace(Correction(
                            chatId: 42, sourceRef: suggestion.sourceRef, inputText: "new feedback", correctedOutput: "NONE",
                            correctionType: .falsePositive
                        ))
                    }
                }
                if intent == "new-feedback" {
                    await app.model.undo()
                    try await MainActor.run {
                        try expect(app.model.corrections.falsePositives(since: nil).first?.inputText == "new feedback")
                        try expect(app.signals.openSignals().map(\.id) == ["feedback-other"])
                    }
                } else {
                    let fresh = await MainActor.run { makeHistoryApp(signals: app.signals, history: app.history) }
                    await fresh.model.start()
                    try await MainActor.run {
                        fresh.actions.undoNotForMe(batch)
                        let open = Set(app.signals.openSignals().map(\.id))
                        try expect(open.contains("feedback-two") && open.contains("feedback-other"))
                        try expect(open.contains(suggestion.id) == (intent == "reextraction"))
                        if intent == "reextraction" { try expect(open.contains("new-suggestion")) }
                    }
                }
            }
            suite.run("failed mark Retry does not replay past newer \(intent)") {
                let (app, batch, suggestion) = try await MainActor.run { try feedbackFixture() }
                await app.model.start()
                try feedbackSQL(app, "CREATE TRIGGER fail_feedback BEFORE INSERT ON corrections BEGIN SELECT RAISE(ABORT, 'injected'); END")
                await MainActor.run { app.model.notForMe(suggestion) }
                try feedbackSQL(app, "DROP TRIGGER fail_feedback")
                try await MainActor.run {
                    let failure = try require(app.model.failures.first, "failure must offer Retry")
                    switch intent {
                    case "approval": try app.signals.approve(signalId: suggestion.id, reminderId: "r")
                    case "checkoff": try app.signals.checkOff(signalId: suggestion.id)
                    case "dismissal": try app.signals.dismiss(signalId: suggestion.id)
                    case "reopen-redismiss":
                        try app.signals.dismiss(signalId: suggestion.id)
                        try app.signals.reopen(signalId: suggestion.id)
                        try app.signals.dismiss(signalId: suggestion.id)
                    case "reextraction":
                        try app.signals.recordReExtractedSignals(sourceRef: suggestion.sourceRef, signals: [Signal(
                            id: "new-suggestion", source: .messages, sourceRef: suggestion.sourceRef, label: "New task",
                            originalText: "New task", createdAt: Date(), provenance: .inferred
                        )])
                    default: app.actions.notForMe(batch)
                    }
                    app.model.retryFailure(failure.id)
                    try expect(app.model.undoOffer == nil)
                    if intent != "new-feedback" {
                        try expect(app.model.corrections.types(forBatches: [suggestion.sourceRef]).isEmpty)
                        try expect(app.signals.openSignals().contains { $0.id == "feedback-two" })
                    }
                    try expect(app.signals.openSignals().contains { $0.id == "feedback-other" })
                }
            }
        }
        suite.run("failed Undo remains retryable after its Undo bar clears") {
            let (app, _, suggestion) = try await MainActor.run { try feedbackFixture() }
            await app.model.start()
            await MainActor.run { app.model.notForMe(suggestion) }
            try feedbackSQL(app, "CREATE TRIGGER fail_reopen BEFORE UPDATE OF state ON signals WHEN NEW.state = 'open' BEGIN SELECT RAISE(ABORT, 'injected'); END")
            await app.model.undo()
            try await MainActor.run {
                try expect(app.model.undoOffer == nil)
                try expect(app.model.failures.count == 1)
            }
            try feedbackSQL(app, "DROP TRIGGER fail_reopen")
            try await MainActor.run {
                app.model.retryFailure(app.model.failures[0].id)
                try expect(app.signals.openSignals().count == 3)
                try expect(app.model.failures.isEmpty)
            }
        }
        suite.run("failed Undo Retry respects approvals and dismissals made after failure") {
            let (app, _, suggestion) = try await MainActor.run { try feedbackFixture() }
            await app.model.start()
            await MainActor.run { app.model.notForMe(suggestion) }
            try feedbackSQL(app, "CREATE TRIGGER fail_reopen BEFORE UPDATE OF state ON signals WHEN NEW.state = 'open' AND NEW.id = 'feedback-two' BEGIN SELECT RAISE(ABORT, 'injected'); END")
            await app.model.undo()
            try await MainActor.run {
                try expect(app.signals.openSignals().map(\.id) == ["feedback-other"], "even the first reopen must roll back")
                try expect(!app.model.corrections.types(forBatches: [suggestion.sourceRef]).isEmpty)
            }
            try feedbackSQL(app, "DROP TRIGGER fail_reopen")
            try app.signals.approve(signalId: suggestion.id, reminderId: "later-approved")
            try app.signals.dismiss(signalId: "feedback-two")
            try await MainActor.run {
                app.model.retryFailure(app.model.failures[0].id)
                try expect(app.model.failures.isEmpty)
                try expect(app.signals.openSignals().map(\.id) == ["feedback-other"])
                try expect(app.model.corrections.types(forBatches: [suggestion.sourceRef]).isEmpty)
            }
        }
        suite.run("old Undo cannot erase a newer action on the same Batch") {
            let (app, batch, suggestion) = try await MainActor.run { try feedbackFixture() }
            await app.model.start()
            await MainActor.run {
                app.model.notForMe(suggestion)
                app.actions.undoNotForMe(batch)
                app.actions.notForMe(batch)
            }
            await app.model.undo()
            try await MainActor.run {
                try expect(app.signals.openSignals().map(\.id) == ["feedback-other"])
                try expect(!app.model.corrections.types(forBatches: [suggestion.sourceRef]).isEmpty)
            }
        }
        suite.run("Retry withdraws feedback when eligibility changes or History is replaced or deleted") {
            for change in ["missed-task", "rerun", "deleted"] {
                let (app, batch, _) = try await MainActor.run { try feedbackFixture() }
                await app.model.start()
                try feedbackSQL(app, "CREATE TRIGGER fail_feedback BEFORE INSERT ON corrections BEGIN SELECT RAISE(ABORT, 'injected'); END")
                await MainActor.run { app.actions.notForMe(batch) }
                try feedbackSQL(app, "DROP TRIGGER fail_feedback")
                if change == "missed-task" {
                    try app.corrections.record(Correction(
                        chatId: 42, sourceRef: "feedback-batch", inputText: "actually work", correctedOutput: "Task",
                        correctionType: .missedTask
                    ))
                } else if change == "deleted" {
                    try app.history.delete(sourceRef: "feedback-batch")
                } else {
                    try app.history.record(HistoryEntry(
                        sourceRawText: "Call dentist", rawOutput: "NONE", modelUsed: "New model", signalCount: 0,
                        chatId: 42, kind: .rerun, sourceRef: "feedback-batch"
                    ))
                }
                try await MainActor.run {
                    app.model.retryFailure(app.model.failures[0].id)
                    try expect(app.signals.openSignals().count == 3)
                    try expect(!app.model.corrections.types(forBatches: ["feedback-batch"])["feedback-batch", default: []].contains(.falsePositive))
                    try expect(app.model.failures.first?.canRetry == false)
                    app.model.dismissFailure(app.model.failures[0].id)
                    try expect(app.model.failures.isEmpty)
                }
            }
        }
        suite.run("legacy dismissal markers remain undoable but unmarked dismissals stay dismissed") {
            let (app, batch, suggestion) = try await MainActor.run { try feedbackFixture() }
            try app.corrections.record(Correction(
                chatId: 42, sourceRef: suggestion.sourceRef, inputText: "legacy", correctedOutput: "NONE",
                correctionType: .falsePositive
            ))
            try app.signals.dismissByNotForMe(signalId: suggestion.id)
            try app.signals.dismiss(signalId: "feedback-two")
            await app.model.start()
            try await MainActor.run {
                app.actions.undoNotForMe(batch)
                try expect(Set(app.signals.openSignals().map(\.id)) == [suggestion.id, "feedback-other"])
                try expect(app.model.corrections.types(forBatches: [suggestion.sourceRef]).isEmpty)
            }
        }
        suite.run("feedback only dismisses open inferred Suggestions") {
            let (app, batch, suggestion) = try await MainActor.run { try feedbackFixture() }
            try app.signals.approve(signalId: "feedback-two", reminderId: "already-approved")
            try app.signals.recordReExtractedSignals(sourceRef: suggestion.sourceRef, signals: [Signal(
                id: "stated-signal", source: .messages, sourceRef: suggestion.sourceRef, label: "Explicit task",
                originalText: "Explicit task", createdAt: Date(), provenance: .stated
            )])
            await app.model.start()
            try await MainActor.run {
                app.actions.notForMe(batch)
                try expect(Set(app.signals.openSignals().map(\.id)) == ["stated-signal", "feedback-other"])
                app.actions.undoNotForMe(batch)
                try expect(Set(app.signals.openSignals().map(\.id)) == ["stated-signal", "feedback-other", suggestion.id])
            }
        }
        suite.run("unreadable feedback Retry refreshes without replaying unverified intent") {
            let (app, batch, suggestion) = try await MainActor.run { try feedbackFixture() }
            await app.model.start()
            let viewModel = await MainActor.run { app.viewModel() }
            let before = await MainActor.run { viewModel.batches }
            let path = app.correctionsPath
            let backup = path + ".saved"
            try FileManager.default.moveItem(atPath: path, toPath: backup)
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            defer {
                if FileManager.default.fileExists(atPath: backup) {
                    try? FileManager.default.removeItem(atPath: path)
                    try? FileManager.default.moveItem(atPath: backup, toPath: path)
                }
            }
            await MainActor.run { app.actions.notForMe(batch) }
            try await MainActor.run {
                try expect(viewModel.batches == before, "a read failure must not clear History's cached rows")
                try expect(app.model.rankedList.suggested.count == 3)
            }
            try FileManager.default.removeItem(atPath: path)
            try FileManager.default.moveItem(atPath: backup, toPath: path)
            try app.signals.approve(signalId: suggestion.id, reminderId: "newer-intent")
            try await MainActor.run {
                let failure = try require(app.model.failures.first)
                try expect(failure.canRetry)
                app.model.retryFailure(failure.id)
                try expect(app.model.failures.isEmpty)
                try expect(app.model.corrections.types(forBatches: [suggestion.sourceRef]).isEmpty)
                try expect(Set(app.signals.openSignals().map(\.id)) == ["feedback-other", "feedback-two"])
                try expect(app.model.undoOffer == nil)
            }
        }
    }
}
