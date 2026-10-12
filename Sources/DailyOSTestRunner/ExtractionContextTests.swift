import DailyOSCore
import Foundation

private func chatMessage(
    id: String, chatId: Int = 1, isFromMe: Bool = false, text: String = "hi", createdAt: Date
) -> ChatMessage {
    ChatMessage(id: id, chatId: chatId, isFromMe: isFromMe, text: text, createdAt: createdAt)
}

func registerExtractionContextTests(_ runner: TestRunner) {
    let now = Date(timeIntervalSince1970: 1_000_000)

    runner.suite("recentContext") { r in
        r.run("messages from a different chat are excluded") {
            let target = chatMessage(id: "t", chatId: 1, createdAt: now)
            let other = chatMessage(id: "o", chatId: 2, createdAt: now - 60)
            try expect(recentContext(for: target, in: [target, other]).isEmpty)
        }
        r.run("the target message itself is excluded from its own context") {
            let target = chatMessage(id: "t", chatId: 1, createdAt: now)
            try expect(recentContext(for: target, in: [target]).isEmpty)
        }
        r.run("a message after the target is excluded") {
            let target = chatMessage(id: "t", chatId: 1, createdAt: now)
            let later = chatMessage(id: "later", chatId: 1, createdAt: now + 60)
            try expect(recentContext(for: target, in: [target, later]).isEmpty)
        }
        r.run("prior same-chat messages come back oldest-to-newest") {
            let target = chatMessage(id: "t", chatId: 1, createdAt: now)
            let first = chatMessage(id: "first", chatId: 1, text: "first", createdAt: now - 120)
            let second = chatMessage(id: "second", chatId: 1, text: "second", createdAt: now - 60)
            let context = recentContext(for: target, in: [target, second, first])
            try expect(context.map(\.id) == ["first", "second"])
        }
        r.run("only the most recent `limit` prior messages are kept") {
            let target = chatMessage(id: "t", chatId: 1, createdAt: now)
            let messages = (0..<10).map { i in
                chatMessage(id: "m\(i)", chatId: 1, createdAt: now - Double(600 - i * 60))
            }
            let context = recentContext(for: target, in: messages + [target], limit: 3)
            try expect(context.map(\.id) == ["m7", "m8", "m9"])
        }
    }

    runner.suite("formatForExtraction") { r in
        r.run("with no context, a Self-thread note's plain text passes through unchanged") {
            let target = ChatMessage(id: "t", chatId: 1, isFromMe: true, text: "call the dentist", createdAt: now, isSelfThread: true)
            try expect(formatForExtraction(target: target, context: []) == "call the dentist")
        }
        r.run("with no context, a message from someone else still goes under [latest messages]") {
            let target = chatMessage(id: "t", text: "call the dentist", createdAt: now)
            try expect(formatForExtraction(target: target, context: []) == "[latest messages]\nThem: call the dentist")
        }
        r.run("context is labeled by direction and precedes the target under a judge marker") {
            let target = chatMessage(id: "t", isFromMe: false, text: "also grab bread", createdAt: now)
            let context = [
                chatMessage(id: "c1", isFromMe: false, text: "can you grab milk", createdAt: now - 120),
                chatMessage(id: "c2", isFromMe: true, text: "sure what time", createdAt: now - 60),
            ]
            let formatted = formatForExtraction(target: target, context: context)
            try expect(formatted.contains("Them: can you grab milk"))
            try expect(formatted.contains("You: sure what time"))
            try expect(formatted.contains("Them: also grab bread"))
            try expect(formatted.hasSuffix("Them: also grab bread"), "the message to judge must be last")
        }
        r.run("a self-sent target is labeled You in its own judge line") {
            let target = chatMessage(id: "t", isFromMe: true, text: "I'll send the file tomorrow", createdAt: now)
            let context = [chatMessage(id: "c1", isFromMe: false, text: "can you send that file", createdAt: now - 60)]
            let formatted = formatForExtraction(target: target, context: context)
            try expect(formatted.hasSuffix("You: I'll send the file tomorrow"))
        }

        r.run("a custom senderLabel closure names a non-you sender instead of the literal Them") {
            let target = chatMessage(id: "t", isFromMe: false, text: "also grab bread", createdAt: now)
            let context = [chatMessage(id: "c1", isFromMe: false, text: "can you grab milk", createdAt: now - 60)]
            let formatted = formatForExtraction(target: target, context: context, senderLabel: { _ in "Participant A" })
            try expect(formatted.contains("Participant A: can you grab milk"))
            try expect(formatted.hasSuffix("Participant A: also grab bread"))
        }

        r.run("with zero corrections, output is unchanged from before this parameter existed") {
            let target = chatMessage(id: "t", text: "call the dentist", createdAt: now)
            try expect(formatForExtraction(target: target, context: [], corrections: []) == formatForExtraction(target: target, context: []))
        }

        r.run("a single-line correction renders as a quoted Message/Output pair ahead of context, under a [corrections] header") {
            let target = chatMessage(id: "t", isFromMe: false, text: "lol nice", createdAt: now)
            let correction = Correction(chatId: 1, inputText: "just chatting", correctedOutput: "NONE", correctionType: .falsePositive)
            let formatted = formatForExtraction(target: target, context: [], corrections: [correction])
            try expect(formatted == "[corrections]\nMessage: \"just chatting\"\nOutput: NONE\n\n[latest messages]\nThem: lol nice")
        }

        r.run("a context-bearing correction (containing a newline) renders unquoted, matching the multi-line EXAMPLES shape") {
            let target = chatMessage(id: "t", isFromMe: false, text: "lol nice", createdAt: now)
            let multilineInput = "[context]\nParticipant A: can someone grab snacks\n\n[latest messages]\nParticipant B: also grab napkins"
            let correction = Correction(chatId: 1, inputText: multilineInput, correctedOutput: "NONE", correctionType: .falsePositive)
            let formatted = formatForExtraction(target: target, context: [], corrections: [correction])
            try expect(formatted.hasPrefix("[corrections]\nMessage:\n\(multilineInput)\nOutput: NONE"), "must not wrap a multi-line input in quotes")
        }

        r.run("several corrections join with a blank line between each pair") {
            let target = chatMessage(id: "t", isFromMe: false, text: "lol nice", createdAt: now)
            let corrections = [
                Correction(chatId: 1, inputText: "a", correctedOutput: "NONE", correctionType: .falsePositive),
                Correction(chatId: 1, inputText: "b", correctedOutput: "NONE", correctionType: .falsePositive),
            ]
            let formatted = formatForExtraction(target: target, context: [], corrections: corrections)
            try expect(formatted.contains("Message: \"a\"\nOutput: NONE\n\nMessage: \"b\"\nOutput: NONE"))
        }

        r.run("corrections precede context, and [latest messages] always comes last") {
            let target = chatMessage(id: "t", isFromMe: false, text: "lol nice", createdAt: now)
            let context = [chatMessage(id: "c1", isFromMe: false, text: "earlier line", createdAt: now - 60)]
            let correction = Correction(chatId: 1, inputText: "flagged input", correctedOutput: "NONE", correctionType: .falsePositive)
            let formatted = formatForExtraction(target: target, context: context, corrections: [correction])
            let correctionsRange = try require(formatted.range(of: "[corrections]"))
            let contextRange = try require(formatted.range(of: "[context]"))
            let judgeRange = try require(formatted.range(of: "[latest messages]"))
            try expect(correctionsRange.lowerBound < contextRange.lowerBound)
            try expect(contextRange.lowerBound < judgeRange.lowerBound)
        }
    }
}
