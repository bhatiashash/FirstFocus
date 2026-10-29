import DailyOSApp
import DailyOSCore
import Foundation

/// history-snapshot: which actions a History Batch offers, worked out from
/// the Batch and the facts History read about it. No stores.

private let chatId = 1

private func transcript(_ text: String) -> [HistoryTranscriptLine] {
    [HistoryTranscriptLine(speaker: "Mom", isFromMe: false, text: text, sentAt: Date())]
}

private func modelRow(_ sourceRef: String, output: String, chatId: Int? = chatId) -> HistoryEntry {
    HistoryEntry(
        timestamp: Date(), sourceRawText: "text", rawOutput: output, modelUsed: "Q",
        signalCount: output == "NONE" ? 0 : 1, chatId: chatId, sourceRef: sourceRef, sender: "Mom",
        transcript: transcript("text")
    )
}

private func screenedRow(_ sourceRef: String) -> HistoryEntry {
    HistoryEntry(
        timestamp: Date(), sourceRawText: "text", modelUsed: "JEV", signalCount: 0, chatId: chatId,
        kind: .screening(ScreeningDecision(probability: 0.1, mode: .live(cutoff: 0.4))),
        sourceRef: sourceRef, sender: "Mom", transcript: transcript("text")
    )
}

private let taskBatch = historyBatch(modelRow("task", output: "Call the dentist"))
private let noneBatch = historyBatch(modelRow("none", output: "NONE"))
private let screenedBatch = historyBatch(screenedRow("screened"))

private func facts(
    showsScreening: Bool = true, isModelLoaded: Bool = true, corrections: [String: Set<CorrectionType>] = [:],
    supersessions: [String: [RecordedSupersession]] = [:], mutedChats: Set<Int> = []
) -> HistoryFacts {
    HistoryFacts(
        showsScreening: showsScreening, isModelLoaded: isModelLoaded, correctionTypes: corrections,
        supersessions: supersessions, mutedChats: mutedChats
    )
}

