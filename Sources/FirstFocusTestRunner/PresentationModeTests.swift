import FirstFocusApp
import FirstFocusCore
import Foundation

/// Zen Focus Mode, Minimal View, Esc and \u{2318}Z, decided without a window.

private let keyWindow = WindowFocus(isMainWindowKey: true, hasSheet: false)

@MainActor
private func makeModel(
    tasks: [ReminderTask] = [], checkedOff: [CheckedOffReminder] = []
) -> AppModel {
    let store = makeTestSignalStore()
    try? store.markBackfillComplete()
    return AppModel(AppDependencies.test { d in
        d.taskSource = FakeTaskSource(tasks: tasks, checkedOff: checkedOff)
        d.signalStore = store
    })
}

private func task(_ id: String) -> ReminderTask {
    ReminderTask(id: id, title: id, dueAt: nil, priority: .high, createdAt: Date())
}

private func doneToday(_ id: String) -> CheckedOffReminder {
    CheckedOffReminder(task: task(id), checkedOffAt: Date())
}

func registerPresentationModeTests(_ runner: TestRunner) {
    runner.suite("Presentation mode: what Esc leaves") { r in
        r.run("with Zen and Minimal View both on, Esc leaves Zen first") {
            let both = PresentationMode(isZen: true, isMinimalView: true)
            try expect(both.escapeExit(window: keyWindow, isPreviewOpen: false) == .zen)
            let minimalOnly = PresentationMode(isZen: false, isMinimalView: true)
            try expect(minimalOnly.escapeExit(window: keyWindow, isPreviewOpen: false) == .minimalView)
        }

        r.run("Esc is left to others while an alert, a preview or another window has it, or in neither mode") {
            let both = PresentationMode(isZen: true, isMinimalView: true)
            try expect(both.escapeExit(window: WindowFocus(isMainWindowKey: false, hasSheet: false), isPreviewOpen: false) == nil)
            try expect(both.escapeExit(window: WindowFocus(isMainWindowKey: true, hasSheet: true), isPreviewOpen: false) == nil)
            try expect(both.escapeExit(window: keyWindow, isPreviewOpen: true) == nil)
            try expect(PresentationMode(isZen: false, isMinimalView: false).escapeExit(window: keyWindow, isPreviewOpen: false) == nil)
        }

        r.run("the model leaves Zen on the first Esc and Minimal View on the second") {
            let model = await MainActor.run { makeModel() }
            await MainActor.run {
                model.isZenFocusModeEnabled = true
                model.isMinimalViewEnabled = true
            }
            let first = await MainActor.run { model.pressEscape(window: keyWindow) }
            let afterFirst = await MainActor.run { (model.isZenFocusModeEnabled, model.isMinimalViewEnabled) }
            try expect(first && afterFirst == (false, true), "got \(afterFirst)")
            let second = await MainActor.run { model.pressEscape(window: keyWindow) }
            let afterSecond = await MainActor.run { (model.isZenFocusModeEnabled, model.isMinimalViewEnabled) }
            try expect(second && afterSecond == (false, false))
            let third = await MainActor.run { model.pressEscape(window: keyWindow) }
            try expect(!third, "nothing left to leave")
        }
    }

    runner.suite("Undo bar: \u{2318}Z") { r in
        r.run("undoes the offer only with the main window key, no sheet, and no text being edited") {
            let model = await MainActor.run { makeModel(tasks: [task("r1")]) }
            await model.start()
            let withNoOffer = await MainActor.run { model.pressCommandZ(window: keyWindow) }
            try expect(!withNoOffer, "no offer on the bar")
            await MainActor.run { model.checkOff(model.rankedList.focus.first!) }
            let blocked = await MainActor.run {
                [
                    model.pressCommandZ(window: WindowFocus(isMainWindowKey: false, hasSheet: false)),
                    model.pressCommandZ(window: WindowFocus(isMainWindowKey: true, hasSheet: true)),
                    model.pressCommandZ(window: WindowFocus(isMainWindowKey: true, hasSheet: false, isEditingText: true)),
                ]
            }
            try expect(blocked == [false, false, false])
            let taken = await MainActor.run { model.pressCommandZ(window: keyWindow) }
            try expect(taken)
            try await Task.sleep(for: .milliseconds(100))
            let back = await MainActor.run { model.rankedList.focus.map(\.id) }
            try expect(back == ["r1"], "undone, got \(back)")
        }
    }

    runner.suite("Checked Off: the count text") { r in
        r.run("reads in the singular and the plural") {
            let one = await MainActor.run { makeModel(checkedOff: [doneToday("a")]) }
            await one.start()
            let three = await MainActor.run { makeModel(checkedOff: [doneToday("a"), doneToday("b"), doneToday("c")]) }
            await three.start()
            let texts = await MainActor.run { (one.checkedOffCountText, three.checkedOffCountText) }
            try expect(texts.0 == "1 reminder completed today", "got \(texts.0)")
            try expect(texts.1 == "3 reminders completed today", "got \(texts.1)")
        }
    }
}
