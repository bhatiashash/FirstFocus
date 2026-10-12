import DailyOSCore
import Foundation

/// undo-bar: the Undo bar on its own, with a fake clock and offers whose
/// commit and reverse steps only record that they ran.
@MainActor
private final class Steps {
    var ran: [String] = []
}

@MainActor
private func makeBar() -> (bar: UndoBar, clock: FakeUndoClock, steps: Steps) {
    let clock = FakeUndoClock()
    return (UndoBar(clock: clock, window: 5), clock, Steps())
}

/// The clock's actions hop to the main actor, as production's do. Lets
/// them land before the test looks.
private func settle() async {
    try? await Task.sleep(nanoseconds: 50_000_000)
}

func registerUndoBarTests(_ runner: TestRunner) {
    runner.suite("undo-bar: an offer and its window") { r in
        r.run("an offer shows until its window ends") {
            let (bar, clock, steps) = await MainActor.run { makeBar() }
            try await MainActor.run {
                bar.offer(.dismissed, label: "Call the dentist", .reversible { steps.ran.append("reverse") })
                try expect(bar.current?.text == "Dismissed \u{201C}Call the dentist\u{201D}", "got \(String(describing: bar.current))")
            }
            clock.fire()
            await settle()
            try await MainActor.run {
                try expect(bar.current == nil)
                try expect(steps.ran.isEmpty, "a reversible offer does nothing when its window ends")
            }
        }
    }

    runner.suite("undo-bar: a held-back offer") { r in
        r.run("it is hidden while offered and written when its window ends") {
            let (bar, clock, steps) = await MainActor.run { makeBar() }
            try await MainActor.run {
                bar.offer(.checkedOff, label: "Pay rent", .heldBack(hiding: "r1") { steps.ran.append("commit r1") })
                try expect(bar.hiddenIDs == ["r1"])
                try expect(steps.ran.isEmpty, "nothing is written while the offer shows")
            }
            clock.fire()
            await settle()
            try await MainActor.run {
                try expect(steps.ran == ["commit r1"], "got \(steps.ran)")
                try expect(bar.current == nil)
                try expect(bar.hiddenIDs.isEmpty)
            }
        }

        r.run("Undo drops it unwritten, and its window ending later writes nothing") {
            let (bar, clock, steps) = await MainActor.run { makeBar() }
            await MainActor.run {
                bar.offer(.checkedOff, label: "Pay rent", .heldBack(hiding: "r1") { steps.ran.append("commit r1") })
            }
            await bar.undo()
            try await MainActor.run {
                try expect(bar.current == nil)
                try expect(bar.hiddenIDs.isEmpty)
            }
            clock.fire()
            await settle()
            try await MainActor.run { try expect(steps.ran.isEmpty, "got \(steps.ran)") }
        }

        r.run("another offer replacing it writes it at once") {
            let (bar, _, steps) = await MainActor.run { makeBar() }
            try await MainActor.run {
                bar.offer(.checkedOff, label: "Pay rent", .heldBack(hiding: "r1") { steps.ran.append("commit r1") })
                bar.offer(.checkedOff, label: "Call mum", .heldBack(hiding: "r2") { steps.ran.append("commit r2") })
                try expect(steps.ran == ["commit r1"], "got \(steps.ran)")
                try expect(bar.hiddenIDs == ["r2"])
                try expect(bar.current?.label == "Call mum")
            }
        }

        r.run("the replaced one's window ending writes nothing twice and leaves the newer one showing") {
            let (bar, clock, steps) = await MainActor.run { makeBar() }
            await MainActor.run {
                bar.offer(.checkedOff, label: "Pay rent", .heldBack(hiding: "r1") { steps.ran.append("commit r1") })
                bar.offer(.dismissed, label: "Grab milk", .reversible { steps.ran.append("reverse") })
            }
            clock.fireOldest()
            await settle()
            try await MainActor.run {
                try expect(steps.ran == ["commit r1"], "got \(steps.ran)")
                try expect(bar.current?.label == "Grab milk")
            }
        }
    }

    runner.suite("undo-bar: a reversible offer") { r in
        r.run("Undo runs its reverse step and closes the bar") {
            let (bar, _, steps) = await MainActor.run { makeBar() }
            await MainActor.run {
                bar.offer(.dismissed, label: "Grab milk", .reversible { steps.ran.append("reverse") })
            }
            await bar.undo()
            try await MainActor.run {
                try expect(steps.ran == ["reverse"], "got \(steps.ran)")
                try expect(bar.current == nil)
            }
        }

        r.run("replaced, it stays done: its reverse never runs") {
            let (bar, clock, steps) = await MainActor.run { makeBar() }
            await MainActor.run {
                bar.offer(.dismissed, label: "Grab milk", .reversible { steps.ran.append("reverse milk") })
                bar.offer(.dismissed, label: "Grab bread", .reversible { steps.ran.append("reverse bread") })
            }
            clock.fireOldest()
            await settle()
            let label = await MainActor.run { bar.current?.label }
            try expect(label == "Grab bread", "the replaced offer's window ending leaves the newer one, got \(String(describing: label))")
            await bar.undo()
            try await MainActor.run { try expect(steps.ran == ["reverse bread"], "got \(steps.ran)") }
        }

        r.run("after its window ends, Undo does nothing") {
            let (bar, clock, steps) = await MainActor.run { makeBar() }
            await MainActor.run {
                bar.offer(.dismissed, label: "Grab milk", .reversible { steps.ran.append("reverse") })
            }
            clock.fire()
            await settle()
            await bar.undo()
            try await MainActor.run { try expect(steps.ran.isEmpty, "got \(steps.ran)") }
        }
    }

    runner.suite("undo-bar: a report-only offer") { r in
        r.run("it can't be undone, and Undo leaves it showing") {
            let (bar, _, _) = await MainActor.run { makeBar() }
            await MainActor.run { bar.offer(.addedToLater, label: "Pay rent", .report) }
            await bar.undo()
            try await MainActor.run {
                try expect(bar.current?.canUndo == false)
                try expect(bar.current?.text == "Added \u{201C}Pay rent\u{201D} to Later")
            }
        }

        r.run("another offer replaces it") {
            let (bar, _, _) = await MainActor.run { makeBar() }
            try await MainActor.run {
                bar.offer(.addedToLater, label: "Pay rent", .report)
                bar.offer(.dismissed, label: "Grab milk", .reversible {})
                try expect(bar.current?.text == "Dismissed \u{201C}Grab milk\u{201D}", "got \(String(describing: bar.current))")
            }
        }
    }

    runner.suite("undo-bar: quitting") { r in
        r.run("quitting writes a held-back offer at once") {
            let (bar, _, steps) = await MainActor.run { makeBar() }
            try await MainActor.run {
                bar.offer(.checkedOff, label: "Pay rent", .heldBack(hiding: "r1") { steps.ran.append("commit r1") })
                bar.flush()
                try expect(steps.ran == ["commit r1"], "got \(steps.ran)")
            }
        }

        r.run("quitting runs no reverse step") {
            let (bar, _, steps) = await MainActor.run { makeBar() }
            try await MainActor.run {
                bar.offer(.dismissed, label: "Grab milk", .reversible { steps.ran.append("reverse") })
                bar.flush()
                try expect(steps.ran.isEmpty, "got \(steps.ran)")
            }
        }
    }
}
