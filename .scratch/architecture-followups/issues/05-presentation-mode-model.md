# 05: Presentation mode model for Zen, Minimal View and Esc

**What to build:** One module owns the Zen Focus Mode and Minimal View flags and the order Esc acts in. Zen exits first, since it can sit on top of Minimal View. It replaces the one-line predicates for Esc, Command-Z and the checked-off count text, which exist only to be tested.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] A test checks that Esc with both modes on exits Zen first, then Minimal View.
- [ ] The predicate modules for Esc and Command-Z are gone, and their cases are covered by the new module's tests.
- [ ] Zen window sizing keeps working as before.
