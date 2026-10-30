# 09: Approved tasks never vanish into a hidden list

**What to build:** Approving a Suggestion makes a reminder in the default Reminders list. If you unticked that list in Advanced, the approved task disappears at once. Decide between warning when you untick the default list, creating approved tasks in a list that is shown, or showing an approved task until the next refresh. Then make that happen.

**Blocked by:** None (can start immediately).

**Status:** done

- [x] Approving a Suggestion while the default list is unticked has a defined result, chosen and recorded in the ticket comments.
- [x] A test covers the case.
- [x] The Lists section footer and the view reference describe the behaviour.

## Comments

Decision: keep approval as it is, and label the default list in Advanced. Approving still makes the reminder in the default list and clears the Suggestion; if that list is unticked the reminder is hidden. The default list shows "Approved tasks from messages go here", and a warning in orange while it is unticked.
