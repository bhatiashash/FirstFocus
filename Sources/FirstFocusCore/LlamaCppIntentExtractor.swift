import Foundation
import LlamaSwift

public enum LlamaCppIntentExtractorError: Error {
    case modelFileNotFound(path: String)
    case modelLoadFailed
    case contextCreationFailed
    case tokenizationFailed
    case promptTooLong(tokenCount: Int, contextSize: Int)
    case decodeFailed
}

/// Production `IntentExtractor`, backed by llama.cpp (via the `LlamaSwift`
/// package's precompiled XCFramework — confirmed to need no local Metal
/// shader compilation, unlike MLX Swift, which this machine can't build
/// because it has no `Xcode.app`).
///
/// The model loads once at `init`, and one context stays open for the
/// object's whole life rather than one per call — llama.cpp's context setup
/// (allocating KV cache buffers) is too heavy to redo per message the way
/// v1's Foundation Models adapter opened a fresh session per call. The
/// system turn's tokens stay in the KV cache between calls (ADR 0037), and
/// each call removes everything after them before evaluating its own user
/// turn, which keeps the "no cross-message bleed" guarantee that clearing
/// the whole cache used to give, without reprocessing ~1,000 tokens of
/// instructions per message.
///
/// `@unchecked Sendable`: the underlying `llama_context` isn't safe for
/// concurrent calls, but nothing in this codebase calls `extract(from:)`
/// concurrently — `AppModel` always awaits one message at a time in a
/// sequential loop (see `Extraction.swift`).
public final class LlamaCppIntentExtractor: IntentExtractor, FreeTextGenerating, @unchecked Sendable {
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let modelPath: String
    /// Serializes `extract(from:)`'s native calls (`llama_memory_clear`,
    /// `llama_decode`) against the one shared `context` and its KV cache.
    /// This class documents itself as never called concurrently, but
    /// nothing previously enforced that: two refresh triggers firing close
    /// together (very plausible right at launch — a `.foreground` trigger,
    /// the repeating timer's first tick, and an EventKit change can all
    /// land within the same moment) each spawn their own `Task`, and if
    /// both reach `extract(from:)` before the first finishes, they race on
    /// the same Metal command state. Reproduced directly: two concurrent
    /// `extract(from:)` calls against a freshly loaded model crash with
    /// `EXC_BAD_ACCESS` inside `ggml_metal_op_rope`, deterministically, on
    /// the first attempt — the same crash signature this fixes. Held only
    /// across the fully-synchronous native-call span inside each `Task`'s
    /// closure, never across an `await`, so a second caller simply waits
    /// its turn rather than deadlocking.
    private let decodeLock = NSLock()
    /// Guards the small bits of state read outside `decodeLock` (the
    /// system-turn token-count memo), so reading the budget never waits
    /// behind a decode that takes seconds.
    private let stateLock = NSLock()
    private var systemTurnCountCache: (text: String, count: Int)?
    /// Approved Rules (ADR 0038), guarded by `stateLock`.
    private var rules: [String] = []
    /// Set by `invalidateCachedPrefix()`, guarded by `stateLock`; read and
    /// cleared by `preparePrefix`, which runs under `decodeLock`.
    private var prefixInvalidated = false
    /// The system turn whose tokens currently sit at the front of the KV
    /// cache, and how many there are (ADR 0037). Only touched with
    /// `decodeLock` held.
    private var cachedPrefix: (text: String, length: Int)?

    /// The `.gguf` filename without its extension — a catalog entry's
    /// friendlier name when it matches one (`ModelCatalog.displayName`
    /// applies that on top of this), the filename itself otherwise, e.g. for
    /// a model chosen outside the catalog via the file picker.
    public var modelDisplayName: String {
        let filename = (modelPath as NSString).lastPathComponent
        return ModelCatalog.displayName(
            forFilename: filename,
            fallback: filename.hasSuffix(".gguf") ? String(filename.dropLast(".gguf".count)) : filename
        )
    }

