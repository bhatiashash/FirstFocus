import DailyOSCore
import Foundation

private func message(id: String, createdAt: Date) -> ChatMessage {
    ChatMessage(id: id, chatId: 1, isFromMe: true, text: "text \(id)", createdAt: createdAt)
}

func registerExtractionWindowTests(_ runner: TestRunner) {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let day: TimeInterval = 86400

    runner.suite("withinExtractionWindow") { r in
        r.run("a message from today is within the window") {
            let m = message(id: "a", createdAt: now)
            try expect(withinExtractionWindow([m], now: now).map(\.id) == ["a"])
        }

        r.run("a message exactly at the lookback boundary is within the window") {
            let m = message(id: "a", createdAt: now.addingTimeInterval(-extractionLookbackDays * day))
            try expect(withinExtractionWindow([m], now: now).map(\.id) == ["a"])
        }

        r.run("a message older than the lookback window is excluded") {
            let m = message(id: "a", createdAt: now.addingTimeInterval(-(extractionLookbackDays * day) - 1))
            try expect(withinExtractionWindow([m], now: now).isEmpty)
        }

        r.run("a mix of recent and old messages keeps only the recent ones, in their original order") {
            let recent = message(id: "recent", createdAt: now - day)
            let old = message(id: "old", createdAt: now - (30 * day))
            let alsoRecent = message(id: "also-recent", createdAt: now - (2 * day))
            try expect(withinExtractionWindow([recent, old, alsoRecent], now: now).map(\.id) == ["recent", "also-recent"])
        }

        r.run("empty input produces empty output") {
            try expect(withinExtractionWindow([], now: now).isEmpty)
        }

        r.run("a custom lookbackDays overrides the default extractionLookbackDays") {
            let m = message(id: "a", createdAt: now - (3 * day))
            try expect(withinExtractionWindow([m], now: now, lookbackDays: 2).isEmpty, "3 days old, outside a 2-day window")
            try expect(withinExtractionWindow([m], now: now, lookbackDays: 5).map(\.id) == ["a"], "3 days old, inside a 5-day window")
        }
    }
}
