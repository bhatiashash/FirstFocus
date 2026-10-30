import FirstFocusCore
import Foundation

func registerProcessedAmongTests(_ runner: TestRunner) {
    runner.suite("Signal store: which source references are Processed, in one read") { r in
        r.run("answers for many references at once, leaving out the unprocessed and unknown ones") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [])
            try store.recordOneMessageBatch("m2", signals: [])
            let processed = store.processedSourceRefs(among: ["m1", "m2", "m3", "never-seen"])
            try expect(processed == ["m1", "m2"], "got \(processed)")
        }

        r.run("an empty question has an empty answer") {
            let store = makeTestSignalStore()
            try expect(store.processedSourceRefs(among: []).isEmpty)
        }

        r.run("a question larger than SQLite's variable limit is still answered") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m5", signals: [])
            try store.recordOneMessageBatch("m1100", signals: [])
            let refs = (0..<1200).map { "m\($0)" }
            let processed = store.processedSourceRefs(among: refs)
            try expect(processed == ["m5", "m1100"], "got \(processed)")
        }

        r.run("agrees with asking about each reference alone") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("a", signals: [])
            let refs = ["a", "b"]
            try expect(store.processedSourceRefs(among: refs) == Set(refs.filter { store.isProcessed(sourceRef: $0) }))
        }
    }
}
