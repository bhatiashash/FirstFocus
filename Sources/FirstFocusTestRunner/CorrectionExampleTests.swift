import FirstFocusCore
import Foundation

private let base = Date(timeIntervalSince1970: 1_780_000_000)

private func message(_ id: String, _ text: String, fromMe: Bool = false, chatId: Int = 5) -> ChatMessage {
    ChatMessage(id: id, chatId: chatId, isFromMe: fromMe, text: text, createdAt: base, senderAddress: fromMe ? nil : "+15551230000")
}

/// A History row for a model call, carrying the prompt the composer really
/// produced for it and a transcript under real names, the way `judge`
/// records one.
private func row(prompt: String, sourceRef: String = "m9", chatId: Int = 5) -> HistoryEntry {
    HistoryEntry(
        sourceRawText: "…", rawOutput: "Book the flights", modelUsed: "Q", signalCount: 1, chatId: chatId,
        renderedContext: prompt, sourceRef: sourceRef, sender: "Priya Raman",
        transcript: [HistoryTranscriptLine(speaker: "Priya Raman", isFromMe: false, text: "can you book the flights", sentAt: base)]
    )
}

private let earlierExample = Correction(
    chatId: 2, sourceRef: "m1", inputText: "[context]\nParticipant A: old context\n\n[latest messages]\nParticipant A: old ask",
    correctedOutput: "NONE", correctionType: .falsePositive
)

func registerCorrectionExampleTests(_ runner: TestRunner) {
    runner.suite("A Correction's example carries only its Batch and context") { r in
        r.run("a prompt that carried earlier examples and open Suggestions keeps only its own context and Batch") {
            let prompt = formatForExtraction(
                batch: [message("m9", "can you book the flights")], context: [message("m8", "trip is on")],
                corrections: [earlierExample], openSuggestions: ["Pack the bags"],
                senderLabel: { _ in "Participant A" }
            )
            let store = FakeCorrectionStore()
            try Corrections(store: store).recordNotForMe(row(prompt: prompt))
            let stored = try require(store.stored.first)
            try expect(
                stored.inputText == "[context]\nParticipant A: trip is on\n\n[latest messages]\nParticipant A: can you book the flights",
                "got:\n\(stored.inputText)"
            )
        }

        r.run("a prompt with no context of its own doesn't borrow an earlier example's context") {
            let prompt = formatForExtraction(
                batch: [message("m9", "can you book the flights")], context: [], corrections: [earlierExample],
                senderLabel: { _ in "Participant A" }
            )
            let store = FakeCorrectionStore()
            try Corrections(store: store).recordNotForMe(row(prompt: prompt))
            try expect(store.stored.first?.inputText == "[latest messages]\nParticipant A: can you book the flights")
        }

        r.run("a Self-thread note sent as a bare line is kept as that line") {
            let store = FakeCorrectionStore()
            try Corrections(store: store).recordMissedTask(label: "Call mum", for: row(prompt: "call mum sunday"))
            try expect(store.stored.first?.inputText == "call mum sunday")
        }

        r.run("an example shown to the model never nests another example, an open Suggestion or a real name") {
            let recorded = formatForExtraction(
                batch: [message("m9", "can you book the flights")], context: [message("m8", "trip is on")],
                corrections: [earlierExample], openSuggestions: ["Pack the bags"],
                senderLabel: { _ in "Participant A" }
            )
            let store = FakeCorrectionStore()
            try Corrections(store: store).recordNotForMe(row(prompt: recorded))
            let next = formatForExtraction(
                batch: [message("m20", "see you there")], context: [], corrections: selectCorrections(chatId: 5, store: store),
                senderLabel: { _ in "Participant A" }
            )
            try expect(next.components(separatedBy: "[corrections]").count == 2, "one [corrections] block, got:\n\(next)")
            try expect(!next.contains("[open suggestions]"), "got:\n\(next)")
            try expect(!next.contains("old ask"), "the earlier example stays out, got:\n\(next)")
            try expect(!next.contains("Priya"), "History's transcript names never reach the prompt")
        }

        r.run("the Rule proposal prompt lists each mistake without nested examples") {
            let recorded = formatForExtraction(
                batch: [message("m9", "can you book the flights")], context: [], corrections: [earlierExample],
                openSuggestions: ["Pack the bags"], senderLabel: { _ in "Participant A" }
            )
            let store = FakeCorrectionStore()
            try Corrections(store: store).recordNotForMe(row(prompt: recorded))
            let prompt = ruleProposalUserPrompt(corrections: store.stored)
            try expect(prompt == "Mistake 1:\n[latest messages]\nParticipant A: can you book the flights", "got:\n\(prompt)")
        }
    }
}
