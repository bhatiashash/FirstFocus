import FirstFocusCore
import Foundation

/// Every row as CSV, one line each in the order given (ADR 0029).
package func historyCSV(rows: [HistoryEntry]) -> String {
    func field(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    var csv = "timestamp,kind,message id,model used,source text,raw output,signal count,starred\n"
    let formatter = ISO8601DateFormatter()
    for entry in rows {
        csv += [
            formatter.string(from: entry.timestamp), entry.kind.storageName, entry.sourceRef ?? "",
            entry.modelUsed, entry.sourceRawText, entry.rawOutput,
            String(entry.signalCount), String(entry.isStarred),
        ].map(field).joined(separator: ",") + "\n"
    }
    return csv
}

/// `batches` as Markdown, in the order given. Uses what the model and
/// Screening saw, under Participant Labels, and never a Sender or
/// transcript, so no Contacts name leaves the app this way.
package func historyMarkdown(batches: [HistoryBatch], view: String, cutoff: Double, exportedAt: Date) -> String {
    let formatter = ISO8601DateFormatter()
    var lines = [
        "# FirstFocus History export",
        "",
        "Exported: \(formatter.string(from: exportedAt))",
        "View: \(view)",
        "Cutoff: \(formatScore(cutoff))",
    ]
    for batch in batches {
        lines += ["", "## \(formatter.string(from: batch.timestamp))", ""]
        lines.append(batch.chatId.map { "Chat \($0)" } ?? chatNotRecordedTitle)
        if let sourceRef = batch.sourceRef { lines.append("Message id: \(sourceRef)") }
        let inspection = HistoryInspection(batch)
        if let prompt = inspection.prompt {
            lines += ["", "Prompt:", "", fenced(prompt)]
        }
        lines.append("")
        switch batch.result {
        case .tasks(let labels): lines.append("Tasks: " + labels.joined(separator: "; "))
        default: lines.append("Result: " + batch.resultSummary)
        }
        if let screening = inspection.screening {
            let decision = screening.wasScreened ? "screened" : "let through"
            let cutoff = screening.cutoff.map { ", cutoff \(formatScore($0))" } ?? ", shadow mode"
            lines.append("Screening: \(formatScore(screening.probability)) (\(decision)\(cutoff))")
        }
        if let failure = inspection.screeningFailure {
            lines.append("Screening failed: \(failure.reason)")
        }
        if inspection.screeningUnavailable {
            lines.append("Screening unavailable: sent straight to the model")
        }
        let outputs = [inspection.modelCall].compactMap { $0 } + inspection.reruns + [inspection.audit].compactMap { $0 }
        for output in outputs {
            let heading = switch output.kind {
            case .audit: "Audit Sample"
            case .rerun: "Re-run"
            default: "Model output"
            }
            lines += ["", "\(heading) (\(output.modelUsed)):", "", fenced(output.rawOutput)]
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

/// A fenced block whose fence is longer than any backtick run inside.
private func fenced(_ text: String) -> String {
    var longest = 0
    var run = 0
    for character in text {
        run = character == "`" ? run + 1 : 0
        longest = max(longest, run)
    }
    let fence = String(repeating: "`", count: max(3, longest + 1))
    return "\(fence)\n\(text)\n\(fence)"
}

/// `contents` in a new temp file, for the caller to offer through a Save
/// panel. Nil when the file can't be written.
func writeHistoryExport(_ contents: String, extension ext: String) -> URL? {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("FirstFocus-History-\(UUID().uuidString).\(ext)")
    do {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    } catch {
        return nil
    }
}
