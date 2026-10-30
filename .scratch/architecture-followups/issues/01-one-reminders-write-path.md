# 01: One Reminders write path in the Signal Board

**What to build:** Every action that changes a reminder (check off, snooze, create, rename, delete, set priority, move) goes through one write path in the Signal Board. The path does the write off the main thread, refetches Reminders, and tells the caller whether the write landed. Today each verb repeats its own copy of that sequence and discards failures.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] The Signal Board has one place that performs a Reminders write and its refetch; no verb repeats the sequence.
- [ ] A caller can tell whether a write failed. Existing behaviour on success is unchanged.
- [ ] A test using the fake task source makes a write fail and checks what the Board and the caller see.
- [ ] The test runner passes with the same count or more tests.
