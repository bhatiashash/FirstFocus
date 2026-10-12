import DailyOSCore
import Foundation

func registerHeuristicTests(_ runner: TestRunner) {
    runner.suite("isWorthExtracting") { r in
        r.run("empty text is rejected") {
            try expect(isWorthExtracting("") == false)
        }
        r.run("whitespace-only text is rejected") {
            try expect(isWorthExtracting("   \n  ") == false)
        }
        r.run("a plain acknowledgment is rejected") {
            try expect(isWorthExtracting("ok") == false)
            try expect(isWorthExtracting("thanks") == false)
            try expect(isWorthExtracting("lol") == false)
        }
        r.run("an acknowledgment is rejected regardless of case or surrounding whitespace") {
            try expect(isWorthExtracting("  OK  ") == false)
            try expect(isWorthExtracting("Thanks") == false)
        }
        r.run("ordinary work text passes through") {
            try expect(isWorthExtracting("call the dentist") == true)
            try expect(isWorthExtracting("buy milk and eggs") == true)
        }
        r.run("an acknowledgment word inside a longer message still passes through") {
            try expect(isWorthExtracting("ok let's meet at 5") == true, "only an exact-match acknowledgment is rejected, never a substring")
        }
        r.run("a short but substantive message still passes through") {
            try expect(isWorthExtracting("call mom") == true, "length alone is never the filter")
        }
    }
}
