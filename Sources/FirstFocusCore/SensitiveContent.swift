import Foundation

/// Ticket 02, Rule B: a message that reads as a one-time code or similar
/// machine-generated content. Heuristic-only, by design — an OTP doesn't
/// need a model call to recognize, and never gets one (see
/// `Extraction.swift`). Requires both a code-adjacent keyword and a digit
/// run of at least four, so a bare mention of "code" (asking about a door
/// code, say) or a bare phone number doesn't false-positive on its own.
public func isCodePattern(_ text: String) -> Bool {
    let lowercased = text.lowercased()
    guard codeKeywords.contains(where: { lowercased.contains($0) }) else { return false }
    return containsDigitRun(text, minLength: 4)
}

private let codeKeywords: Set<String> = [
    "code", "otp", "passcode", "verification", "one-time", "2fa", "authentication code",
]

private func containsDigitRun(_ text: String, minLength: Int) -> Bool {
    var run = 0
    for character in text {
        if character.isNumber {
            run += 1
            if run >= minLength { return true }
        } else {
            run = 0
        }
    }
    return false
}

/// Ticket 02, Rule A: an explicit confidentiality instruction inside an
/// otherwise ordinary message ("don't share this," "keep this between
/// us"). Exact-phrase matching only, like `isWorthExtracting`'s
/// acknowledgment list — this is the cheap first pass; a phrasing that
/// slips past it still has a chance to be caught by the model, whose
/// system prompt is instructed to treat a confidentiality ask as NONE
/// (`LlamaCppIntentExtractor`), which is what "model as backstop" means
/// here — there's no separate classification call.
public func isConfidentialityTrigger(_ text: String) -> Bool {
    let lowercased = text.lowercased()
    return confidentialityPhrases.contains { lowercased.contains($0) }
}

private let confidentialityPhrases: Set<String> = [
    "don't tell anyone", "dont tell anyone", "don't tell anybody", "dont tell anybody",
    "don't share this", "dont share this", "don't share it", "dont share it",
    "keep this between us", "just between us", "keep this a secret", "keep this private",
    "don't send this to anyone", "dont send this to anyone",
]
