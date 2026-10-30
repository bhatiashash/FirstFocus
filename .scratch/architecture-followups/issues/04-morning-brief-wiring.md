# 04: Morning Brief wiring in the tested composition

**What to build:** The Morning Brief's preference, delivery and view model are built in the same dependency composition as the rest of the app, so the test harness builds the Brief the way the app does. Today the executable builds them by hand and the test harness copies that wiring.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] The executable builds the Brief through the dependency composition, with no copy in the test harness.
- [ ] A test starts the model and checks the Brief is sent after a wake-up within its window, using the fake alarm.
- [ ] The Brief's behaviour in the running app is unchanged.
