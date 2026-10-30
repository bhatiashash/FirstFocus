# 02: One rule for what counts as Later

**What to build:** The split between Focus and Later, label deduplication and the snooze filter are written once and used by both the ranking and the Later count the Morning Brief reports. Today the Ranked List derives the Later count with its own copy of that rule.

**Blocked by:** None (can start immediately). Do it after 01, which touches the same file, to avoid merge conflicts.

**Status:** ready-for-agent

- [ ] Ranking and the Later count read the same derivation.
- [ ] A test gives the Later count a snoozed reminder, a duplicate label and a dated reminder, and checks the count equals the length of the Later list before the cap.
- [ ] The Morning Brief's "in Later" count is unchanged for existing tests.
