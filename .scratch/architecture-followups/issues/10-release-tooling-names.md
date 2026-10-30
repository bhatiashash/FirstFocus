# 10: Release tooling uses the FirstFocus names

**What to build:** The build script defaults to a signing certificate named "FirstFocus Local Dev" and an env file under a FirstFocus data folder, but the keychain still holds "DailyOS Local Dev" and the data folder is still named for DailyOS. Rename them, or change the defaults and document it, then run a release build end to end without passing the certificate by hand.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] A build with no environment variables set signs with the certificate that exists.
- [ ] The build script and the release script comments name the files and certificate that are in use.
- [ ] A signed release build succeeds.
