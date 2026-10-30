import FirstFocusApp
import FirstFocusCore
import Foundation

/// Morning Brief ticket 04: Open at login, through a fake login item.
final class FakeLoginItem: LoginItem, @unchecked Sendable {
    var isEnabled = false
    var failure: Error?
    private(set) var setCalls: [Bool] = []

    func setEnabled(_ enabled: Bool) throws {
        setCalls.append(enabled)
        if let failure { throw failure }
        isEnabled = enabled
    }
}

private struct RegistrationFailed: Error {}

@MainActor
private func makeViewModel(suite: String, item: FakeLoginItem) -> OpenAtLoginViewModel {
    OpenAtLoginViewModel(loginItem: item, defaults: UserDefaults(suiteName: "firstfocus-tests-login-\(suite)")!)
}

func registerOpenAtLoginTests(_ runner: TestRunner) {
    runner.suite("Open at login") { r in
        r.run("is turned on the first time, and only the first time") {
            let suite = UUID().uuidString
            let item = FakeLoginItem()
            try await MainActor.run {
                let first = makeViewModel(suite: suite, item: item)
                try expect(first.isEnabled)
                try expect(item.isEnabled)
                first.setEnabled(false)
                _ = makeViewModel(suite: suite, item: item)
                try expect(!item.isEnabled, "a later launch keeps your choice")
                try expect(item.setCalls == [true, false], "got \(item.setCalls)")
            }
        }

        r.run("reflects a change made in System Settings") {
            let item = FakeLoginItem()
            try await MainActor.run {
                let viewModel = makeViewModel(suite: UUID().uuidString, item: item)
                item.isEnabled = false
                viewModel.refresh()
                try expect(!viewModel.isEnabled)
            }
        }

        r.run("a failure leaves the toggle showing the real state, with a message") {
            let item = FakeLoginItem()
            item.failure = RegistrationFailed()
            try await MainActor.run {
                let viewModel = makeViewModel(suite: UUID().uuidString, item: item)
                try expect(!viewModel.isEnabled)
                try expect(viewModel.errorText != nil)
            }
        }
    }
}