    /// Sized against real measurement (ticket 05), revised after
    /// re-extraction against real candidate messages (not just synthetic
    /// examples) turned up prompts as long as ~1420 tokens — longer than
    /// the synthetic "long pasted block" and "full 6-message context"
    /// cases this was originally sized against, which only reached ~940
    /// and ~880. 1536 leaves real headroom above that measured real-data
    /// max plus the generation budget below (`evaluate(_:into:)` now
    /// reserves that budget explicitly, rather than only checking the
    /// prompt fits), while still well under the original 2048 that was
    /// never sized against anything. A prompt that still doesn't fit
    /// fails closed via `promptTooLong` — a footprint reduction, not a
    /// new failure mode.
    ///
    /// Raised back to 2048 by ADR 0037, this time sized against something:
    /// the system turn alone measured 1,021 tokens on Qwen3-4B, leaving 451
    /// for Corrections, context and the message at 1536, and approved Rules
    /// (ADR 0038) now take room in that same fixed turn. The extra 512
    /// tokens cost about 75 MB of KV cache.
    private let contextSize: UInt32 = 2048
    /// A real Label batch tops out at a handful of short imperative lines
    /// plus an optional `DUE_TEXT:` line — a quoted phrase instead of a
    /// bare date adds a few tokens, but nowhere near 128 tokens' worth.
    /// Greedy sampling already stops at EOS well before hitting this cap
    /// in the common case (see the loop in `extract(from:)`); this is the
    /// ceiling for the rare batch that doesn't, not the size of a typical
    /// response.
    private let maxGeneratedTokens = 64
    private let promptOverride: String?

