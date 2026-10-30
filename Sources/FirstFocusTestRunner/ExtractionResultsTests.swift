import FirstFocusCore
import Foundation

/// Ticket 02 (batched-extraction): output parses into new, update and
/// cancel results, and a `DUE_TEXT` line belongs to the result above it.
func registerExtractionResultsTests(_ runner: TestRunner) {
    runner.suite("parseExtractionResults") { r in
        r.run("NONE alone gives no results") {
            try expect(parseExtractionResults("NONE") == [])
        }
        r.run("mixed new, update and cancel lines parse in order") {
            let results = parseExtractionResults("Grab milk\nUPDATE 1: Prep Nutty Pudding\nCANCEL 2")
            try expect(results == [
                .new(label: "Grab milk", dueText: nil),
                .update(suggestion: 1, label: "Prep Nutty Pudding", dueText: nil),
                .cancel(suggestion: 2),
            ])
        }
        r.run("a DUE_TEXT line attaches to the result above it") {
            let results = parseExtractionResults("Grab milk\nDUE_TEXT: \"tomorrow\"\nCall the landlord\nDUE_TEXT: \"Friday\"")
            try expect(results == [
                .new(label: "Grab milk", dueText: "\"tomorrow\""),
                .new(label: "Call the landlord", dueText: "\"Friday\""),
            ])
        }
        r.run("a DUE_TEXT line attaches to an update") {
            try expect(parseExtractionResults("UPDATE 1: Prep Nutty Pudding\nDUE_TEXT: \"today\"")
                == [.update(suggestion: 1, label: "Prep Nutty Pudding", dueText: "\"today\"")])
        }
        r.run("a DUE_TEXT line after a cancel is ignored") {
            try expect(parseExtractionResults("CANCEL 1\nDUE_TEXT: \"today\"") == [.cancel(suggestion: 1)])
        }
        r.run("a DUE_TEXT line with nothing above it is ignored") {
            try expect(parseExtractionResults("DUE_TEXT: \"tomorrow\"\nCall the dentist") == [.new(label: "Call the dentist", dueText: nil)])
        }
        r.run("two DUE_TEXT lines under one result are inconsistent, so that result gets no due text") {
            try expect(parseExtractionResults("Call the dentist\nDUE_TEXT: \"tomorrow\"\nDUE_TEXT: \"next week\"")
                == [.new(label: "Call the dentist", dueText: nil)])
        }
        r.run("NONE in any case gives no results, never a Suggestion titled None") {
            try expect(parseExtractionResults("None") == [])
            try expect(parseExtractionResults("none") == [])
            try expect(parseExtractionResults("None.") == [], "a trailing full stop is still NONE")
        }
        r.run("NONE next to other lines fails closed to no results") {
            try expect(parseExtractionResults("Call the dentist\nNONE") == [])
        }
        r.run("NONE with a DUE_TEXT line still gives no results") {
            try expect(parseExtractionResults("NONE\nDUE_TEXT: \"tomorrow\"") == [])
        }
        r.run("malformed UPDATE and CANCEL lines are dropped") {
            let results = parseExtractionResults("UPDATE: Prep meals\nUPDATE x: Prep meals\nUPDATE 1:\nCANCEL\nCANCEL two\nCANCEL 0\nBuy milk")
            try expect(results == [.new(label: "Buy milk", dueText: nil)])
        }
        r.run("a DUE_TEXT line under a dropped malformed line is dropped with it") {
            try expect(parseExtractionResults("UPDATE x: Prep meals\nDUE_TEXT: \"today\"") == [])
        }
        r.run("a Label that merely starts with the word Update or Cancel is a new Label") {
            let results = parseExtractionResults("Update Streamlit dashboard\nCancel gym membership")
            try expect(results == [
                .new(label: "Update Streamlit dashboard", dueText: nil),
                .new(label: "Cancel gym membership", dueText: nil),
            ])
        }
        r.run("a leaked Output: prefix is dropped on every kind of line") {
            let results = parseExtractionResults("Output: Grab milk\nOutput: UPDATE 1: Prep Nutty Pudding\nOutput: CANCEL 2")
            try expect(results == [
                .new(label: "Grab milk", dueText: nil),
                .update(suggestion: 1, label: "Prep Nutty Pudding", dueText: nil),
                .cancel(suggestion: 2),
            ])
            try expect(parseExtractionResults("Output: NONE") == [])
        }
    }

    runner.suite("droppingUnknownSuggestions") { r in
        r.run("an UPDATE or CANCEL naming a suggestion that wasn't listed is dropped; new Labels stay") {
            let results = parseExtractionResults("UPDATE 2: Book Saturday\nCANCEL 1\nCANCEL 3\nBuy milk")
            try expect(droppingUnknownSuggestions(results, openSuggestionCount: 1) == [.cancel(suggestion: 1), .new(label: "Buy milk", dueText: nil)])
            try expect(droppingUnknownSuggestions(results, openSuggestionCount: 0) == [.new(label: "Buy milk", dueText: nil)])
        }
    }

    runner.suite("droppingRepeatedSuggestions") { r in
        r.run("a new Label matching an open Suggestion is dropped, ignoring case and outer spaces; UPDATE and CANCEL stay") {
            let results = parseExtractionResults("lets work \nUPDATE 1: Lets work\nCANCEL 1\nBuy milk")
            try expect(droppingRepeatedSuggestions(results, openLabels: ["Lets work"]) == [
                .update(suggestion: 1, label: "Lets work", dueText: nil), .cancel(suggestion: 1), .new(label: "Buy milk", dueText: nil),
            ])
            try expect(droppingRepeatedSuggestions(results, openLabels: []) == results)
        }
    }

    runner.suite("Messages Intake refresh: each Label gets its own due date") { r in
        r.run("two Labels with their own DUE_TEXT lines produce Signals with different due dates") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: [
                "grab milk tomorrow and call the landlord in two days":
                    "Grab milk\nDUE_TEXT: \"tomorrow\"\nCall the landlord\nDUE_TEXT: \"in 2 days\"",
            ])
            let message = ChatMessage(
                id: "m1", chatId: 1, isFromMe: true, text: "grab milk tomorrow and call the landlord in two days", createdAt: Date()
            )
            let signals = await refreshThroughIntake(from: [message], store: store, extractor: extractor)
            let calendar = Calendar(identifier: .gregorian)
            let milk = try require(signals.first { $0.label == "Grab milk" })
            let landlord = try require(signals.first { $0.label == "Call the landlord" })
            let milkDue = try require(milk.dueAt)
            let landlordDue = try require(landlord.dueAt)
            try expect(calendar.isDate(milkDue, inSameDayAs: expectedDate(daysFromToday: 1)))
            try expect(calendar.isDate(landlordDue, inSameDayAs: expectedDate(daysFromToday: 2)))
        }
        r.run("a Label with no DUE_TEXT line of its own gets no due date") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["buy milk, call the dentist tomorrow": "Buy milk\nCall the dentist\nDUE_TEXT: \"tomorrow\""])
            let message = ChatMessage(id: "m1", chatId: 1, isFromMe: true, text: "buy milk, call the dentist tomorrow", createdAt: Date())
            let signals = await refreshThroughIntake(from: [message], store: store, extractor: extractor)
            let milk = try require(signals.first { $0.label == "Buy milk" })
            let dentist = try require(signals.first { $0.label == "Call the dentist" })
            try expect(milk.dueAt == nil)
            try expect(dentist.dueAt != nil)
        }
        r.run("updates and cancels produce no Signals yet") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["nvm": "UPDATE 1: Prep Nutty Pudding\nCANCEL 2\nBuy milk"])
            let message = ChatMessage(id: "m1", chatId: 1, isFromMe: true, text: "nvm", createdAt: Date())
            let signals = await refreshThroughIntake(from: [message], store: store, extractor: extractor)
            try expect(signals.map(\.label) == ["Buy milk"])
        }
    }
}
