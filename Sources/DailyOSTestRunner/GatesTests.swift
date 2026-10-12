import DailyOSCore
import EventKit
import Foundation

func registerGatesTests(_ runner: TestRunner) {
    runner.suite("messagesAvailability") { r in
        r.run("a successful open means available") {
            try expect(messagesAvailability(canOpen: true) == .available)
        }
        r.run("a failed open means unavailable") {
            try expect(messagesAvailability(canOpen: false) == .unavailable)
        }
    }

    runner.suite("reminderAvailability") { r in
        r.run("full access means available") {
            try expect(reminderAvailability(authorizationStatus: .fullAccess) == .available)
        }
        r.run("not determined means unavailable") {
            try expect(reminderAvailability(authorizationStatus: .notDetermined) == .unavailable)
        }
        r.run("denied means unavailable") {
            try expect(reminderAvailability(authorizationStatus: .denied) == .unavailable)
        }
        r.run("restricted means unavailable") {
            try expect(reminderAvailability(authorizationStatus: .restricted) == .unavailable)
        }
        r.run("write-only means unavailable — it doesn't grant listOpenTasks or complete") {
            try expect(reminderAvailability(authorizationStatus: .writeOnly) == .unavailable)
        }
    }

    runner.suite("identityMismatch") { r in
        r.run("nothing stored yet is never a mismatch") {
            try expect(identityMismatch(current: "DailyOS Local Dev", stored: nil) == false)
        }
        r.run("matching current and stored is not a mismatch") {
            try expect(identityMismatch(current: "DailyOS Local Dev", stored: "DailyOS Local Dev") == false)
        }
        r.run("a different stored identity is a mismatch") {
            try expect(identityMismatch(current: "DailyOS Local Dev", stored: "Some Other Identity") == true)
        }
    }
}