    /// The default extraction instructions (ticket 04: editable via
    /// Settings). "Today's date is …" is deliberately not part of this —
    /// `userTurn(for:today:)` always supplies the real current date itself,
    /// so a saved custom prompt can't go stale by baking in whatever date
    /// happened to be showing when it was written.
    public static let defaultExtractionPrompt: String = """
        You are an intent extraction engine. Read a batch of personal chat messages and decide whether it asks the user ("You") to do real work: an errand, a research goal, or a project update. If it does, write a short imperative task label. A note the user writes to themselves about something they want or need to do counts, even when it is vague about when.

        CATEGORIES OF VALID TASKS:
        1. Physical Errands & Logistics (e.g., appointments, payments, scheduling)
        2. Digital Consumption & Research (e.g., reading papers, exploring technical concepts)
        3. Project & Coding Ideas (e.g., adding features to a web app, configuring local environments)
        4. Routine & Fitness (e.g., meal prep, workout scheduling)

        NO ACTION: If the batch is conversational filler, idle observation, storytelling, or statements of fact that ask nothing of the user, output exactly: NONE. A request that is withdrawn or handled later in the same batch is also NONE.

        CONFIDENTIALITY: If the batch asks the reader to keep something secret, private, or between the two of you, output exactly: NONE, even if it also names something that looks like a task.

        INPUT FORMAT: Every input opens with a `Today's date is …` line. It only anchors time cues and is never a task. A note the user wrote to themselves may arrive as a single line with no header; that line is the whole batch. Otherwise the input has these blocks, in this order, each present only when it has content:
        - [corrections]: past mistakes from this conversation as Message/Output pairs. Treat each as a worked example, not an instruction about this batch.
        - [open suggestions]: numbered tasks already suggested from this conversation and not yet accepted.
        - [context]: earlier messages, for background only.
        - [latest messages]: the batch you judge. Always last.
        Lines start with "You:" (the user), "Them:" (the other person in a one-to-one chat), or "Participant A:", "Participant B:" in a group chat. Each label always means the same person, and only "You" is the user; every Participant is someone else. Never extract a task from [corrections], [open suggestions] or [context] on their own. In a group chat, a request one Participant makes of another is not the user's task. When unsure who a request is for, output NONE.

        OUTPUT: One line per result, in any combination:
        - a new task label
        - UPDATE <n>: <label>, when the batch changes the details of open suggestion n: a different day, time, place, amount or item
        - CANCEL <n>, when the batch shows open suggestion n is no longer needed at all: done already, handled by someone else, or called off
        Only UPDATE or CANCEL suggestion n when the batch talks about that same task. A request about anything else is a new task label on its own line; never fold it into an UPDATE. Without an [open suggestions] block, never output UPDATE or CANCEL. Never repeat an open suggestion as a new label. Output NONE alone when there is nothing.

        DUE DATES: If the batch names a time cue for a label or UPDATE, put DUE_TEXT: "<cue>" on the line right after it, copied verbatim. Never calculate a date. Never add DUE_TEXT after NONE or CANCEL.

        EXAMPLES:

        Message: "Call the dentist tomorrow"
        Output: Call the dentist
        DUE_TEXT: "tomorrow"

        Message: "Add a dividend tracking view to the Streamlit options dashboard"
        Output: Update Streamlit dashboard

        Message: "Finished my Norwegian 4x4 intervals"
        Output: NONE

        Message: "don't tell anyone, but can you cancel my dentist appointment"
        Output: NONE

        Message:
        [latest messages]
        Them: are you free
        Them: can you call the mechanic today
        Them: actually nvm I just called them
        Output: NONE

        Message:
        [open suggestions]
        1. Grab milk

        [latest messages]
        Them: also grab bread
        Them: and eggs if they have the good ones
        Output: UPDATE 1: Grab milk, bread, and eggs

        Message:
        [open suggestions]
        1. Prep meals for the week

        [latest messages]
        You: I don't think I have time for the super veggie prep today
        Them: No worries, just do the Nutty Pudding
        Output: UPDATE 1: Prep Nutty Pudding

        Message:
        [open suggestions]
        1. Renew the parking permit

        [latest messages]
        Them: can you also send me the wifi password
        Output: Send the wifi password

        Message:
        [open suggestions]
        1. Book badminton court

        [latest messages]
        Them: I already booked the court
        Them: can you send me the invoice by Friday
        Output: CANCEL 1
        Send the invoice
        DUE_TEXT: "by Friday"

        Message:
        [latest messages]
        Participant B: Participant A, can you send the slides tonight
        Output: NONE

        Message:
        [latest messages]
        Them: Did you see the game?
        Them: Crazy ending
        Them: Call me when you have a sec
        Output: Call back
        DUE_TEXT: "when you have a sec"

        Judge the following input. Output only the lines described under OUTPUT, or NONE.
        """

