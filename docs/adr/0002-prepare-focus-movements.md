# Prepare Focus movement before changing Reminders

Focus reconciliation saves the home, source and intended destination before moving a reminder because Reminders and SQLite cannot participate in one transaction. Failed preparation prevents movement; an unfinished movement is reconciled against its observed location after refresh or restart. Execution uses only the prepared destination: if that list disappears, a later refresh must prepare a new destination rather than taking an unrecorded fallback.

A distinct newer manual destination is authoritative. TaskSource exposes no movement revision, so a manual return to exactly the pending source before restart cannot be distinguished from a move that never executed; recovery retries the pending intent in that case. Failed sync waits for a new Reminders fetch, and repeated presentation does not retry or duplicate its error message.
