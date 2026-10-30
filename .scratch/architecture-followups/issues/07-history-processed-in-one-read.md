# 07: History facts in one processed-state read

**What to build:** Reading the facts for a set of History Batches asks the store once which of them are Processed, instead of opening a store connection per Batch. The Not for me offers on the Inbox and a History refresh both call it for many Batches at once.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] The signal store answers "which of these source references are Processed" in one read.
- [ ] The History facts use it, and a test checks a refresh with many Batches opens one connection for Processed state.
- [ ] Which Batches count as Processed is unchanged.
