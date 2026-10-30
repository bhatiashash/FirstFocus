import FirstFocusCore
import Foundation

func registerMessagesSourceTests(_ runner: TestRunner) {
    runner.suite("epochDate: Core Data epoch, seconds vs nanoseconds") { r in
        r.run("a value at or above 1e12 is treated as nanoseconds since 2001-01-01") {
            // 810590608352999936 ns ≈ a real row from the snapshot, well
            // into 2026.
            let date = epochDate(fromCoreDataValue: 810_590_608_352_999_936)
            let components = Calendar(identifier: .gregorian).dateComponents([.year], from: date)
            try expect(components.year == 2026)
        }
        r.run("a value below 1e12 is treated as plain seconds since 2001-01-01") {
            // A pre-High-Sierra migrated row: seconds, not nanoseconds.
            // 600_000_000 seconds ≈ 19 years after 2001-01-01.
            let date = epochDate(fromCoreDataValue: 600_000_000)
            let components = Calendar(identifier: .gregorian).dateComponents([.year], from: date)
            try expect(components.year == 2020)
        }
        r.run("zero decodes to exactly the Core Data epoch, 2001-01-01 UTC") {
            let date = epochDate(fromCoreDataValue: 0)
            try expect(abs(date.timeIntervalSince1970 - 978_307_200) < 1)
        }
        r.run("the threshold itself (1e12) is treated as nanoseconds, not seconds") {
            // 1e12 ns is about 2001-01-01 00:16, decades before any real
            // message; no plausible seconds value reaches this high.
            let date = epochDate(fromCoreDataValue: 1_000_000_000_000)
            try expect(date.timeIntervalSince(Date(timeIntervalSince1970: 978_307_200)) < 3600)
        }
    }

    runner.suite("selfChatIds: several self-chats union correctly") { r in
        r.run("a chat whose identifier matches an own address is included") {
            let ids = selfChatIds(
                ownAddresses: ["+15551234567"],
                chats: [(chatId: 78, identifier: "+15551234567")]
            )
            try expect(ids == [78])
        }
        r.run("several self-chats are all returned, matching the real machine's three") {
            let ids = selfChatIds(
                ownAddresses: ["+15551234567", "me@icloud.com", "+15559876543"],
                chats: [
                    (chatId: 78, identifier: "+15551234567"),
                    (chatId: 165, identifier: "+15559876543"),
                    (chatId: 59, identifier: "me@icloud.com"),
                ]
            )
            try expect(Set(ids) == Set([78, 165, 59]))
        }
        r.run("a chat belonging to someone else is excluded") {
            let ids = selfChatIds(
                ownAddresses: ["+15551234567"],
                chats: [
                    (chatId: 78, identifier: "+15551234567"),
                    (chatId: 99, identifier: "+15550000000"),
                ]
            )
            try expect(ids == [78])
        }
        r.run("malformed destination_caller_id variants that match no chat are harmlessly ignored") {
            // Real data shows destination_caller_id can appear as
            // "+1555...", "1555..." (no plus) and "tel:+1555..." for the
            // same underlying number; only exact chat_identifier matches
            // matter, so the extra forms simply match nothing.
            let ids = selfChatIds(
                ownAddresses: ["+15551234567", "15551234567", "tel:+15551234567"],
                chats: [(chatId: 78, identifier: "+15551234567")]
            )
            try expect(ids == [78])
        }
        r.run("no matching chats returns empty, not every chat") {
            let ids = selfChatIds(
                ownAddresses: ["+15551234567"],
                chats: [(chatId: 99, identifier: "+15550000000")]
            )
            try expect(ids.isEmpty)
        }
    }

    runner.suite("resolveChatIdentifier: Deep Linking (ticket 02)") { r in
        r.run("a one-to-one Chat (exactly one participant) resolves to its chat_identifier") {
            let identifier = resolveChatIdentifier(
                forChatId: 78, chatIdentifiers: [78: "+15551234567"], participantCounts: [78: 1]
            )
            try expect(identifier == "+15551234567")
        }
        r.run("a self-chat (no participant rows at all) also resolves — zero counts as targetable") {
            let identifier = resolveChatIdentifier(
                forChatId: 59, chatIdentifiers: [59: "+15551234567"], participantCounts: [:]
            )
            try expect(identifier == "+15551234567", "a missing key means zero participants, which is still one-to-one (or self)")
        }
        r.run("a group Chat (more than one participant) resolves to nil — no specific-chat targeting is possible") {
            let identifier = resolveChatIdentifier(
                forChatId: 99, chatIdentifiers: [99: "chat123456789"], participantCounts: [99: 3]
            )
            try expect(identifier == nil)
        }
        r.run("exactly two participants is already a group — the boundary is more than one, not more than two") {
            let identifier = resolveChatIdentifier(
                forChatId: 99, chatIdentifiers: [99: "chat123456789"], participantCounts: [99: 2]
            )
            try expect(identifier == nil)
        }
        r.run("a chatId with no identifier on record resolves to nil even if it would otherwise be targetable") {
            let identifier = resolveChatIdentifier(
                forChatId: 78, chatIdentifiers: [:], participantCounts: [78: 1]
            )
            try expect(identifier == nil)
        }
    }

    runner.suite("shouldIncludeMessage: ADR 0007's per-row rule") { r in
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cutoff = now.addingTimeInterval(-3600)

        r.run("a self-chat message the user sent is included") {
            try expect(shouldIncludeMessage(
                chatId: 78, isFromMe: true, createdAt: now - 999_999,
                selfChatIds: [78], excludedChatIds: [], nonSelfCutoff: cutoff
            ))
        }
        r.run("a self-chat message the user received (the sent-to-self duplicate row) is excluded") {
            try expect(shouldIncludeMessage(
                chatId: 78, isFromMe: false, createdAt: now,
                selfChatIds: [78], excludedChatIds: [], nonSelfCutoff: cutoff
            ) == false)
        }
        r.run("a self-chat message from long before the cutoff is still included — self-chats are never cutoff-bound") {
            try expect(shouldIncludeMessage(
                chatId: 78, isFromMe: true, createdAt: Date(timeIntervalSince1970: 0),
                selfChatIds: [78], excludedChatIds: [], nonSelfCutoff: cutoff
            ))
        }
        r.run("a non-self message received after the cutoff is included") {
            try expect(shouldIncludeMessage(
                chatId: 99, isFromMe: false, createdAt: now,
                selfChatIds: [78], excludedChatIds: [], nonSelfCutoff: cutoff
            ))
        }
        r.run("a non-self message sent after the cutoff is included — both directions count") {
            try expect(shouldIncludeMessage(
                chatId: 99, isFromMe: true, createdAt: now,
                selfChatIds: [78], excludedChatIds: [], nonSelfCutoff: cutoff
            ))
        }
        r.run("a non-self message from before the cutoff is excluded — never backfilled") {
            try expect(shouldIncludeMessage(
                chatId: 99, isFromMe: false, createdAt: cutoff.addingTimeInterval(-1),
                selfChatIds: [78], excludedChatIds: [], nonSelfCutoff: cutoff
            ) == false)
        }
        r.run("a non-self message exactly at the cutoff is excluded — the cutoff is the moment reading started, not the first message read") {
            try expect(shouldIncludeMessage(
                chatId: 99, isFromMe: false, createdAt: cutoff,
                selfChatIds: [78], excludedChatIds: [], nonSelfCutoff: cutoff
            ) == false)
        }
        r.run("an excluded (Automated) chat is dropped regardless of direction or date") {
            try expect(shouldIncludeMessage(
                chatId: 99, isFromMe: false, createdAt: now,
                selfChatIds: [], excludedChatIds: [99], nonSelfCutoff: cutoff
            ) == false)
        }
        r.run("Automated exclusion beats even the self-chat rule") {
            try expect(shouldIncludeMessage(
                chatId: 78, isFromMe: true, createdAt: now,
                selfChatIds: [78], excludedChatIds: [78], nonSelfCutoff: cutoff
            ) == false)
        }
    }
}
