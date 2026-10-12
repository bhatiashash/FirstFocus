import DailyOSCore
import Foundation

private func reminder(title: String = "Send the deck", notes: String? = nil, url: URL? = nil) -> Signal {
    Signal(
        id: "r1", source: .reminders, sourceRef: "r1", label: title, originalText: title, createdAt: Date(),
        provenance: .stated, notes: notes, url: url
    )
}

private func messagesSignal(label: String, originalText: String, chatIdentifier: String?) -> Signal {
    Signal(
        id: "s1", source: .messages, sourceRef: "m1", label: label, originalText: originalText, createdAt: Date(),
        provenance: .inferred, chatIdentifier: chatIdentifier
    )
}

/// What clicking a Focus or Later row opens (ADR 0041; CONTEXT.md: Notes).
func registerRowDrawerTests(_ runner: TestRunner) {
    runner.suite("rowDrawer(for:)") { r in
        r.run("a reminder with Notes shows them") {
            let drawer = rowDrawer(for: reminder(notes: "Priya: can you send the deck\nYou: sure"))
            try expect(drawer.body == "Priya: can you send the deck\nYou: sure")
            try expect(drawer.hasContent)
            try expect(drawer.messagesURL == nil)
        }

        r.run("a reminder whose URL opens a Chat offers Open in Messages, not a link") {
            let drawer = rowDrawer(for: reminder(url: URL(string: "sms:+15551234567")))
            try expect(drawer.messagesURL == URL(string: "sms:+15551234567"))
            try expect(drawer.links.isEmpty)
            try expect(drawer.body == nil)
            try expect(drawer.hasContent)
        }

        r.run("a reminder with a web URL lists it as a link") {
            let drawer = rowDrawer(for: reminder(url: URL(string: "https://example.com/tickets")))
            try expect(drawer.links == [URL(string: "https://example.com/tickets")!])
            try expect(drawer.messagesURL == nil)
            try expect(drawer.hasContent)
        }

        r.run("a reminder with nothing besides its title has nothing to show") {
            let drawer = rowDrawer(for: reminder())
            try expect(!drawer.hasContent)
            try expect(drawer.body == nil)
        }

        r.run("blank Notes count as none") {
            try expect(!rowDrawer(for: reminder(notes: "  \n")).hasContent)
        }

        r.run("links are found in the Notes and in the title, each once") {
            let drawer = rowDrawer(for: reminder(
                title: "Book tickets https://example.com/tickets",
                notes: "Priya: here https://example.com/tickets and https://maps.apple.com/?q=venue"
            ))
            try expect(drawer.links == [URL(string: "https://example.com/tickets")!, URL(string: "https://maps.apple.com/?q=venue")!])
        }

        r.run("a Messages Signal shows its original wording and opens its one-to-one Chat") {
            let drawer = rowDrawer(for: messagesSignal(
                label: "Send Priya the deck", originalText: "Priya: can you send the deck", chatIdentifier: "+15551234567"
            ))
            try expect(drawer.body == "Priya: can you send the deck")
            try expect(drawer.messagesURL == URL(string: "sms:+15551234567"))
        }

        r.run("a Messages Signal from a group Chat has no Open in Messages") {
            let drawer = rowDrawer(for: messagesSignal(label: "Bring ice", originalText: "Participant A: who's bringing ice", chatIdentifier: nil))
            try expect(drawer.messagesURL == nil)
            try expect(drawer.body == "Participant A: who's bringing ice")
        }

        r.run("the displayed Label has its URLs removed") {
            try expect(rowDrawer(for: reminder(title: "Book tickets https://example.com/tickets?id=4")).displayLabel == "Book tickets")
            try expect(rowDrawer(for: reminder(title: "Read https://example.com/a then reply")).displayLabel == "Read then reply")
        }

        r.run("a Label with no URL is shown unchanged") {
            try expect(rowDrawer(for: reminder(title: "Send the deck (from Priya)")).displayLabel == "Send the deck (from Priya)")
        }

        r.run("a Label that is only a URL shows its site rather than nothing") {
            try expect(rowDrawer(for: reminder(title: "https://example.com/tickets")).displayLabel == "example.com/…")
        }
    }
}
