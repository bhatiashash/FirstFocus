import FirstFocusCore
import Foundation

private func loadFixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures/AttributedBody") else {
        throw TestFailure(message: "missing fixture Fixtures/AttributedBody/\(name).bin")
    }
    return try Data(contentsOf: url)
}

/// Hand-built typedstream-shaped bytes with two NSString class markers, to
/// exercise "the later marker wins" without depending on finding a real
/// multi-run message — none turned up in the real snapshot (also true of
/// ticket 08's multi-Signal case; a synthetic stand-in is the documented
/// precedent here).
private func syntheticMultiRunBlob() -> Data {
    var bytes: [UInt8] = []
    func appendRun(_ text: String) {
        bytes.append(contentsOf: Array("NSString".utf8))
        bytes.append(contentsOf: [0x01, 0x94, 0x84, 0x01]) // observed fixed header
        bytes.append(0x2b) // '+' marker
        let payload = Array(text.utf8)
        bytes.append(UInt8(payload.count))
        bytes.append(contentsOf: payload)
    }
    appendRun("FIRST")
    bytes.append(contentsOf: [0x86, 0x84, 0x02]) // filler, as real blobs carry between runs
    appendRun("SECOND")
    return Data(bytes)
}

func registerAttributedBodyDecoderTests(_ runner: TestRunner) {
    runner.suite("decodeAttributedBody") { r in
        r.run("a plain sentence decodes cleanly") {
            let data = try loadFixture("plain-sentence")
            try expect(decodeAttributedBody(data) == "Pick up dry cleaning before 6 today")
        }
        r.run("a short word decodes cleanly") {
            let data = try loadFixture("short-word")
            try expect(decodeAttributedBody(data) == "No")
        }
        r.run("a wide (0x81-escaped two-byte) length prefix decodes a long pasted message in full") {
            let data = try loadFixture("wide-length-pasted-recipe")
            let decoded = try require(decodeAttributedBody(data))
            try expect(decoded.hasPrefix("2. \u{1FAD8} Chickpea Curry"))
            try expect(decoded.hasSuffix("Tastes significantly better day 2 and 3"))
        }
        r.run("an attachment-only message decodes to the object-replacement placeholder") {
            let data = try loadFixture("attachment-placeholder")
            try expect(decodeAttributedBody(data) == "\u{FFFC}")
        }
        r.run("a multi-run blob decodes the later run, not the earlier one") {
            try expect(decodeAttributedBody(syntheticMultiRunBlob()) == "SECOND")
        }
        r.run("empty data decodes to nil rather than crashing") {
            try expect(decodeAttributedBody(Data()) == nil)
        }
        r.run("random bytes with no NSString marker decode to nil") {
            let garbage = Data([0x01, 0x02, 0x03, 0xFF, 0xFE, 0x00, 0x10, 0x20])
            try expect(decodeAttributedBody(garbage) == nil)
        }
        r.run("known accepted quirk: a one-character real message can decode to a stray marker char instead") {
            // Documented in AttributedBodyDecoder.swift: the narrow search
            // window that fixes longer messages colliding with trailing
            // garbage has this trade-off for messages this short. This
            // test pins the known behavior rather than an aspirational one.
            let data = try loadFixture("single-char")
            try expect(decodeAttributedBody(data) == "+")
        }
        r.run("known accepted quirk: some link previews decode with one stray leading character") {
            // This blob is a real com.apple.messages.URLBalloonProvider
            // message, which the ChatDBMessagesSource adapter excludes before
            // it ever reaches this decoder (a bare pasted link becomes a
            // rich balloon, not typed text). Kept as a fixture anyway
            // because it's a real, quirky blob worth the decoder handling
            // gracefully regardless of what the SQL layer routes to it.
            let data = try loadFixture("leading-stray-char-url")
            let decoded = try require(decodeAttributedBody(data))
            try expect(decoded.hasSuffix("youtube.com/watch?v=213rSCulKU"))
            try expect(decoded.hasPrefix("+"))
        }
    }
}