    /// Either the stored override (ticket 04's Settings text editor) or
    /// `defaultExtractionPrompt`. A blank or whitespace-only override is
    /// treated the same as no override at all — clearing the field in
    /// Settings falls back to the default rather than sending the model
    /// empty instructions. Holds nothing that changes on its own (ADR 0037):
    /// the date lives in `userTurn(for:today:)`, so this text, and the
    /// tokens cached from it, only change when the user changes them.
    private static func instructions(promptOverride: String?) -> String {
        let trimmedOverride = promptOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmedOverride?.isEmpty == false ? trimmedOverride : nil) ?? defaultExtractionPrompt
    }

    /// Where model files live: alongside `SQLiteSignalStore`'s own
    /// `store.sqlite`, under this bundle's Application Support directory —
    /// outside the vault, consistent with how the rest of FirstFocus's local
    /// state is kept. Exposed on its own (rather than only as a prefix of
    /// `defaultModelPath`) so callers that need the directory itself, like
    /// Settings' "Open in Finder" link, don't have to re-derive it by
    /// stripping the filename back off a file path.
    public static func modelsDirectoryURL(bundleIdentifier: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(bundleIdentifier).appendingPathComponent("models")
    }

    public static func defaultModelPath(bundleIdentifier: String) -> String {
        modelsDirectoryURL(bundleIdentifier: bundleIdentifier)
            .appendingPathComponent("Qwen3-4B-Instruct-2507-Q4_K_M.gguf")
            .path
    }

    /// `llama_backend_init()` is documented as a once-per-process call, not
    /// once-per-instance; a Swift `static let` initializer is guaranteed to
    /// run exactly once, thread-safely, which is the closest match this
    /// language has to that contract. There's no paired
    /// `llama_backend_free()` anywhere — this app has no clean single
    /// shutdown hook to call it from, the same reason `EventKitTaskSource`
    /// never tears down its `EKEventStore` either.
    private static let backendInitialized: Void = { llama_backend_init() }()

    /// `promptOverride` (ticket 04): `nil` by default so every existing
    /// call site — including every test that constructs this type — keeps
    /// using `defaultExtractionPrompt` unchanged. `AppModel` is the one
    /// caller that passes a real value, read from `ExtractionSettings`.
    public init(modelPath: String, promptOverride: String? = nil) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw LlamaCppIntentExtractorError.modelFileNotFound(path: modelPath)
        }
        self.modelPath = modelPath
        self.promptOverride = promptOverride

        _ = Self.backendInitialized

        var modelParams = llama_model_default_params()
        // Explicit rather than relying on whatever `llama_model_default_params()`
        // happens to default to (ticket 05): measured on this machine, the
        // implicit default already offloads every layer to Metal — this
        // just makes that fact a visible part of this file instead of an
        // assumption riding on the library's current default, which a
        // future llama.cpp/llama.swift version bump could silently change
        // without showing up in any diff here. Negative means "all layers"
        // (llama.h's own doc comment on `n_gpu_layers`).
        modelParams.n_gpu_layers = -1
        guard let loadedModel = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaCppIntentExtractorError.modelLoadFailed
        }
        model = loadedModel
        vocab = llama_model_get_vocab(loadedModel)

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = contextSize
        contextParams.n_batch = contextSize
        guard let createdContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            throw LlamaCppIntentExtractorError.contextCreationFailed
        }
        context = createdContext
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    /// `priority` (ticket: extraction QoS) only ever governs *this* Task,
    /// spawned fresh per call rather than reused: the C-API work below has
    /// no suspension points of its own, so without this wrapper it would
    /// simply run wherever the caller's own context already is — which for
    /// every call in this app today is `SignalBoard`, `@MainActor`, i.e.
    /// the main thread, regardless of what priority the caller's own Task
    /// happened to carry. Spawning an unstructured, non-actor-isolated
    /// `Task(priority:)` here and awaiting its `.value` is what actually
    /// moves the work onto the concurrent thread pool at the requested QoS
    /// — the priority has to be set at the point the blocking work begins,
    /// not just at the point the caller happens to kick it off.
    public func extract(from text: String, priority: TaskPriority) async throws -> String {
        try await Task(priority: priority) { [self] in
            try decodeLock.withLock {
                try generate(
                    systemTurn: currentSystemTurn(),
                    userTurn: Self.userTurn(for: text, today: Date()),
                    maxTokens: maxGeneratedTokens
                )
            }
        }.value
    }

    /// ADR 0038's Rule proposals: the same context and decode lock as
    /// extraction, with the caller's own system prompt. That system turn
    /// replaces the cached extraction prefix, so the next extraction
    /// recomputes its own on the text mismatch alone.
    public func generateText(system: String, user: String, maxTokens: Int, priority: TaskPriority) async throws -> String {
        try await Task(priority: priority) { [self] in
            try decodeLock.withLock {
                try generate(
                    systemTurn: "<|im_start|>system\n\(system)<|im_end|>\n",
                    userTurn: "<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n",
                    maxTokens: maxTokens
                )
            }
        }.value
    }

    /// ADR 0038: replaces the Rules this extractor puts in its system turn.
    /// The next call sees a different system turn text, so the cached
    /// prefix is recomputed on its own; the model is never reloaded.
    public func setRules(_ rules: [String]) {
        stateLock.withLock { self.rules = rules }
    }

    private func currentSystemTurn() -> String {
        Self.systemTurn(promptOverride: promptOverride, rules: stateLock.withLock { rules })
    }

    /// Marks the cached system turn stale, so the next call recomputes it
    /// even if its text hasn't changed (ADR 0037). Safe to call from any
    /// thread; never waits behind a running decode.
    public func invalidateCachedPrefix() {
        stateLock.withLock { prefixInvalidated = true }
    }

    /// One generation against the shared context. Must be called with
    /// `decodeLock` held. The system turn's tokens are reused from the KV
    /// cache when `systemTurn` matches what's cached (ADR 0037): everything
    /// after the prefix is removed, so nothing from the previous call's user
    /// turn or output survives into this one, and only `userTurn` is
    /// evaluated. A different `systemTurn`, or an invalidated prefix,
    /// clears the cache and recomputes it first.
    private func generate(systemTurn: String, userTurn: String, maxTokens: Int) throws -> String {
        let userTokens = try tokenize(userTurn, addSpecial: false)
        // Fails closed before any decode, as before ADR 0037, including the
        // prefix decode a cache miss would do: a prompt that doesn't leave
        // room for the whole generation budget is rejected rather than
        // discovered mid-generation.
        let expectedLength = systemTurnTokenCount(for: systemTurn) + userTokens.count
        guard expectedLength + maxTokens <= Int(contextSize) else {
            throw LlamaCppIntentExtractorError.promptTooLong(tokenCount: expectedLength, contextSize: Int(contextSize))
        }
        let prefixLength = try preparePrefix(systemTurn)
        let promptLength = prefixLength + userTokens.count

        var batch = llama_batch_init(Int32(contextSize), 0, 1)
        defer { llama_batch_free(batch) }

        try evaluate(userTokens, startingAt: Int32(prefixLength), into: &batch)

        var generated = ""
        var position = Int32(promptLength)

        for _ in 0..<maxTokens {
            let nextToken = try sampleGreedy(lastLogitsIndex: batch.n_tokens - 1)
            if nextToken == llama_vocab_eos(vocab) {
                break
            }

            // 128 bytes comfortably covers any single subword token's
            // UTF-8 text. A token piece that still doesn't fit
            // (`length <= 0`) is dropped rather than retried with a
            // larger buffer — the same "skip the byte, never crash"
            // posture `AttributedBodyDecoder` takes on its own
            // known-quirky inputs.
            var buffer = [CChar](repeating: 0, count: 128)
            let length = llama_token_to_piece(vocab, nextToken, &buffer, Int32(buffer.count), 0, false)
            if length > 0 {
                let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
                generated += String(decoding: bytes, as: UTF8.self)
            }

            batch.n_tokens = 1
            batch.token[0] = nextToken
            batch.pos[0] = position
            batch.n_seq_id[0] = 1
            if let seqIds = batch.seq_id, let seqId = seqIds[0] {
                seqId[0] = 0
            }
            batch.logits[0] = 1
            position += 1

            guard llama_decode(context, batch) == 0 else {
                throw LlamaCppIntentExtractorError.decodeFailed
            }
        }

        return generated
    }

    /// Leaves the KV cache holding exactly `systemTurn`'s tokens at positions
    /// 0..<n and returns n. Must be called with `decodeLock` held.
    private func preparePrefix(_ systemTurn: String) throws -> Int {
        let memory = llama_get_memory(context)
        let invalidated = stateLock.withLock { () -> Bool in
            defer { prefixInvalidated = false }
            return prefixInvalidated
        }
        if !invalidated, let cached = cachedPrefix, cached.text == systemTurn,
           llama_memory_seq_rm(memory, 0, Int32(cached.length), -1) {
            return cached.length
        }

        // Cleared before recomputing, and the record dropped first, so a
        // failure part-way through leaves nothing that looks reusable: the
        // next call starts again from an empty cache.
        cachedPrefix = nil
        llama_memory_clear(memory, true)
        let tokens = try tokenize(systemTurn, addSpecial: true)
        guard tokens.count + maxGeneratedTokens <= Int(contextSize) else {
            throw LlamaCppIntentExtractorError.promptTooLong(tokenCount: tokens.count, contextSize: Int(contextSize))
        }
        var batch = llama_batch_init(Int32(contextSize), 0, 1)
        defer { llama_batch_free(batch) }
        try evaluate(tokens, startingAt: 0, into: &batch)
        cachedPrefix = (systemTurn, tokens.count)
        return tokens.count
    }

    /// Qwen3's chat format, hand-built rather than through
    /// `llama_chat_apply_template` (which only recognizes a fixed list of
    /// known templates, not an arbitrary Jinja one, and Qwen3's presence on
    /// that list isn't guaranteed across llama.cpp versions). `public` and
    /// pure so it's independently testable — there is no other adapter-
    /// internal seam here worth a fake, since everything past this point is
    /// direct C API calls.
    /// The whole prompt `extract(from:)` sends: `systemTurn` then
    /// `userTurn`, split at the one boundary prefix reuse (ADR 0037) keys on.
    public static func chatMLPrompt(
        for text: String, today: Date = Date(), promptOverride: String? = nil, rules: [String] = []
    ) -> String {
        systemTurn(promptOverride: promptOverride, rules: rules) + userTurn(for: text, today: today)
    }

    /// The cacheable prefix (ADR 0037): byte-identical for a given prompt
    /// text and Rule set on every call, on every day.
    public static func systemTurn(promptOverride: String? = nil, rules: [String] = []) -> String {
        "<|im_start|>system\n\(withRules(rules, in: instructions(promptOverride: promptOverride)))<|im_end|>\n"
    }

    /// Approved Rules (ADR 0038) under their own heading, placed after the
    /// instructions and before the worked examples, so the model reads them
    /// as instructions rather than as one more example. A custom prompt with
    /// no EXAMPLES section gets them at the end. No Rules, no change.
    private static func withRules(_ rules: [String], in instructions: String) -> String {
        guard !rules.isEmpty else { return instructions }
        let block = "RULES (approved by the user; follow them in every conversation):\n"
            + rules.map { "- \($0)" }.joined(separator: "\n")
        guard let examples = instructions.range(of: "\n\nEXAMPLES:") else {
            return instructions + "\n\n" + block
        }
        return instructions[..<examples.lowerBound] + "\n\n" + block + instructions[examples.lowerBound...]
    }

    /// Everything that changes per call: today's date, anchoring relative
    /// time cues (ticket 01's date-only anchoring requirement, moved here
    /// from the system turn by ADR 0037), then the composed message text,
    /// then the open assistant turn the model continues from.
    public static func userTurn(for text: String, today: Date = Date()) -> String {
        let todayString = plainDateFormatter().string(from: today)
        return "<|im_start|>user\nToday's date is \(todayString).\n\n\(text)<|im_end|>\n<|im_start|>assistant\n"
    }

    /// `IntentExtractor.estimatedTokenCount(for:)`: tokenizes `text` alone,
    /// not the full ChatML-wrapped prompt `extract(from:)` actually sends —
    /// comparable against `maxPromptTokens`, which already backs out the
    /// fixed system-prompt overhead below. `Int.max` on failure keeps this
    /// fail-closed: a caller trimming Corrections against this treats a
    /// failed estimate as "still too long," never as "plenty of room."
    public func estimatedTokenCount(for text: String) -> Int {
        (try? tokenize(text))?.count ?? Int.max
    }

    /// `IntentExtractor.maxPromptTokens`: `contextSize`, minus the
    /// generation headroom `evaluate(_:into:)` already reserves, minus the
    /// fixed overhead around the message (the system turn, plus the user
    /// turn's wrapper and date line) — what's actually left for
    /// `formatForExtraction`'s composed context/corrections/target text.
    /// The system turn's count is tokenized once per system-turn text
    /// rather than on every access (ADR 0037); only the short user-turn
    /// wrapper, whose date changes daily, is tokenized each time.
    public var maxPromptTokens: Int {
        let systemTokens = systemTurnTokenCount(for: currentSystemTurn())
        let userOverhead = (try? tokenize(Self.userTurn(for: "", today: Date()), addSpecial: false))?.count ?? 0
        return max(0, Int(contextSize) - maxGeneratedTokens - systemTokens - userOverhead)
    }

    /// Memoized per system-turn text, so `maxPromptTokens` stops
    /// re-tokenizing the ~1,000-token system turn on every message. `Int.max`
    /// on failure keeps the budget fail-closed, same as
    /// `estimatedTokenCount(for:)`.
    private func systemTurnTokenCount(for systemTurn: String) -> Int {
        if let cached = stateLock.withLock({ systemTurnCountCache }), cached.text == systemTurn {
            return cached.count
        }
        let count = (try? tokenize(systemTurn, addSpecial: true))?.count ?? Int.max
        stateLock.withLock { systemTurnCountCache = (systemTurn, count) }
        return count
    }

    /// `addSpecial` adds the model's own start-of-text token where it has
    /// one: true for anything that starts a sequence, false for a user turn
    /// appended after an already-evaluated system turn (ADR 0037).
    private func tokenize(_ prompt: String, addSpecial: Bool = true) throws -> [llama_token] {
        let maxTokenCount = prompt.utf8.count + 16
        var tokens = [llama_token](repeating: 0, count: maxTokenCount)
        let tokenCount = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), &tokens, Int32(maxTokenCount), addSpecial, true)
        guard tokenCount > 0 else {
            throw LlamaCppIntentExtractorError.tokenizationFailed
        }
        return Array(tokens.prefix(Int(tokenCount)))
    }

    /// Evaluates `tokens` at positions `start...`, requesting logits only
    /// for the last one. Capacity is checked by the callers before this runs
    /// (`generate` and `preparePrefix`), which reserve the whole generation
    /// budget up front: a prompt that fits on its own but leaves less than
    /// that much headroom used to fail mid-generation instead, with
    /// `llama_decode` reporting "failed to find a memory slot", reproduced
    /// against real re-extraction candidates after ticket 05 tightened
    /// `contextSize`. Failing closed before any decode is strictly safer.
    private func evaluate(_ tokens: [llama_token], startingAt start: Int32, into batch: inout llama_batch) throws {
        batch.n_tokens = Int32(tokens.count)
        for i in 0..<tokens.count {
            batch.token[i] = tokens[i]
            batch.pos[i] = start + Int32(i)
            batch.n_seq_id[i] = 1
            if let seqIds = batch.seq_id, let seqId = seqIds[i] {
                seqId[0] = 0
            }
            batch.logits[i] = 0
        }
        if batch.n_tokens > 0 {
            batch.logits[Int(batch.n_tokens) - 1] = 1
        }
        guard llama_decode(context, batch) == 0 else {
            throw LlamaCppIntentExtractorError.decodeFailed
        }
    }

    private func sampleGreedy(lastLogitsIndex: Int32) throws -> llama_token {
        guard let logits = llama_get_logits_ith(context, lastLogitsIndex) else {
            throw LlamaCppIntentExtractorError.decodeFailed
        }
        let vocabSize = Int(llama_vocab_n_tokens(vocab))
        var bestLogit = logits[0]
        var bestToken: llama_token = 0
        for i in 1..<vocabSize where logits[i] > bestLogit {
            bestLogit = logits[i]
            bestToken = llama_token(i)
        }
        return bestToken
    }
}
