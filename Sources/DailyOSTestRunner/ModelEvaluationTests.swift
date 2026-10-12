import DailyOSCore
import Foundation

/// extraction-accuracy-baseline tickets 01 and 03: what ModelEvaluator's
/// committed report may quote, and how a stored Correction becomes a
/// scored case.
func registerModelEvaluationTests(_ runner: TestRunner) {
    runner.suite("evaluationTranscriptBody: real message text stays out of the report") { r in
        r.run("a synthetic case quotes its input and its raw output") {
            let body = evaluationTranscriptBody(input: "can you grab milk\nthanks", rawOutput: "Grab milk", isRealData: false)
            try expect(body == "> can you grab milk\n> thanks\n\n```\nGrab milk\n```\n\n")
        }
        r.run("a real case quotes neither its input nor its raw output") {
            let body = evaluationTranscriptBody(
                input: "[latest messages]\nThem: pick up Priya at 6", rawOutput: "Pick up Priya", isRealData: true
            )
            try expect(!body.contains("Priya"), "real message text, and output that can copy it, must not reach the committed report")
            try expect(body.contains("CSV"), "the reader should be told where the text went")
        }
        r.run("a real case's format violations keep their kind but drop the output they quote") {
            let violations = ["unresolvable DUE_TEXT line (\"DUE_TEXT: before Priya's party\")", "leaked token Output:"]
            let reported = reportableViolations(violations, isRealData: true)
            try expect(reported == ["unresolvable DUE_TEXT line", "leaked token Output:"])
            try expect(reportableViolations(violations, isRealData: false) == violations, "a synthetic case keeps the detail")
        }
    }

    runner.suite("correctionCase: a stored Correction as a scored ModelEvaluator case") { r in
        r.run("a \"Not for me\" Correction expects NONE") {
            let correction = Correction(
                chatId: 3, inputText: "[latest messages]\nThem: lol", correctedOutput: "NONE", correctionType: .falsePositive
            )
            let scored = try require(correctionCase(from: correction))
            try expect(scored.expectsTask == false)
            try expect(scored.input == "[latest messages]\nThem: lol", "the input is replayed as the model saw it")
        }
        r.run("an \"Add task\" Correction expects a task and keeps the Label you typed for comparison") {
            let correction = Correction(
                chatId: 3, inputText: "[latest messages]\nThem: can you book the court", correctedOutput: "Book the court",
                correctionType: .missedTask
            )
            let scored = try require(correctionCase(from: correction))
            try expect(scored.expectsTask == true)
            try expect(scored.typedLabel == "Book the court")
        }
        r.run("\"This was work\" and field corrections are not scored") {
            for type in [CorrectionType.falseNegative, .fieldCorrection] {
                let correction = Correction(chatId: 3, inputText: "[latest messages]\nThem: hi", correctedOutput: "", correctionType: type)
                try expect(correctionCase(from: correction) == nil, "\(type) carries no answer the model should give")
            }
        }
        r.run("a Correction recorded in the one-message format is replayed in the Batch format") {
            let correction = Correction(
                chatId: 3, inputText: "[context]\nThem: hey\n\n[message to judge]\nThem: lol", correctedOutput: "NONE",
                correctionType: .falsePositive
            )
            let scored = try require(correctionCase(from: correction))
            try expect(scored.input == "[context]\nThem: hey\n\n[latest messages]\nThem: lol")
        }
    }
}
