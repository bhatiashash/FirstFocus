import FirstFocusCore

func registerSignalPresentationTests(_ runner: TestRunner) {
    runner.suite("firstName(from:): sender display (window-chrome-and-inbox-legibility ticket 02)") { r in
        r.run("a plain first/last name is split on the first space") {
            try expect(firstName(from: "Jane Doe") == "Jane")
        }

        r.run("a raw address with no space is shown whole") {
            try expect(firstName(from: "+15551234567") == "+15551234567")
        }

        r.run("a trailing routing-tag suffix is stripped from a raw short code") {
            try expect(firstName(from: "41064(smsft)") == "41064")
        }

        r.run("a different routing-tag suffix is stripped the same way") {
            try expect(firstName(from: "41064(smsfp)") == "41064")
        }

        r.run("a routing-tag suffix preceded by a space is still stripped, with the space trimmed") {
            try expect(firstName(from: "41064 (smsft)") == "41064")
        }

        r.run("a resolved name is never mistaken for carrying a routing tag") {
            try expect(firstName(from: "Jane Doe") == "Jane")
        }
    }

    runner.suite("shorteningURLs(in:): caption legibility (window-chrome-and-inbox-legibility ticket 03)") { r in
        r.run("text with no URL is returned unchanged") {
            try expect(shorteningURLs(in: "Your reservation has been set for Saab Sis Thai") == "Your reservation has been set for Saab Sis Thai")
        }

        r.run("a URL with a path collapses to host plus a trailing ellipsis") {
            let input = "For more info, visit the Reserve with Google Help Center: https://support.google.com/reserve/"
            try expect(shorteningURLs(in: input) == "For more info, visit the Reserve with Google Help Center: support.google.com/…")
        }

        r.run("a bare URL with no path beyond the host loses only the protocol") {
            try expect(shorteningURLs(in: "See https://support.google.com for details") == "See support.google.com for details")
        }

        r.run("http (not just https) is stripped the same way") {
            try expect(shorteningURLs(in: "http://example.com/a/b/c") == "example.com/…")
        }

        r.run("multiple URLs in the same caption are each shortened") {
            let input = "https://a.com/x and https://b.com/y"
            try expect(shorteningURLs(in: input) == "a.com/… and b.com/…")
        }
    }

    runner.suite("sourceIconSymbolName(for:) / sourceHelpText(for:sender:): SourceIcon's rules") { r in
        r.run("Reminders gets the list-bullet symbol and label") {
            try expect(sourceIconSymbolName(for: .reminders) == "list.bullet")
            try expect(sourceHelpText(for: .reminders, sender: nil) == "Reminders")
        }

        r.run("Messages gets the bubble symbol") {
            try expect(sourceIconSymbolName(for: .messages) == "bubble.left")
        }

        r.run("a Messages Signal with a resolved Sender shows the Sender, not \"Messages\"") {
            try expect(sourceHelpText(for: .messages, sender: "Jane Doe") == "Jane Doe")
        }

        r.run("a Messages Signal with no Sender (self-thread) falls back to \"Messages\"") {
            try expect(sourceHelpText(for: .messages, sender: nil) == "Messages")
        }

        r.run("Reminders' help text ignores sender even if one is somehow passed") {
            try expect(sourceHelpText(for: .reminders, sender: "Jane Doe") == "Reminders")
        }
    }
}
