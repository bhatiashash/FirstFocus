import DailyOSCore
import Foundation

private func lowConfidenceSignal(id: String, sourceRef: String, createdAt: Date = Date()) -> Signal {
    Signal(
        id: id, source: .messages, sourceRef: sourceRef, label: id, originalText: id, createdAt: createdAt,
        provenance: .inferred, lowConfidence: true
    )
}

private func ordinarySignal(id: String, sourceRef: String? = nil, createdAt: Date = Date()) -> Signal {
    Signal(
        id: id, source: .messages, sourceRef: sourceRef ?? id, label: id, originalText: id, createdAt: createdAt,
        provenance: .inferred, lowConfidence: false
    )
}

func registerSubtaskGroupingTests(_ runner: TestRunner) {
    runner.suite("groupForRendering (ticket 04)") { r in
        r.run("two Signals from the same message render grouped") {
            let a = lowConfidenceSignal(id: "a", sourceRef: "m1")
            let b = lowConfidenceSignal(id: "b", sourceRef: "m1")
            let groups = groupForRendering([a, b])
            try expect(groups.count == 1)
            guard case .group(let members) = try require(groups.first) else {
                throw TestFailure(message: "expected a single .group")
            }
            try expect(members.map(\.id) == ["a", "b"])
        }

        r.run("Signals from different messages never group even if adjacent in rank") {
            let a = lowConfidenceSignal(id: "a", sourceRef: "m1")
            let b = lowConfidenceSignal(id: "b", sourceRef: "m2")
            let groups = groupForRendering([a, b])
            try expect(groups == [.single(a), .single(b)])
        }

        r.run("a lone lowConfidence Signal whose batch-mates are already resolved renders alone, with no group chrome") {
            // The other member of this batch has already been checked off,
            // dismissed, or approved, so it no longer appears in the array
            // `groupForRendering` is handed at all.
            let a = lowConfidenceSignal(id: "a", sourceRef: "m1")
            try expect(groupForRendering([a]) == [.single(a)])
        }

        r.run("a group's rendering correctly shrinks as members are individually resolved") {
            let a = lowConfidenceSignal(id: "a", sourceRef: "m1")
            let b = lowConfidenceSignal(id: "b", sourceRef: "m1")
            try expect(groupForRendering([a, b]).count == 1, "starts grouped")
            // b resolved (checked off/dismissed/approved) and so removed
            // from what's passed in on the next render.
            try expect(groupForRendering([a]) == [.single(a)], "shrinks to a lone single once only one member remains")
        }

        r.run("ordinary (non-lowConfidence) Signals never group, even sharing a sourceRef") {
            let a = ordinarySignal(id: "a", sourceRef: "m1")
            let b = ordinarySignal(id: "b", sourceRef: "m1")
            try expect(groupForRendering([a, b]) == [.single(a), .single(b)])
        }

        r.run("a mixed sequence keeps singles and a group each in their original position") {
            let before = ordinarySignal(id: "before")
            let a = lowConfidenceSignal(id: "a", sourceRef: "m1")
            let b = lowConfidenceSignal(id: "b", sourceRef: "m1")
            let after = ordinarySignal(id: "after")
            let groups = groupForRendering([before, a, b, after])
            try expect(groups.count == 3)
            try expect(groups[0] == .single(before))
            try expect(groups[2] == .single(after))
            guard case .group(let members) = groups[1] else {
                throw TestFailure(message: "expected the middle element to be a .group")
            }
            try expect(members.map(\.id) == ["a", "b"])
        }

        r.run("grouping never changes rank order — no reordering, only clustering") {
            let a = lowConfidenceSignal(id: "a", sourceRef: "m1")
            let b = lowConfidenceSignal(id: "b", sourceRef: "m1")
            let c = ordinarySignal(id: "c")
            let groups = groupForRendering([c, a, b])
            try expect(groups.map(\.id) == [c.id, "a+b"])
        }

        r.run("a three-member batch groups together, not split into a pair and a single") {
            let a = lowConfidenceSignal(id: "a", sourceRef: "m1")
            let b = lowConfidenceSignal(id: "b", sourceRef: "m1")
            let c = lowConfidenceSignal(id: "c", sourceRef: "m1")
            let groups = groupForRendering([a, b, c])
            try expect(groups.count == 1)
            guard case .group(let members) = try require(groups.first) else {
                throw TestFailure(message: "expected one .group of three")
            }
            try expect(members.map(\.id) == ["a", "b", "c"])
        }

        r.run("empty input produces no groups") {
            try expect(groupForRendering([]).isEmpty)
        }
    }
}
