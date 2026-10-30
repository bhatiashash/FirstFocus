import Foundation

private func csvField(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") || value.contains("\n") {
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return value
}

/// Wide-format CSV, one row per corpus item with all three models' output
/// side by side — easier to scan for cross-model discrepancies at a glance
/// than the long-format transcript in model_evaluation_report.md, which
/// this deliberately doesn't replace (kept both since they answer
/// different questions: the CSV for "where do the three disagree," the
/// report for "why").
func writeCSV(modelResults: [ModelResult], allItems: [CorpusItem]) {
    // Model order fixed by ModelCatalog.entries — matches the Qwen2.5 /
    // Llama3.2 / Qwen3 columns the spec asks for by name, since that's
    // the same order every model's `runs` array was built in.
    guard modelResults.count == 3 else { return }
    let (qwen25, llama32, qwen3) = (modelResults[0], modelResults[1], modelResults[2])

    var rows: [[String]] = [[
        "Message_ID", "Category", "Source_Text",
        "Qwen2.5_Output", "Llama3.2_Output", "Qwen3_Output",
        "Format_Errors", "Signal_Discrepancy", "Possible_Hallucination",
        "Inference_Time_Diff_ms", "Typed_Label",
    ]]

    for (index, item) in allItems.enumerated() {
        guard index < qwen25.runs.count, index < llama32.runs.count, index < qwen3.runs.count else { continue }
        let runs = [qwen25.runs[index], llama32.runs[index], qwen3.runs[index]]

        let outputs = runs.map { run -> String in
            run.error != nil ? "ERROR: \(run.error!)" : (run.parsedLabels.isEmpty ? "NONE" : run.parsedLabels.joined(separator: " | "))
        }

        let formatErrors = zip(["Qwen2.5", "Llama3.2", "Qwen3"], runs)
            .compactMap { name, run -> String? in
                run.formatViolations.isEmpty ? nil : "\(name): \(run.formatViolations.joined(separator: "; "))"
            }
            .joined(separator: " | ")

        let signalDiscrepancy = Set(runs.map(\.producedSignal)).count > 1 ? "yes" : "no"

        let hallucinationFlags = zip(["Qwen2.5", "Llama3.2", "Qwen3"], runs)
            .compactMap { name, run -> String? in run.possibleHallucination ? name : nil }
            .joined(separator: ", ")

        let latencies = runs.map { $0.latencySeconds * 1000 }
        let timeDiffMs = (latencies.max() ?? 0) - (latencies.min() ?? 0)

        rows.append([
            item.id, item.category, item.text,
            outputs[0], outputs[1], outputs[2],
            formatErrors, signalDiscrepancy, hallucinationFlags,
            String(format: "%.0f", timeDiffMs), item.typedLabel ?? "",
        ])
    }

    let csv = rows.map { row in row.map(csvField).joined(separator: ",") }.joined(separator: "\n")
    let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    let outputPath = (desktopURL?.path ?? FileManager.default.currentDirectoryPath) + "/FirstFocus_Model_Evaluation.csv"
    try? csv.write(toFile: outputPath, atomically: true, encoding: .utf8)
}
