# 08: Inbox and Section tests drive InboxTriage directly

**What to build:** The tests for the Suggestion popover, the Inbox key guards and Section collapse no longer build a full AppModel with a fake task source, a store and an alarm. They run against the InboxTriage value, with one AppModel test left for the wiring.

**Blocked by:** None (can start immediately).

**Status:** done

- [x] The key guard, popover and collapse cases are covered by InboxTriage tests and removed from the AppModel tests.
- [x] At least one AppModel test remains that checks a key press reaches Approve or Dismiss.
- [x] The number of cases covered does not shrink.
