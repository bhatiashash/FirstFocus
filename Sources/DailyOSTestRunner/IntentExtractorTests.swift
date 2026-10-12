import DailyOSCore
import Foundation

func registerIntentExtractorTests(_ runner: TestRunner) {
    runner.suite("parseExtractionOutput") { r in
        r.run("a literal NONE line parses to no candidates") {
            try expect(parseExtractionOutput("NONE") == [])
        }
        r.run("one line parses to one candidate") {
            try expect(parseExtractionOutput("Call the dentist") == ["Call the dentist"])
        }
        r.run("several lines parse to several candidates, in order") {
            try expect(parseExtractionOutput("Call the dentist\nBuy milk") == ["Call the dentist", "Buy milk"])
        }
        r.run("surrounding whitespace on each line is trimmed") {
            try expect(parseExtractionOutput("  Call the dentist  \n  Buy milk  ") == ["Call the dentist", "Buy milk"])
        }
        r.run("blank lines between candidates are ignored") {
            try expect(parseExtractionOutput("Call the dentist\n\n\nBuy milk") == ["Call the dentist", "Buy milk"])
        }
        r.run("empty output parses to no candidates") {
            try expect(parseExtractionOutput("") == [])
        }
        r.run("whitespace-only output parses to no candidates") {
            try expect(parseExtractionOutput("   \n  ") == [])
        }
        r.run("NONE mixed with other lines is malformed and fails closed to no candidates") {
            try expect(parseExtractionOutput("Call the dentist\nNONE") == [], "inconsistent output is never promoted")
        }
        r.run("a lowercase none still means no task, never a candidate labelled none") {
            try expect(parseExtractionOutput("none") == [], "a Suggestion titled \"None\" reached the Inbox before this")
        }
        r.run("a DUE_TEXT line is never treated as a candidate label") {
            try expect(parseExtractionOutput("Call the dentist\nDUE_TEXT: \"tomorrow\"") == ["Call the dentist"])
        }
        r.run("several candidate labels alongside one DUE_TEXT line all parse, the DUE_TEXT line excluded") {
            try expect(parseExtractionOutput("Buy milk\nCall the dentist\nDUE_TEXT: \"tomorrow\"") == ["Buy milk", "Call the dentist"])
        }
    }

    runner.suite("DUE_TEXT resolution") { r in
        func parseExtractedDueDate(_ raw: String) -> Date? {
            parseExtractionResults(raw).first?.dueText.flatMap(resolveDueDate(fromPhrase:))
        }
        r.run("a clear DUE_TEXT line resolves to the right calendar day") {
            let date = try require(parseExtractedDueDate("Call the dentist\nDUE_TEXT: \"tomorrow\""))
            try expect(Calendar(identifier: .gregorian).isDate(date, inSameDayAs: expectedDate(daysFromToday: 1)))
        }
        r.run("the resolved date is midnight, never carrying a time of day") {
            let date = try require(parseExtractedDueDate("Call the dentist\nDUE_TEXT: \"tomorrow\""))
            let components = Calendar(identifier: .gregorian).dateComponents([.hour, .minute, .second], from: date)
            try expect(components.hour == 0 && components.minute == 0 && components.second == 0)
        }
        r.run("a DUE_TEXT line preceding the label belongs to nothing, so it is ignored") {
            try expect(parseExtractedDueDate("DUE_TEXT: \"tomorrow\"\nCall the dentist") == nil)
        }
        r.run("a message with no temporal cue at all produces no date") {
            try expect(parseExtractedDueDate("Call the dentist") == nil)
        }
        r.run("NONE with no DUE_TEXT line produces no date") {
            try expect(parseExtractedDueDate("NONE") == nil)
        }
        r.run("a cue too abstract for NSDataDetector to resolve fails closed to no date rather than a guess") {
            try expect(parseExtractedDueDate("Call the dentist\nDUE_TEXT: \"someday\"") == nil)
        }
        r.run("more than one DUE_TEXT line is inconsistent output and fails closed") {
            try expect(parseExtractedDueDate("Call the dentist\nDUE_TEXT: \"tomorrow\"\nDUE_TEXT: \"next week\"") == nil)
        }
        r.run("empty output produces no date") {
            try expect(parseExtractedDueDate("") == nil)
        }
    }

    runner.suite("resolveDueDate") { r in
        r.run("a bare weekday phrase resolves to that weekday") {
            let date = try require(resolveDueDate(fromPhrase: "next Tuesday"))
            try expect(Calendar(identifier: .gregorian).component(.weekday, from: date) == 3, "Tuesday is weekday 3")
        }
        r.run("\"tomorrow\" resolves within a day of today") {
            let date = try require(resolveDueDate(fromPhrase: "tomorrow"))
            try expect(Calendar(identifier: .gregorian).isDate(date, inSameDayAs: expectedDate(daysFromToday: 1)))
        }
        r.run("surrounding quotes are accepted and stripped") {
            let quoted = try require(resolveDueDate(fromPhrase: "\"tomorrow\""))
            let bare = try require(resolveDueDate(fromPhrase: "tomorrow"))
            try expect(Calendar(identifier: .gregorian).isDate(quoted, inSameDayAs: bare))
        }
        r.run("a phrase with no quotes still resolves") {
            try expect(resolveDueDate(fromPhrase: "next Tuesday") != nil, "the model won't always reproduce the taught quotes exactly")
        }
        r.run("a phrase too abstract to resolve returns nil, never a guess") {
            try expect(resolveDueDate(fromPhrase: "someday") == nil)
            try expect(resolveDueDate(fromPhrase: "eventually") == nil)
        }
        r.run("a coarse phrase NSDataDetector doesn't cover also returns nil") {
            try expect(resolveDueDate(fromPhrase: "next week") == nil, "a known coverage gap, accepted in exchange for never hallucinating a date")
        }
        r.run("empty or blank phrases return nil") {
            try expect(resolveDueDate(fromPhrase: "") == nil)
            try expect(resolveDueDate(fromPhrase: "   ") == nil)
        }
        r.run("a partial match still resolves, using whatever date it found") {
            try expect(resolveDueDate(fromPhrase: "EOD Friday") != nil, "NSDataDetector matches only \"Friday\" here, which is still a real date")
        }
        r.run("a resolved date never carries a time of day, even when the phrase names one") {
            let date = try require(resolveDueDate(fromPhrase: "by 5pm"))
            let components = Calendar(identifier: .gregorian).dateComponents([.hour, .minute, .second], from: date)
            try expect(components.hour == 0 && components.minute == 0 && components.second == 0, "a stated time is discarded along with the noon default, to keep one consistent rule")
        }
    }

    runner.suite("LlamaCppIntentExtractor.chatMLPrompt") { r in
        r.run("wraps the system prompt and user text in matching ChatML turns") {
            let prompt = LlamaCppIntentExtractor.chatMLPrompt(for: "call the dentist")
            try expect(prompt.contains("<|im_start|>system"))
            try expect(prompt.contains("call the dentist<|im_end|>"))
            try expect(prompt.contains("<|im_start|>user\n"))
            try expect(prompt.hasSuffix("<|im_start|>assistant\n"), "the prompt must end mid-assistant-turn, ready for the model to continue")
        }
        r.run("every im_start has a matching im_end before the final open assistant turn") {
            let prompt = LlamaCppIntentExtractor.chatMLPrompt(for: "anything")
            let starts = prompt.components(separatedBy: "<|im_start|>").count - 1
            let ends = prompt.components(separatedBy: "<|im_end|>").count - 1
            try expect(starts == 3, "system, user, assistant")
            try expect(ends == 2, "system and user close; assistant is deliberately left open")
        }
        r.run("user text is embedded verbatim, without escaping or truncation") {
            let text = "a message with \"quotes\" and\nnewlines"
            try expect(LlamaCppIntentExtractor.chatMLPrompt(for: text).contains(text))
        }
        r.run("today's date is embedded in the prompt, so a relative phrase has an anchor to resolve against") {
            let today = Date(timeIntervalSince1970: 1_000_000)
            let expected = plainDateFormatter().string(from: today)
            let prompt = LlamaCppIntentExtractor.chatMLPrompt(for: "anything", today: today)
            try expect(prompt.contains(expected), "expected the prompt to contain today's date (\(expected))")
        }
        r.run("ADR 0037: the system turn is byte-identical across dates, so its cached tokens stay valid past midnight") {
            let today = Date(timeIntervalSince1970: 1_000_000)
            let later = today.addingTimeInterval(86400 * 30)
            try expect(LlamaCppIntentExtractor.systemTurn() == LlamaCppIntentExtractor.systemTurn())
            let earlierPrompt = LlamaCppIntentExtractor.chatMLPrompt(for: "anything", today: today)
            let laterPrompt = LlamaCppIntentExtractor.chatMLPrompt(for: "anything", today: later)
            try expect(earlierPrompt.hasPrefix(LlamaCppIntentExtractor.systemTurn()))
            try expect(laterPrompt.hasPrefix(LlamaCppIntentExtractor.systemTurn()))
            let dateString = plainDateFormatter().string(from: Date())
            try expect(!LlamaCppIntentExtractor.systemTurn().contains(dateString), "the date must not live in the cacheable prefix")
        }
        r.run("ADR 0037: the date line opens the user turn, ahead of the message text") {
            let today = Date(timeIntervalSince1970: 1_000_000)
            let expected = plainDateFormatter().string(from: today)
            let prompt = LlamaCppIntentExtractor.chatMLPrompt(for: "[context]\nThem: hi\n\n[latest messages]\nThem: grab bread", today: today)
            try expect(prompt.contains("<|im_start|>user\nToday's date is \(expected).\n\n[context]"), "the date line must come first in the user turn")
        }
        r.run("the system turn plus the user turn is exactly the full prompt") {
            let today = Date(timeIntervalSince1970: 1_000_000)
            let full = LlamaCppIntentExtractor.chatMLPrompt(for: "call mom", today: today, promptOverride: "Custom.")
            let parts = LlamaCppIntentExtractor.systemTurn(promptOverride: "Custom.") + LlamaCppIntentExtractor.userTurn(for: "call mom", today: today)
            try expect(full == parts)
        }
        r.run("a different today produces a different date in the prompt") {
            let today = Date(timeIntervalSince1970: 1_000_000)
            let laterToday = today.addingTimeInterval(86400 * 30)
            let earlierPrompt = LlamaCppIntentExtractor.chatMLPrompt(for: "anything", today: today)
            let laterPrompt = LlamaCppIntentExtractor.chatMLPrompt(for: "anything", today: laterToday)
            try expect(earlierPrompt != laterPrompt)
        }
        r.run("with no override, the system prompt is the built-in default") {
            let prompt = LlamaCppIntentExtractor.chatMLPrompt(for: "anything")
            try expect(prompt.contains(LlamaCppIntentExtractor.defaultExtractionPrompt))
        }
        r.run("a non-blank override replaces the default instructions") {
            let prompt = LlamaCppIntentExtractor.chatMLPrompt(for: "anything", promptOverride: "Only ever output NONE.")
            try expect(prompt.contains("Only ever output NONE."))
            try expect(!prompt.contains(LlamaCppIntentExtractor.defaultExtractionPrompt))
        }
        r.run("today's date is still prepended ahead of a custom override") {
            let today = Date(timeIntervalSince1970: 1_000_000)
            let expected = plainDateFormatter().string(from: today)
            let prompt = LlamaCppIntentExtractor.chatMLPrompt(for: "anything", today: today, promptOverride: "Custom instructions.")
            try expect(prompt.contains("Today's date is \(expected)."), "the date must not depend on the override at all")
        }
        r.run("a blank or whitespace-only override falls back to the default, not an empty instruction") {
            let prompt = LlamaCppIntentExtractor.chatMLPrompt(for: "anything", promptOverride: "   \n  ")
            try expect(prompt.contains(LlamaCppIntentExtractor.defaultExtractionPrompt))
        }
        r.run("nil and blank overrides produce the exact same prompt") {
            let today = Date(timeIntervalSince1970: 1_000_000)
            let withNil = LlamaCppIntentExtractor.chatMLPrompt(for: "anything", today: today, promptOverride: nil)
            let withBlank = LlamaCppIntentExtractor.chatMLPrompt(for: "anything", today: today, promptOverride: "")
            try expect(withNil == withBlank)
        }
    }

    runner.suite("FakeIntentExtractor") { r in
        r.run("returns the mapped response for known text") {
            let fake = FakeIntentExtractor(responses: ["call mom" : "Call mom"])
            let raw = try await fake.extract(from: "call mom")
            try expect(raw == "Call mom")
        }
        r.run("returns the default response for unmapped text") {
            let fake = FakeIntentExtractor(responses: [:], defaultResponse: "NONE")
            let raw = try await fake.extract(from: "anything else")
            try expect(raw == "NONE")
        }
    }
}
