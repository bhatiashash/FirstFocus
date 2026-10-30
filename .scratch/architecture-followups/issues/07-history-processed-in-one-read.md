# 07: History facts in one processed-state read

**What to build:** Reading the facts for a set of History Batches asks the store once which of them are Processed, instead of opening a store connection per Batch. The Not for me offers on the Inbox and a History refresh both call it for many Batches at once.

**Blocked by:** None (can start immediately).

**Status:** done

- [x] The signal store answers "which of these source references are Processed" in one read.
- [x] The History facts use it, and the batch query is tested for correctness (the connection count is not tested, as agreed).
- [x] Which Batches count as Processed is unchanged.
