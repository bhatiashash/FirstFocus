import FirstFocusCore
import Foundation

/// One row per category, one column per model, each cell the correct
/// count out of that category's runs.
private func categoryTable(firstColumn: String, categories: [String], modelResults: [ModelResult]) -> String {
    var out = "| \(firstColumn) | " + modelResults.map(\.displayName).joined(separator: " | ") + " |\n"
    out += "| --- |" + modelResults.map { _ in " --- |" }.joined() + "\n"
    for category in categories {
        var row = "| \(category) |"
        for result in modelResults {
            let runsInCategory = result.runs.filter { $0.item.category == category }
            guard !runsInCategory.isEmpty else {
                row += " — |"
                continue
            }
            let correct = runsInCategory.filter { $0.correctSignalDecision == true }.count
            row += " \(correct)/\(runsInCategory.count) |"
        }
        out += row + "\n"
    }
    return out + "\n"
}

func writeReport(modelResults: [ModelResult], syntheticItemCount: Int, realItemCount: Int, correctionItemCount: Int) {
    var out = ""
    out += "# FirstFocus Model Comparison Study\n\n"
    out += "Generated \(ISO8601DateFormatter().string(from: Date())) by `swift run -c release ModelEvaluator`.\n\n"

    out += "## Methodology Note\n\n"
    out += """
    This deviates from the spec in ways worth stating plainly, since each affects how much weight the numbers below should carry:

    1. **Corpus is mostly synthetic, not real History.** History held \(realItemCount) real row(s) at run time (0 starred) — nowhere near the 50 the spec assumed sampling from. \(syntheticItemCount) hand-written items make up the rest, covering the same categories (simple tasks, due dates, multi-task messages, zero-signal filler, the confidentiality rule, the context-block rule, edge cases) but designed to be judged against, not copied from, `LlamaCppIntentExtractor.defaultExtractionPrompt`'s own few-shot examples — reusing one of those verbatim would measure whether a model can repeat text already sitting in its own system prompt, not whether it generalizes. Any real rows found are run and logged, but never scored — there's no independent ground truth for them. The \(correctionItemCount) stored Correction(s) with a known right answer are the exception to "unscored": see Corrections below. They are kept out of the summary table so its numbers stay comparable with earlier runs. The text of every real row and Correction, and the models' output on them, is only in the Desktop CSV, never in this committed report.
    2. **One shared prompt template across all three models**, per the spec's own "exact same system prompt... to maintain experimental control." `LlamaCppIntentExtractor` hand-builds a ChatML-style prompt (`<|im_start|>...`) unconditionally. Qwen2.5-3B-Instruct and Qwen3-4B-Instruct are both Qwen-family models trained on ChatML, so this is their native format. Llama-3.2-3B-Instruct was trained on Meta's own Llama 3 chat template (`<|start_header_id|>`/`<|eot_id|>`), not ChatML — running it through the wrong template is a real, uncontrolled disadvantage baked into "experimental control," not a level playing field. Treat any gap where Llama-3.2 underperforms the two Qwen models with that in mind.
    3. **No literal stop-token string exists to check "format adherence" against.** The real stop condition is `extract(from:)` breaking its generation loop on the vocabulary's EOS token (or a 64-token cap). Format adherence here means: no leaked chat-template tokens, no leaked conversational filler (the spec's own "Here are your tasks:" example and close relatives), and well-formed `DUE_TEXT:` lines.
    4. **"Ms per token" is a whitespace-word estimate (~1.3 tokens/word), not `llama.cpp`'s real subword count.** Getting the exact figure means changing `LlamaCppIntentExtractor.extract(from:priority:)`'s return type to carry a token count — a production API change this one-off study didn't make. Treat the per-token figures as order-of-magnitude, not measured.
    5. **"Hallucination" is a word-overlap heuristic**, not semantic judgment: flagged only when a non-NONE label shares *zero* words with its source text, deliberately loose to keep false positives low. A real "does this logically map back to the source" call needs a human reading the transcript — this heuristic is a filter for where to look, not a verdict.
    6. **GPU utilization isn't in this report.** Process resident memory is (via Mach's `task_info`, no AppKit needed), but there's no standard-framework API for live Metal GPU utilization — the spec's own fallback ("otherwise focus strictly on time") is what this falls back to for that one figure specifically.


    """

    out += "## Comparative Summary\n\n"
    out += "| Model | Load Time | Memory (resident, +Δ) | Accuracy (task vs. NONE) | Zero-Signal Accuracy | Format Adherence | Possible Hallucinations | Avg Latency | Avg ms/token (est.) |\n"
    out += "| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n"
    for result in modelResults {
        if let loadError = result.loadError {
            out += "| \(result.displayName) | — | — | — | — | — | — | — | — (\(loadError)) |\n"
            continue
        }
        let scored = result.scoredRuns
        out += "| \(result.displayName) | \(seconds(result.loadSeconds)) | \(mb(result.residentMemoryDeltaMB)) "
        out += "| \(percent(result.accuracy)) (\(scored.filter { $0.correctSignalDecision == true }.count)/\(scored.count)) "
        out += "| \(percent(result.zeroSignalAccuracy)) (\(result.zeroSignalItems.filter { $0.correctSignalDecision == true }.count)/\(result.zeroSignalItems.count)) "
        out += "| \(percent(result.formatAdherenceRate)) | \(result.possibleHallucinationCount)/\(result.runs.count) "
        out += "| \(seconds(result.averageLatency)) | \(String(format: "%.0fms", result.averageMsPerEstimatedToken)) |\n"
    }
    out += "\n"

    out += "## Accuracy by Category\n\n"
    let categories = Array(Set(syntheticCorpus.map(\.category))).sorted()
    out += categoryTable(firstColumn: "Category", categories: categories, modelResults: modelResults)

    out += "## Corrections\n\n"
    out += "Each stored \"Not for me\" or \"Add task\" Correction, replayed with the input the model saw when it was recorded. \"Not for me\" expects NONE. \"Add task\" expects at least one task, whatever its wording; the Label you typed is in the CSV's `Typed_Label` column. \"This was work\" and field corrections are skipped.\n\n"
    let correctionCategories = [CorrectionType.falsePositive, .missedTask].map(correctionCategory)
    out += categoryTable(firstColumn: "Correction type", categories: correctionCategories, modelResults: modelResults)

    out += "## Cross-Model Discrepancies\n\n"
    out += "Items where the three models didn't agree on task-vs-NONE — the spec's own \"flag discrepancies where one model found a signal but another returned zero-Signals.\" Full detail (including which model) is in `FirstFocus_Model_Evaluation.csv`'s `Signal_Discrepancy` column; this is just the count.\n\n"
    if modelResults.count == 3, modelResults.allSatisfy({ $0.loadError == nil }) {
        let (a, b, c) = (modelResults[0].runs, modelResults[1].runs, modelResults[2].runs)
        let discrepancyCount = zip(zip(a, b), c).filter { pair, thirdRun in
            Set([pair.0.producedSignal, pair.1.producedSignal, thirdRun.producedSignal]).count > 1
        }.count
        out += "\(discrepancyCount) of \(a.count) items had at least one model disagree with the other two on whether the message contained a task at all.\n\n"
    }

    out += "## Qualitative Notes & Recommendation\n\n"
    out += "_Filled in by hand after reading the full transcript and CSV — not generated by this script._\n\n"

    out += "## Full Transcript\n\n"
    out += "Every call this run made: raw output before parsing, parsed labels, and whether it matched this study's own hand-authored expectation (`—` for real History rows, which aren't scored). Read this to judge reasoning style, not just the pass/fail counts above.\n\n"
    for result in modelResults {
        out += "### \(result.displayName)\n\n"
        if let loadError = result.loadError {
            out += "Load error: \(loadError)\n\n"
            continue
        }
        for run in result.runs {
            let status: String
            if run.error != nil {
                status = "ERROR"
            } else if let correct = run.correctSignalDecision {
                status = correct ? "✓" : "✗"
            } else {
                status = "—"
            }
            let expectedLabel = run.item.expectedSignal.map { $0 ? "task" : "NONE" } ?? "unscored"
            out += "**[\(run.item.id)]** (\(run.item.category), expected \(expectedLabel)) \(status) — \(seconds(run.latencySeconds))"
            if !run.formatViolations.isEmpty {
                out += " ⚠️ \(reportableViolations(run.formatViolations, isRealData: run.item.isRealData).joined(separator: "; "))"
            }
            if run.possibleHallucination {
                out += " ⚠️ possible hallucination"
            }
            out += "\n\n"
            out += evaluationTranscriptBody(
                input: run.item.text, rawOutput: run.error == nil ? run.rawOutput : nil, isRealData: run.item.isRealData
            )
            if let error = run.error {
                out += "Error: \(error)\n\n"
            }
        }
    }

    let outputPath = FileManager.default.currentDirectoryPath + "/model_evaluation_report.md"
    try? out.write(toFile: outputPath, atomically: true, encoding: .utf8)
}
