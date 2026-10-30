# 06: AppModel stops mirroring the Advanced list ticks

**What to build:** The app reads which Reminders lists are ticked from the Focus list, and no longer keeps its own copy that it patches after each tick. The list-hiding change removed the first-run rule that needed the mirror, so this is a small cleanup.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Unticking and ticking a list in Advanced still updates the checkbox, the list in the window and the Focus list.
- [ ] AppModel holds no separate copy of the ticks.
- [ ] Existing Focus list tests pass.
