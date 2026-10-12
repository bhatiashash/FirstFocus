import DailyOSCore
import Foundation

/// Ticket 04 (batched-extraction): which Batches have closed, and when the
/// next one will.
private let t0 = Date(timeIntervalSince1970: 2_000_000)

private func msg(
    _ id: String, chat: Int, at seconds: TimeInterval, isFromMe: Bool = false, isSelfThread: Bool = false
) -> ChatMessage {
    ChatMessage(
        id: id, chatId: chat, isFromMe: isFromMe, text: "text \(id)", createdAt: t0.addingTimeInterval(seconds),
        senderAddress: isFromMe ? nil : "+1555000\(chat)", isSelfThread: isSelfThread
    )
}

func registerBatchTests(_ runner: TestRunner) {
    runner.suite("closeBatches (pure)") { r in
        r.run("a Chat quiet for the quiet window closes as one Batch, oldest first") {
            let messages = [msg("b", chat: 1, at: 5, isFromMe: true), msg("a", chat: 1, at: 0)]
            let result = closeBatches(messages, now: t0.addingTimeInterval(5 + batchQuietWindow))
            try expect(result.closed.map(\.memberIds) == [["a", "b"]])
            try expect(result.closed.first?.id == "b", "a Batch is named for its newest message")
            try expect(result.nextClosingAt == nil)
        }
        r.run("a Chat still inside its quiet window stays open, with the right closing time") {
            let messages = [msg("a", chat: 1, at: 0), msg("b", chat: 1, at: 10)]
            let result = closeBatches(messages, now: t0.addingTimeInterval(15))
            try expect(result.closed.isEmpty)
            try expect(result.nextClosingAt == t0.addingTimeInterval(10 + batchQuietWindow))
        }
        r.run("a Chat that keeps going closes at the cap") {
            let messages = stride(from: 0.0, through: batchCap, by: 12).map { msg("m\(Int($0))", chat: 1, at: $0) }
                .prefix(maxBatchMessages - 1).map { $0 }
            let last = messages[messages.count - 1].createdAt
            let atCap = t0.addingTimeInterval(batchCap)
            try expect(last.addingTimeInterval(batchQuietWindow) > atCap, "the fixture must still be busy at the cap")
            try expect(closeBatches(messages, now: atCap.addingTimeInterval(-1)).closed.isEmpty)
            try expect(closeBatches(messages, now: atCap).closed.count == 1)
        }
        r.run("two Chats close independently") {
            let messages = [msg("a", chat: 1, at: 0), msg("b", chat: 2, at: 30)]
            let result = closeBatches(messages, now: t0.addingTimeInterval(30))
            try expect(result.closed.map(\.id) == ["a"])
            try expect(result.nextClosingAt == t0.addingTimeInterval(30 + batchQuietWindow))
        }
        r.run("Self-thread notes are each their own Batch and close at once") {
            let messages = [
                msg("n1", chat: 9, at: 0, isFromMe: true, isSelfThread: true),
                msg("n2", chat: 9, at: 1, isFromMe: true, isSelfThread: true),
            ]
            let result = closeBatches(messages, now: t0.addingTimeInterval(1))
            try expect(result.closed.map(\.memberIds) == [["n1"], ["n2"]])
            try expect(result.nextClosingAt == nil)
        }
        r.run("messages already older than the quiet window at launch close at once") {
            let messages = [msg("a", chat: 1, at: 0), msg("b", chat: 1, at: 1)]
            let result = closeBatches(messages, now: t0.addingTimeInterval(3600))
            try expect(result.closed.map(\.memberIds) == [["a", "b"]])
        }
        r.run("a long run is split into Batches of at most maxBatchMessages, and a full one closes early") {
            let messages = (0..<(maxBatchMessages + 2)).map { msg("m\($0)", chat: 1, at: Double($0)) }
            let result = closeBatches(messages, now: t0.addingTimeInterval(Double(maxBatchMessages + 2)))
            try expect(result.closed.map(\.messages.count) == [maxBatchMessages])
            try expect(result.nextClosingAt != nil, "the remaining two are still open")
        }
        r.run("a pause of the quiet window or longer inside one Chat starts a new Batch") {
            let messages = [msg("a", chat: 1, at: 0), msg("b", chat: 1, at: 5), msg("c", chat: 1, at: 3600)]
            let result = closeBatches(messages, now: nil)
            try expect(result.closed.map(\.memberIds) == [["a", "b"], ["c"]])
        }
        r.run("with no clock, everything counts as closed") {
            let messages = [msg("a", chat: 1, at: 0), msg("b", chat: 2, at: 0)]
            try expect(closeBatches(messages, now: nil).closed.count == 2)
        }
    }
}
