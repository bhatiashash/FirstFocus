/// Records `runBackfill`'s progress callbacks. A class, not a local `var`,
/// since the callback is `@Sendable` and the compiler can't otherwise prove
/// a captured local won't be mutated concurrently — `runBackfill` in fact
/// calls it strictly in sequence, but that isn't visible from its type.
final class ProgressRecorder: @unchecked Sendable {
    private(set) var reported: [(completed: Int, total: Int)] = []

    func record(_ completed: Int, _ total: Int) {
        reported.append((completed, total))
    }
}
