# 03: Pass scheduling apart from what a pass does

**What to build:** One module decides whether a Messages pass starts: the pass slot, joining a running pass, the follow-up pass, the running kind and the re-extraction cooldown, all judged against the injected clock. What a pass does (read, garbage collect, backfill, extract) stays elsewhere. Start by reading what the "IntakeRunner owns the passes" commit already moved, and shrink this ticket to what is left.

**Blocked by:** None (can start immediately).

**Status:** done

- [x] Queueing, joining and the follow-up pass are tested without Messages or model fakes.
- [x] No pass reads the wall clock directly; the passes that did use the injected clock.
- [x] The re-extraction double-click guard and the slot guard live in one place.
- [x] Existing pass tests still pass.