func registerHistoryOffersTests(_ runner: TestRunner) {
    runner.suite("history-snapshot: what a Batch offers, from the facts") { r in
        r.run("a Batch with a task offers Not for me, Re-run and Mute") {
            let offers = historyBatchOffers(for: taskBatch, facts: facts())
            try expect(offers[.notForMe] == .enabled)
            try expect(offers[.rerun] == .enabled)
            try expect(offers[.mute] == .enabled)
            try expect(offers[.addTask] == nil && offers[.thisWasWork] == nil && offers[.restore] == nil)
        }

        r.run("Not for me shows as taken once the Batch has a false positive") {
            let offers = historyBatchOffers(for: taskBatch, facts: facts(corrections: ["task": [.falsePositive]]))
            try expect(offers[.notForMe] == .taken)
        }

        r.run("a missed task on the Batch withdraws Not for me") {
            let offers = historyBatchOffers(for: taskBatch, facts: facts(corrections: ["task": [.missedTask]]))
            try expect(offers[.notForMe] == nil)
        }

        r.run("a Batch the model found nothing in offers Add task, taken once added") {
            try expect(historyBatchOffers(for: noneBatch, facts: facts())[.addTask] == .enabled)
            try expect(historyBatchOffers(for: noneBatch, facts: facts(corrections: ["none": [.missedTask]]))[.addTask] == .taken)
        }

        r.run("a Screened Batch offers This was work with the toggle on, and Add task with it off") {
            let on = historyBatchOffers(for: screenedBatch, facts: facts(showsScreening: true))
            try expect(on[.thisWasWork] == .enabled && on[.addTask] == nil)
            let off = historyBatchOffers(for: screenedBatch, facts: facts(showsScreening: false))
            try expect(off[.thisWasWork] == nil && off[.addTask] == .enabled)
        }

        r.run("with no model loaded, This was work and Re-run are disabled with the reason, and Add task isn't") {
            let noModel = HistoryActionState.unavailable(reason: noModelLoadedReason)
            try expect(historyBatchOffers(for: screenedBatch, facts: facts(isModelLoaded: false))[.thisWasWork] == noModel)
            try expect(historyBatchOffers(for: noneBatch, facts: facts(isModelLoaded: false))[.rerun] == noModel)
            try expect(historyBatchOffers(for: noneBatch, facts: facts(isModelLoaded: false))[.addTask] == .enabled)
        }

        r.run("Restore is offered while something the Batch Superseded can come back") {
            let restorable = RecordedSupersession(signalId: "s1", label: "Buy flowers", replacedBy: nil, stands: true, isRestorable: true)
            let restored = RecordedSupersession(signalId: "s1", label: "Buy flowers", replacedBy: nil, stands: false, isRestorable: false)
            try expect(historyBatchOffers(for: noneBatch, facts: facts(supersessions: ["none": [restorable]]))[.restore] == .enabled)
            try expect(historyBatchOffers(for: noneBatch, facts: facts(supersessions: ["none": [restored]]))[.restore] == .taken)
        }

        r.run("a row with no Chat offers nothing Chat-scoped") {
            let batch = historyBatch(modelRow("task", output: "Call the dentist", chatId: nil))
            let offers = historyBatchOffers(for: batch, facts: facts())
            try expect(offers[.notForMe] == nil && offers[.mute] == nil)
        }

        r.run("the Mute label follows the Muted Chats") {
            try expect(historyBatchOffers(for: taskBatch, facts: facts(mutedChats: [chatId])).isMuted)
            try expect(!historyBatchOffers(for: taskBatch, facts: facts()).isMuted)
        }
    }

    runner.suite("history-snapshot: History draws from one read, and actions check again") { r in
        r.run("the list and each Batch's offers come from the same refresh") {
            let app = await MainActor.run { makeHistoryApp() }
            await app.model.extraction.load()
            let viewModel = try await MainActor.run { () -> HistoryViewModel in
                try app.history.record(screenedRow("screened"))
                let viewModel = app.viewModel()
                viewModel.showsUnfilteredLog = true
                return viewModel
            }
            try await MainActor.run {
                let batch = try require(viewModel.batches.first { $0.id == "screened" })
                try expect(viewModel.offers(for: batch)[.thisWasWork] == .enabled)
                try expect(viewModel.segments.contains(.borderline))
            }
        }

        r.run("a button drawn before the Screening toggle went off does nothing when clicked") {
            let app = await MainActor.run { makeHistoryApp() }
            await app.model.extraction.load()
            let batch = try await MainActor.run { () -> HistoryBatch in
                try app.history.record(screenedRow("screened"))
                let viewModel = app.viewModel()
                viewModel.showsUnfilteredLog = true
                let batch = try require(viewModel.batches.first { $0.id == "screened" })
                try expect(viewModel.offers(for: batch)[.thisWasWork] == .enabled)
                app.screeningSettings.isEnabled = false
                return batch
            }
            await app.actions.thisWasWork(batch)
            let recorded = await MainActor.run { app.model.corrections.types(forBatches: ["screened"]) }
            try expect(recorded.isEmpty, "got \(recorded)")
        }
    }

    runner.suite("history-snapshot: History refreshes when what it reads changes") { r in
        r.run("flipping the Screening toggle in Settings refreshes the segments and buttons together") {
            let app = await MainActor.run { makeHistoryApp() }
            await app.model.extraction.load()
            let (viewModel, settings, batch) = try await MainActor.run { () -> (HistoryViewModel, ScreeningSettingsViewModel, HistoryBatch) in
                try app.history.record(screenedRow("screened"))
                let viewModel = app.viewModel()
                viewModel.showsUnfilteredLog = true
                let settings = ScreeningSettingsViewModel(settings: app.screeningSettings, keyStore: FakeAPIKeyStore(), extraction: app.model.extraction)
                return (viewModel, settings, try require(viewModel.batches.first { $0.id == "screened" }))
            }
            try await MainActor.run {
                settings.isEnabled = false
                try expect(!viewModel.segments.contains(.borderline))
                try expect(viewModel.offers(for: batch)[.thisWasWork] == nil)
                try expect(viewModel.offers(for: batch)[.addTask] == .enabled)
                settings.isEnabled = true
                try expect(viewModel.segments.contains(.borderline))
                try expect(viewModel.offers(for: batch)[.thisWasWork] == .enabled)
            }
        }

        r.run("unloading the model refreshes History's model-bound buttons") {
            let (app, viewModel, batch) = try await MainActor.run { () -> (HistoryApp, HistoryViewModel, HistoryBatch) in
                let app = makeHistoryApp()
                try app.history.record(screenedRow("screened"))
                let viewModel = app.viewModel()
                viewModel.showsUnfilteredLog = true
                return (app, viewModel, try require(viewModel.batches.first { $0.id == "screened" }))
            }
            try await MainActor.run {
                app.model.extraction.unload()
                try expect(viewModel.offers(for: batch)[.thisWasWork] == .unavailable(reason: noModelLoadedReason))
            }
        }
    }
}
