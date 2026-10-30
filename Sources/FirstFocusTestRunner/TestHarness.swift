import Foundation

// Swift Testing's SwiftPM runtime (`swiftpm-testing-helper`) cannot load its
// own test bundle on this machine: `_Testing_Foundation.framework` ships
// with no Modules directory at all, not merely stale, so there's no working
// version to fall back to the way tickets 01 and 14's toolchain fixes did.
// XCTest needs Xcode.app, which isn't installed either. This is a plain
// assertion runner instead: no framework dependency, run with `swift run
// FirstFocusTestRunner`, exits non-zero on any failure.

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String = "",
    file: String = #fileID,
    line: Int = #line
) throws {
    guard condition() else {
        let detail = message()
        let suffix = detail.isEmpty ? "" : "\(detail) "
        throw TestFailure(message: "\(suffix)(\(file):\(line))")
    }
}

func require<T>(
    _ value: T?,
    _ message: @autoclosure () -> String = "expected a non-nil value",
    file: String = #fileID,
    line: Int = #line
) throws -> T {
    guard let value else {
        throw TestFailure(message: "\(message()) (\(file):\(line))")
    }
    return value
}

/// A day offset from the moment the test runs, at day granularity (no
/// time-of-day component compared). Exists because `resolveDueDate`
/// resolves relative phrases ("tomorrow") against the live wall clock —
/// `NSDataDetector` has no reference-date override — so its tests can't
/// assert a single pinned `Date` and instead compare against this same
/// live-clock computation.
func expectedDate(daysFromToday days: Int, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
    calendar.date(byAdding: .day, value: days, to: Date())!
}

final class TestRunner {
    private(set) var passed = 0
    private(set) var failed = 0

    func run(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            print("  \u{2713} \(name)")
        } catch {
            failed += 1
            print("  \u{2717} \(name): \(error)")
        }
    }

    /// Async overload: blocks the calling thread until `body` completes, so
    /// suites can stay plain synchronous functions while individual tests
    /// exercise `async` code (extraction, which calls out to a model).
    func run(_ name: String, _ body: @escaping @Sendable () async throws -> Void) {
        do {
            try awaitSync(body)
            passed += 1
            print("  \u{2713} \(name)")
        } catch {
            failed += 1
            print("  \u{2717} \(name): \(error)")
        }
    }

    func suite(_ name: String, _ body: (TestRunner) -> Void) {
        print(name)
        body(self)
    }

    func summarize() -> Int32 {
        print("")
        print("\(passed) passed, \(failed) failed")
        return failed > 0 ? 1 : 0
    }
}

private final class ThrownErrorBox: @unchecked Sendable {
    var error: Error?
    var finished = false
}

/// Pumps the main run loop while waiting, rather than blocking it on a
/// semaphore. The semaphore version deadlocked the moment a test body
/// hopped to the main actor: `run` is called from the main thread, so
/// `semaphore.wait()` parked the very thread the hop needed, and nothing
/// could ever signal it. Every `AppModel` test does that hop, since the
/// model is `@MainActor`.
///
/// `run(mode:before:)` returns immediately when no input source is
/// attached, so the short sleep is what keeps this from spinning a core
/// flat while it waits.
private func awaitSync(_ body: @escaping @Sendable () async throws -> Void) throws {
    let box = ThrownErrorBox()
    Task {
        do {
            try await body()
        } catch {
            box.error = error
        }
        box.finished = true
    }
    while !box.finished {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        usleep(500)
    }
    if let error = box.error { throw error }
}
