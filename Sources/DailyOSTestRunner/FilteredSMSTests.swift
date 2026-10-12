import DailyOSCore
import Foundation

func registerFilteredSMSTests(_ runner: TestRunner) {
    runner.suite("Filtered SMS addresses") { r in
        r.run("a Transactions or Promotions suffix marks the address, in any case") {
            try expect(isFilteredSMSAddress("23045(smsfp)"))
            try expect(isFilteredSMSAddress("+15551234567(smsft)"))
            try expect(isFilteredSMSAddress("23045(SMSFP)"))
        }
        r.run("an ordinary address or email is not Filtered SMS") {
            try expect(!isFilteredSMSAddress("+15551234567"))
            try expect(!isFilteredSMSAddress("23045"))
            try expect(!isFilteredSMSAddress("smsfp@example.com"))
        }
    }

    runner.suite("Filtered SMS settings") { r in
        r.run("ignoring is on until turned off, and the choice is kept") {
            let defaults = UserDefaults(suiteName: "FilteredSMSTests-\(UUID().uuidString)")!
            let settings = FilteredSMSSettings(defaults: defaults)
            try expect(settings.ignoresFilteredSMS)
            settings.ignoresFilteredSMS = false
            try expect(!FilteredSMSSettings(defaults: defaults).ignoresFilteredSMS)
        }
    }

    runner.suite("Intake and Filtered SMS") { r in
        let start = Date().addingTimeInterval(-3600)
        let promotion = ChatMessage(
            id: "m1", chatId: 7, isFromMe: false, text: "call us today to book your free upgrade", createdAt: start,
            senderAddress: "23045(smsfp)", chatIdentifier: "23045(smsfp)"
        )

        r.run("while ignored, a Filtered SMS Batch never reaches the model") {
            let extractor = FakeIntentExtractor(defaultResponse: "Book the upgrade")
            let deps = ExtractionDependencies(store: makeTestSignalStore(), extractor: extractor, ignoresFilteredSMS: { true })
            let signals = await refreshThroughIntake(from: [promotion], deps: deps)
            try expect(extractor.calls.isEmpty, "the model was asked: \(extractor.calls)")
            try expect(signals.isEmpty)
        }

        r.run("when not ignored, it is extracted like any other Batch") {
            let extractor = FakeIntentExtractor(defaultResponse: "Book the upgrade")
            let deps = ExtractionDependencies(store: makeTestSignalStore(), extractor: extractor, ignoresFilteredSMS: { false })
            let signals = await refreshThroughIntake(from: [promotion], deps: deps)
            try expect(extractor.calls.count == 1)
            try expect(signals.map(\.label) == ["Book the upgrade"])
        }
    }
}
