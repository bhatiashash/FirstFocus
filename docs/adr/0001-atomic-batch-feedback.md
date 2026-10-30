# Treat feedback and its dismissals as one durable action

“Not for me” and its Undo use a single SQLite transaction over Corrections and Suggestions rather than coordinating independent store writes. Persisted ownership identifies which dismissals Undo may reverse; later changes invalidate that ownership, while a Batch revision prevents failed actions from replaying stale intent. This deliberately depends on the production stores sharing one database, and leaves History and Inbox as callers of the same feedback operation.

Failure leaves both records unchanged and produces a nonblocking, retryable message. Retry notices are session-local; persisted ownership keeps History Undo available after relaunch. If the initial feedback state was unreadable, Retry refreshes storage without replaying an unverifiable action.
