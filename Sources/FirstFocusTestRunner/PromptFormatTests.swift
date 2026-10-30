import FirstFocusCore
import Foundation

/// Ticket 03 (batched-extraction): the user turn's blocks, their order,
/// and the versioned saved prompt.
private func chat(
    id: String, text: String, isFromMe: Bool = false, isSelfThread: Bool = false, at offset: TimeInterval = 0
) -> ChatMessage {
    ChatMessage(
        id: id, chatId: 7, isFromMe: isFromMe, text: text, createdAt: Date(timeIntervalSince1970: 1_000_000 + offset),
        isSelfThread: isSelfThread
    )
}

private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!
}

func registerPromptFormatTests(_ runner: TestRunner) {
    runner.suite("formatForExtraction: batched-extraction input format") { r in
        r.run("a bare Self-thread note with nothing else is sent as the bare line") {
            let note = chat(id: "n1", text: "call the dentist", isFromMe: true, isSelfThread: true)
            try expect(formatForExtraction(target: note, context: []) == "call the dentist")
        }
        r.run("a message from someone else always goes under [latest messages] with its sender") {
            let message = chat(id: "m1", text: "can you grab milk")
            try expect(formatForExtraction(target: message, context: []) == "[latest messages]\nThem: can you grab milk")
        }
        r.run("the four blocks come in order: corrections, open suggestions, context, latest messages") {
            let context = [chat(id: "c1", text: "can you grab milk", at: 0), chat(id: "c2", text: "sure", isFromMe: true, at: 1)]
            let target = chat(id: "m1", text: "also grab bread", at: 2)
            let correction = Correction(chatId: 7, inputText: "lol", correctedOutput: "NONE", correctionType: .falsePositive)
            let formatted = formatForExtraction(
                target: target, context: context, corrections: [correction], openSuggestions: ["Grab milk", "Book court"]
            )
            try expect(formatted == """
                [corrections]
                Message: "lol"
                Output: NONE

                [open suggestions]
                1. Grab milk
                2. Book court

                [context]
                Them: can you grab milk
                You: sure

                [latest messages]
                Them: also grab bread
                """, "got:\n\(formatted)")
        }
        r.run("a Self-thread note with open suggestions gets the blocks too") {
            let note = chat(id: "n1", text: "skip the dentist, moved it", isFromMe: true, isSelfThread: true)
            let formatted = formatForExtraction(target: note, context: [], openSuggestions: ["Call the dentist"])
            try expect(formatted == "[open suggestions]\n1. Call the dentist\n\n[latest messages]\nYou: skip the dentist, moved it")
        }
        r.run("a Correction written in the old format is shown with the new block name") {
            let old = "[context]\nThem: can you grab milk\n\n[message to judge]\nThem: also bread"
            let correction = Correction(chatId: 7, inputText: old, correctedOutput: "NONE", correctionType: .falsePositive)
            let formatted = formatForExtraction(target: chat(id: "m1", text: "ok"), context: [], corrections: [correction])
            try expect(!formatted.contains("[message to judge]"))
            try expect(formatted.contains("[context]\nThem: can you grab milk\n\n[latest messages]\nThem: also bread\nOutput: NONE"))
        }
    }

    runner.suite("the default extraction prompt") { r in
        r.run("describes the new blocks and output lines, and never the old judge marker") {
            let prompt = LlamaCppIntentExtractor.defaultExtractionPrompt
            for needle in ["[latest messages]", "[open suggestions]", "[corrections]", "[context]", "UPDATE <n>: <label>", "CANCEL <n>", "DUE_TEXT"] {
                try expect(prompt.contains(needle), "missing \(needle)")
            }
            try expect(!prompt.contains("[message to judge]"))
            try expect(!prompt.contains("Dad"), "the model only ever sees You, Them and Participant Labels (ADR 0033)")
        }
        r.run("the system turn is the same on different days and still carries Rules") {
            let turn = LlamaCppIntentExtractor.systemTurn(rules: ["Shipping updates are never tasks"])
            try expect(turn == LlamaCppIntentExtractor.systemTurn(rules: ["Shipping updates are never tasks"]))
            try expect(turn.contains("Shipping updates are never tasks"))
        }
    }

    runner.suite("ExtractionSettings: saved prompt format version") { r in
        r.run("an override saved before versioning is set aside, not used") {
            let defaults = isolatedDefaults()
            defaults.set("my old prompt", forKey: "extractionPromptOverride")
            let settings = ExtractionSettings(defaults: defaults)
            try expect(settings.effectivePromptOverride == nil)
            try expect(settings.setAsidePromptOverride == "my old prompt")
        }
        r.run("an override saved now is used and nothing is set aside") {
            let settings = ExtractionSettings(defaults: isolatedDefaults())
            settings.promptOverride = "my new prompt"
            try expect(settings.effectivePromptOverride == "my new prompt")
            try expect(settings.setAsidePromptOverride == nil)
        }
        r.run("saving again stamps the current version") {
            let defaults = isolatedDefaults()
            defaults.set("my old prompt", forKey: "extractionPromptOverride")
            let settings = ExtractionSettings(defaults: defaults)
            settings.promptOverride = "my old prompt, merged"
            try expect(settings.effectivePromptOverride == "my old prompt, merged")
            try expect(settings.setAsidePromptOverride == nil)
        }
        r.run("no override means nothing is used or set aside") {
            let settings = ExtractionSettings(defaults: isolatedDefaults())
            try expect(settings.effectivePromptOverride == nil)
            try expect(settings.setAsidePromptOverride == nil)
        }
    }
}
