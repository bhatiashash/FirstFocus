import FirstFocusCore
import Foundation

/// `ChatDBMessagesSource.listMessages` decodes the attributed body of every
/// message in chat.db with a null `text`, in every chat, on every Messages
/// pass. The decode has to stay linear in the blob.

/// A blob shaped like Messages': header, the class marker, the text, then
/// `trailing` bytes of attribute-dictionary structure after it.
private func blob(text: String, trailing: Int) -> Data {
    var bytes: [UInt8] = Array("streamtyped".utf8) + [0x81, 0xe8, 0x03, 0x84, 0x01, 0x40]
    bytes += Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84, 0x08] + Array("NSObject".utf8) + [0x00]
    bytes += [0x85, 0x92, 0x84, 0x84, 0x84, 0x08] + Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2b]
    let payload = Array(text.utf8)
    bytes.append(UInt8(payload.count))
    bytes += payload
    bytes += [0x86, 0x84, 0x02, 0x69, 0x49, 0x01]
    // Attribute dictionary filler with no class marker in it.
    for index in 0..<trailing { bytes.append(UInt8(0x20 + index % 90)) }
    return Data(bytes)
}

func registerDecodeSpeedTests(_ runner: TestRunner) {
    runner.suite("decodeAttributedBody: stays fast on a whole chat.db") { r in
        r.run("decodes 3,000 blobs of 6 KB correctly, in a couple of seconds") {
            let blobs = (0..<3000).map { blob(text: "Pick up dry cleaning \($0)", trailing: 6000) }
            let started = Date()
            let decoded = blobs.map(decodeAttributedBody)
            let elapsed = Date().timeIntervalSince(started)
            try expect(decoded[0] == "Pick up dry cleaning 0" && decoded[2999] == "Pick up dry cleaning 2999")
            try expect(elapsed < 2, "took \(elapsed)s")
        }
    }
}
