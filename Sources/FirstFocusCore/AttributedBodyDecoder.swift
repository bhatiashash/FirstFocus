import Foundation

/// Byte-scan heuristic for `message.attributedBody`'s typedstream blob, not
/// a full typedstream decoder — the consumer is only a ranking function and
/// a one-line row, so cheap-and-observable beats a correct-by-construction
/// parser for a format Apple documents nowhere. See ticket 10.
///
/// Finds the last `NSString`/`NSMutableString` class marker in the blob
/// (later occurrences win over earlier ones — later is the actual message
/// body, earlier ones are typically attribute-dictionary keys), then tries
/// each of the next few bytes as a length prefix, in both the single-byte
/// and the `0x81`-escaped two-byte-little-endian forms, and keeps whichever
/// interpretation decodes the longest valid UTF-8 run.
///
/// Validated against the real snapshot (1,310 self-thread messages with
/// null `text`): zero outright failures, and message content came through
/// cleanly across a random sample. Two known, accepted imperfections
/// rather than bugs to chase further, matching the lossy-by-design posture
/// ticket 10 settled on: some link-preview messages (Google/YouTube URLs
/// in particular) decode with one stray leading character ahead of the
/// real text, and an attachment-only message decodes to just `\u{FFFC}`
/// (Unicode's object-replacement placeholder), which is correct — that's
/// genuinely what's there. Neither affects ranking or a one-line row.
///
/// A narrow 8-byte search window, tried empirically against real data: a
/// wider window reaches far enough into the trailing attribute-dictionary
/// structure to find coincidental longer "valid UTF-8" garbage that beats
/// a correct but very short (one- or two-character) real message.
///
/// Raw bytes in, text or `nil` out — no database types anywhere near this
/// function. `nil` means the caller should drop the message, not surface
/// it with placeholder text.
public func decodeAttributedBody(_ data: Data) -> String? {
    let bytes = [UInt8](data)
    guard let markerEnd = lastClassMarkerEnd(in: bytes) else {
        return nil
    }

    let searchWindow = 8
    let searchStart = markerEnd
    let searchEnd = min(bytes.count, searchStart + searchWindow)
    guard searchStart < searchEnd else { return nil }

    var best: String?

    for offset in searchStart..<searchEnd {
        if let decoded = decodeSingleByteLength(bytes: bytes, at: offset), isLonger(decoded, than: best) {
            best = decoded
        }
        if let decoded = decodeWideLength(bytes: bytes, at: offset), isLonger(decoded, than: best) {
            best = decoded
        }
    }

    return best
}

private func isLonger(_ candidate: String, than current: String?) -> Bool {
    guard let current else { return true }
    return candidate.utf8.count > current.utf8.count
}

/// Byte index just past the last "NSString" or "NSMutableString" ASCII run
/// in the blob, whichever occurs later.
private func lastClassMarkerEnd(in bytes: [UInt8]) -> Int? {
    let markers = [Array("NSMutableString".utf8), Array("NSString".utf8)]
    var bestEnd: Int?
    for marker in markers {
        if let range = lastRange(of: marker, in: bytes) {
            let end = range.upperBound
            bestEnd = bestEnd.map { Swift.max($0, end) } ?? end
        }
    }
    return bestEnd
}

/// Scans backward from the end without allocating, so a blob costs one
/// pass over its bytes. This runs for every message with a null `text` in
/// every chat on every Messages pass; building an `Array` slice at each
/// position made a large chat.db take minutes.
private func lastRange(of pattern: [UInt8], in bytes: [UInt8]) -> Range<Int>? {
    guard let first = pattern.first, bytes.count >= pattern.count else { return nil }
    var start = bytes.count - pattern.count
    while start >= 0 {
        if bytes[start] == first {
            var offset = 1
            while offset < pattern.count, bytes[start + offset] == pattern[offset] { offset += 1 }
            if offset == pattern.count { return start..<(start + pattern.count) }
        }
        start -= 1
    }
    return nil
}

/// `[length byte][length bytes of UTF-8]`, length < 0x80 (0x81 is reserved
/// as the wide-length escape, so a byte at or above it is never a valid
/// short length).
private func decodeSingleByteLength(bytes: [UInt8], at index: Int) -> String? {
    guard index < bytes.count else { return nil }
    let length = Int(bytes[index])
    guard length > 0, length < 0x81 else { return nil }
    let payloadStart = index + 1
    let payloadEnd = payloadStart + length
    guard payloadEnd <= bytes.count else { return nil }
    return String(bytes: bytes[payloadStart..<payloadEnd], encoding: .utf8)
}

/// `[0x81][length low byte][length high byte][length bytes of UTF-8]`,
/// little-endian 16-bit length.
private func decodeWideLength(bytes: [UInt8], at index: Int) -> String? {
    guard index + 2 < bytes.count, bytes[index] == 0x81 else { return nil }
    let length = Int(bytes[index + 1]) | (Int(bytes[index + 2]) << 8)
    guard length > 0 else { return nil }
    let payloadStart = index + 3
    let payloadEnd = payloadStart + length
    guard payloadEnd <= bytes.count else { return nil }
    return String(bytes: bytes[payloadStart..<payloadEnd], encoding: .utf8)
}
