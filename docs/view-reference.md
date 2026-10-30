# FirstFocus View Reference

The app was called DailyOS until 0.1.6; the code, bundle identifier and executable now use the name FirstFocus.

Every screen and control, mapped to what it does today. Updated with every UI change.

Last updated: 2026-10-30

## Nonblocking failures

Storage and Focus sync failures appear in a shared message area at the bottom of the window, including Main, History and Advanced. They do not open a modal or prevent other actions. Each failure has Dismiss; repeated attempts update the same message rather than adding duplicates.

- **Not for me:** History and the Inbox save the Correction and dismiss the Batch’s currently open message Suggestions together. Failure changes neither the Correction nor Suggestions and offers no success or new Undo bar. Retry attempts the original action only if the Batch and its eligibility have not changed; otherwise the message asks you to review current actions. Other Batches are unaffected.
- **Undo Not for me:** deleting the action’s Correction and reopening its still-owned dismissals happen together. A later approval, completion, dismissal or replacement feedback is never reversed. Failure leaves both records unchanged and offers Retry independently of the Undo bar, even after that bar clears or expires. Ownership survives relaunch; History can still undo the recorded action. Retry messages themselves last for the current app session.
- **Unreadable feedback state:** Retry refreshes storage without replaying an action whose original state could not be verified. After recovery, choose Not for me or Undo in History again.
- **Focus list sync:** a message distinguishes an unreadable sync record, a record that could not be saved, and a Reminders update failure. Sync automatically retries on the next meaningful Reminders refresh, not in a tight loop. Dismissing a message keeps the same ongoing failure quiet; successful sync clears it, allowing a future failure to be reported again.

## Window chrome and toolbar

One window: sidebar on the left, the selected screen on the right. Zen Focus Mode and Minimal View hide the sidebar and the toolbar; only the traffic lights and title stay.

The window can't be made smaller than 1110 × 520 (350 × 120 in Zen). The width fits History with the Inspector open: sidebar 200 (fixed), Batch list 250, detail 400, Inspector 250, plus the dividers. The Batch list stays 250; widening the window widens the detail pane. The divider between the detail pane and the Inspector can be dragged; the Batch list's can't. The limit is the same on every screen, so switching screens in the sidebar never resizes the window.

| Element | What it does |
|---|---|
| Traffic lights | Standard close / minimize / zoom. Always shown, Zen and Minimal View included. |
| Sidebar toggle (`sidebar.left`, top left) | Shows or hides the sidebar. Stays beside the traffic lights either way. |
| Title "FirstFocus" | Static. |
| Zen Focus Mode (`leaf`, top right, left of `+`) | Turns Zen on: Main shows Focus only (plus Notices), the sidebar and toolbar hide, and the window shrinks to 380pt wide with its height hugging the list (it can be resized down to 350 × 120). Leave with Esc or View → Zen Focus Mode (⇧⌘F); the screen, sidebar and window size come back. Remembered across launches. |
| `+` (not reachable in Zen or Minimal View, which hide the toolbar) | Switches to Main and opens an inline "New Reminder" field just under the Focus header, lined up with the tasks. ⏎ creates the reminder with a Priority (so it stays in Focus) and clears the field for the next; ⏎ on an empty field, Esc or clicking away closes it. With no Focus on screen, the field sits at the top instead and the reminder lands in Later. A reminder that lands in Later, either way, opens Later if it was collapsed. A date phrase ("tomorrow", "friday", "next week", "this weekend", "end of month", "in 3 days") shows a gray badge beside the field: "Today", "Tomorrow", or the date ("Fri, Oct 2"); ⏎ then saves the reminder with that due date, without the phrase and without a Priority. No badge when the phrase is the whole text ("tomorrow" alone is saved as a title). The badge's × or ⌫ straight after it appears cancels it, and the words stay as typed for the rest of that reminder. |
| Minimal View (`arrow.down.right.and.arrow.up.left.square`) | Turns Minimal View on. Same as View → Minimal View (⇧⌘M). |

Toolbar items show icons only. Right-clicking the toolbar offers no Icon and Text / Icon Only / Text Only choice.

There is no `...` menu. Re-run Extraction, History export and the unfiltered History log are in the menu bar (see Other windows and modes).

## Sidebar

| Element | What it does |
|---|---|
| Main (`list.bullet`) | Ranked list. |
| History (`clock.arrow.circlepath`) | Batch log. |
| Models (`cpu`) | Model catalog. |
| Advanced (`gearshape`) | Behavior settings. |
| About (`info.circle`) | Read-only reference. |
| Footer status | Spinner + "Re-extracting… n of m", only during a re-extraction you started. Routine intake passes show nothing. With the sidebar hidden (including Zen and Minimal View), the same status floats as a capsule at the top right of the screen. |
| Footer dot | Green: extraction model loaded. Red: the model file is there but didn't load. Gray: no model file, as after deleting the active model. |
| Footer model name | Active model, "No model loaded", or "No model selected" when there's no model file. |
| Footer version | `arrow.triangle.2.circlepath` and the app version, together one button: click to check for updates, the same as FirstFocus → Check for Updates…. Reads "Checking for updates…", with the icon turning, and ignores clicks while any check, including the daily one, waits on the feed; back to the version once Sparkle has an answer. Sparkle then shows the new version with its release notes, or "You're up to date". Tooltip "Check for Updates". |

## Main

States, in order of precedence: "Reading your self-thread… n of m" (first-run backfill), "Loading…", "Nothing open. Nice." (with the Checked Off count at the bottom of the window, if any), Zen (Focus header and rows only, plus any Notice), or the list.

**Sections** (top to bottom; each only when non-empty, except the empty Focus drop zone)

| Section | Header control | Contents |
|---|---|---|
| Suggested | Chevron collapses / expands; starts expanded | Inferred Signals waiting for Approve or Dismiss. Collapsing it drops keyboard focus and closes any preview. |
| Focus | None; takes drops | Overdue, has a Priority, or due today or tomorrow. Ordered by any order you dragged, then dated rows (most overdue first, then soonest), then undated rows by Priority, then newest. When empty but Later has rows: a dashed "Drag a task here to move it into Focus." drop zone (not in Zen). |
| Later | Chevron collapses / expands; starts expanded; opens when a reminder you add lands in it; takes drops, even collapsed | Everything else. Rows due after tomorrow come first, soonest first, then undated rows, newest first. A dated row moves into Focus by itself the day before it's due. |
| Snoozed | "Snoozed (N)" · chevron collapses / expands; starts collapsed (collapse state is not saved between launches); takes no drops; not in Zen | Snoozed rows, soonest to return first. Their rows don't count toward Later's cap. |
| Notice: Messages | None | "Full Disk Access is needed…" · Open System Settings · Retry. |
| Notice: Reminders | None | "Reminders access is needed…" · Open System Settings · Retry. |
| Notice: Extraction | None | "The local extraction model failed to load…" · Retry. |

**Suggested row**

| Element | What it does |
|---|---|
| `plus.circle` (hover or keyboard focus) | Approve: creates a real reminder. Shows the Undo bar: "Added "…" to Later" (or "to Focus"). Undo deletes the reminder and puts the row back with keyboard focus on it. |
| Label + original text (gray, when it adds something) | Static. |
| Sender chip (first name) | Static. |
| Source icon | Tooltip names the source and sender. |
| `hand.thumbsdown` (hover or keyboard focus) | Not for me: records a false positive for the Batch, as History does, and dismisses the row. Only when the model found this one task in the Batch, History has its model-call row with a Chat, and the Batch has no missed-task Correction. Otherwise its space stays blank, so × keeps its column. No key. Shows the Undo bar: "Marked "…" Not for me". Undo does what History's Undo does and puts keyboard focus on the row. |
| `xmark` (hover or keyboard focus) | Dismiss. Records nothing. Shows the Undo bar: "Dismissed "…"". Undo puts the row back with keyboard focus on it. |
| Swipe left: Dismiss | Same as `xmark`. |
| Swipe left: Tomorrow / Next Week | Approves it and Snoozes the new reminder, which goes straight to the Snoozed Section. Records nothing for extraction. Shows the Undo bar: "Added "…", snoozed until Mon 12 Oct". Undo deletes the reminder and puts the row back. |
| Click row | Opens the Chat in Messages. |
| Hover 0.5 s | Opens the preview popover (earlier context, then the Batch). Closes on hover out. |

**Focus / Later row**

| Element | What it does |
|---|---|
| Drag (press and hold anywhere on the row) | Onto a Focus row: reorders, or moves a Later row into Focus (gives it a Priority) at that spot. Onto a Later row or header: moves a Focus row to Later (clears its Priority); refused for a row due today, tomorrow or earlier. |
| `circle` (flush with the section header) | Check off. Shows the Undo bar. |
| Label | Static. URLs are left out; they're listed in the drawer. |
| `note.text` glyph (gray, after the Label) | Shown only on rows with Notes, a link, or a Chat to open. |
| "Inferred" chip (hover) | Static. |
| Source icon (inferred only) | Tooltip names the source and sender. |
| `xmark` (hover, Messages only) | Dismiss. |
| Due date | Red when overdue: a date with no time once its day has ended, a date with a time once that time has passed, judged when the list was last worked out. The Morning Brief marks "(overdue)" by the same rule. Nothing is drawn when there's no date and a sender pill, so those rows stay the normal height. |
| Sender pill (blue) | Static. |
| Click row (only with the glyph) | Opens or closes the Notes drawer under the row; opening another row's closes this one. Instant under Reduce Motion. A row without the glyph ignores the click. In Zen, the window grows to fit an open drawer (up to Zen's usual maximum) and shrinks back when it closes. |
| Drawer: Notes | The reminder's Notes (for an approved Suggestion, the whole Batch with names), or a Messages Signal's original wording. Read-only; selectable. |
| Drawer: links (`link`, gray, underlined) | Every link in the Notes, the title and the reminder's URL. Opens it. |
| Drawer: Open in Messages (`message`) | Only for a one-to-one Chat. Opens that Chat. |
| Right-click | Snooze until Tomorrow · Snooze until Next Week · Move to Focus (Later rows) · Move to Later (Focus rows with a Priority and no due date by tomorrow) · Rename… and Delete (Reminders only). Rename… opens a sheet with the title in an editable field, Cancel (Esc) and Save (⏎). A date phrase typed into it shows the same badge as the `+` field, and Save sets that date as the due date and drops the phrase from the title; dates already in the title when it opens stay words, so saving it unchanged never moves the due date. Without a phrase, Save changes only the title. Delete asks to confirm. |
| Swipe left: Tomorrow (`sunrise`) / Next Week (`calendar`) | Snoozes until 8 AM tomorrow (8 AM today if it's before 8 AM), or until 8 AM on the coming Monday. Closes an open drawer first. Shows the Undo bar. |
| Swipe left: Delete (Reminders) / Dismiss (Messages) | Same as the menu / `xmark`. Closes an open drawer first. |

**Snoozed row** (in the Snoozed Section): the same as a Focus / Later row, except:

| Element | What it does |
|---|---|
| Return time (gray pill, in the date column, left of any due date) | Static. "Mon 8 AM". |
| Drag, drop | None. |
| Right-click | Unsnooze · Snooze until Tomorrow · Snooze until Next Week · Rename… and Delete (Reminders only). No Move to Focus or Move to Later. |
| Swipe left: Unsnooze (`arrow.uturn.backward`) | Puts the row back in Focus or Later at its computed place. No Undo bar. |
| Swipe left: Tomorrow / Next Week | Replaces the return time. Shows the Undo bar. |
| `circle` | Check off, as anywhere else. |

**Checked Off count** (pinned to the bottom of the window, outside the scrolling list, under the list and under "Nothing open. Nice."; the Undo bar covers it while it shows): "1 reminder completed today" / "N reminders completed today", small gray text, centered. Click opens the Checked Off sheet. Counts reminders checked off today, wherever that happened; a check off made here counts once its Undo bar is gone. Hidden when the count is 0, in Zen, and on the loading and backfill screens.

**Checked Off sheet** (click the count, or View → Checked Off Today ⇧⌘C): title "Completed Today", 400pt wide, up to 600pt tall, rows scroll inside. Rows newest first, updated live. Unchecking a row removes it at once. When empty (last row unchecked, midnight, or Reminders access lost) it stays open and shows "No reminders completed today". Done (bottom right, ⏎), Esc or ⇧⌘C close it; entering Zen closes it too. ⌘Z does nothing while it's open.

**Checked Off row** (in the sheet)

| Element | What it does |
|---|---|
| `checkmark.circle.fill` | Uncheck: reopens the reminder, which goes back to Focus or Later at its computed place, not where it was dragged. No Undo bar; ⌘Z doesn't reverse it. On a repeating reminder it's dimmed and ignores clicks, with the tooltip "Repeating reminder. Change it in Reminders." |
| Label (struck through, gray) | Static. |
| Due date (gray, never red) | Static. |

Nothing else: no drag, drop, snooze, right-click menu, Notes drawer or Sender pill.

**Undo bar** (bottom, one at a time): "Checked off "…"" · Undo, after a check off. After a Dismiss (× or Delete): "Dismissed "…"" · Undo. After an Approve (+ or Return): "Added "…" to Later" or "to Focus" · Undo. After the thumbs-down: "Marked "…" Not for me" · Undo. After a snooze: "Snoozed "…" until Mon 12 Oct" · Undo, which puts back the snooze the row had before, or none. After Tomorrow or Next Week on a Suggestion: "Added "…", snoozed until Mon 12 Oct" · Undo. After `+` adds a reminder that lands in Later, such as one due after tomorrow: "Added "…" to Later", no button. Lasts 5 seconds. A newer action replaces it, and the one it showed stays done. ⌘Z presses Undo while no text field is being edited.

**Inline "New Reminder" field** (under the Focus header, after `+`): see the toolbar's `+`.

**Keyboard** (Suggested only, once a Suggestion has focus, and never while Suggested is collapsed): ↑ ↓ move · ⏎ Approve · ⌫ Dismiss · Space preview · Esc close preview.

## History

Everything about Screening in History shows only while the Screening toggle in Advanced is on, with or without a key. With it off, History hides the Borderline view, the Screened and Borderline counts, the Screening failed and Borderline badges and This was work, and a Batch Jev once Screened reads "Not read by the model." Copy Raw Output then copies only the model's answer. Stored rows are kept, and turning the toggle back on shows them as before. History re-reads each time it's shown and whenever the toggle flips, so it follows the toggle at once, with its views, counts, badges and buttons changing together. The Inspector is the exception: it shows whatever Screening a Batch stored, toggle on or off.

| Element | What it does |
|---|---|
| View picker (toolbar center) | Overview (default): Batches with a task, plus Borderline, Corrected, any Batch the model failed on, and any Batch whose UPDATE or CANCEL replaced or withdrew a Suggestion (and a Muted Chat's last Batch); every Batch with View → Show Unfiltered History Log (⇧⌘L) on. That is needed to reach Add Task… on a Batch where the model found nothing, and This was work on a Screened Batch that isn't Borderline. Borderline (with count; only while the Screening toggle is on): Screening scored within 0.1 of the cutoff. With the toggle off, Borderline is no reason for Overview to list a Batch, and a Borderline view left selected falls back to Overview. Corrected: has a Correction. Starred. |
| Inspector button (`sidebar.right`) | Shows or hides the Inspector pane. The Inspector is at least 250 wide; drag its divider to widen it. The detail pane narrows (to no less than 400); the window doesn't grow. Remembered across launches. |
| "Past 7 days" header | Counts: Batches · with a task · Screened · Borderline · corrected. Screened and Borderline only while the Screening toggle is on. |
| List row | Chat title or Sender, time, first line, badges (Task / n tasks, Model failed, Screening failed, Borderline score, Corrected, Muted; Screening failed and Borderline only while the Screening toggle is on). Grouped by day; "Earlier" for pinned Muted Chats. The list re-reads after every action, whenever a Messages pass ends, when the Screening toggle flips, and when a model loads or unloads, so new Batches show without leaving History. A button drawn before something changed does nothing if the action no longer applies. |
| Right-click row | Not for me (Undo Not for me once marked) · Restore · This was work · Try Again · Mute/Unmute Thread · Re-run Against Active Model · Star/Unstar · Copy Raw Output · Delete. Each only where it applies and the row recorded what it needs. With no model loaded, This was work, Try Again and Re-run show disabled, titled "(No model loaded)". |

**Detail pane**

| Element | What it does |
|---|---|
| Date | Static. |
| Transcript | Chat bubbles. Context lines dimmed; "Judged from here" marks where the Batch starts. |
| Result | Task labels, or a summary (no task, "The model call failed (reason).", Screened with score, let through, Screening failed; with the Screening toggle off, any Batch the model never judged reads "Not read by the model."). Below it, in secondary text, one line per Suggestion the Batch Superseded: "Replaced: <label>" for an UPDATE, "Withdrew: <label>" for a CANCEL. Suggestions Superseded before this was recorded show nothing. |
| Add Task… | Only when the model found nothing, or when intake gave up on the Batch after the model failed on it three times, or, with the Screening toggle off, on a Screened Batch the model never judged; and only when the row recorded its Chat and messages (older rows may not have). Alert: type the task, Add. Puts it in Suggested and records a missed-task Correction. Becomes "Task Added". |
| Not for me | Only when the Batch produced a task, the row recorded its Chat, and the Batch has no missed-task Correction. Dismisses it and records a Correction. Becomes "Marked Not for me", also when taken from Suggested, with Undo beside it: deletes the Correction and puts back in Suggested what "Not for me" dismissed. No confirmation. |
| Restore | Only on a Batch whose UPDATE or CANCEL Superseded a Suggestion. Puts that Suggestion back in Suggested under its own id; for an UPDATE, also dismisses the replacement if it is still in Suggested. Records no Correction. Not offered once an UPDATE's replacement is Approved or itself replaced. Becomes "Restored", also once a later Batch Supersedes the same Suggestion again (that Batch then offers Restore). |
| This was work | Only on a Screened Batch the model hasn't judged, and only while the Screening toggle is on. Sends it to the model now, after any pass already running; records a Screening miss. Disabled with no model loaded; hover says "No model loaded". |
| Try Again | Only on a Batch intake gave up on after the model failed on it three times (while it has tries left, intake retries it on its own each pass). Sends it to the model now, after any pass already running, and keeps any task it finds. Records no Correction. Disabled with no model loaded; hover says "No model loaded". |
| Mute / Unmute Thread | Only when the row recorded its Chat. Stops or restarts Extraction for this Chat. |
| More menu | Re-run Against Active Model (disabled, titled "(No model loaded)", with no model loaded) · Star/Unstar · Copy Raw Output · Delete. |

**Inspector pane** (the three Screening sections show whenever the Batch has them, whatever the Screening toggle says): Screening (score, cutoff, mode, decision, service) · Screening failed (reason) · Screening unavailable (the Batch skipped Jev because it had failed three times in a row or rejected the key within the last 15 minutes, and went straight to the model; no row badge) · Model output (model, raw text) · Prompt the model saw (Screening's input when the model never saw the Batch) · Re-runs · Audit Sample · Identifiers (message id, Chat id). Read-only.

## Models

| Element | What it does |
|---|---|
| Local Models / Available to Download | Model cards. Headers show only when both groups exist. Local Models lists every `.gguf` in the models folder, re-read each time Models opens. A file that isn't one of the three catalog models is named after its filename, without `.gguf`, and has no quantization. |
| Card: name, quantization, "Active" | Static. The active card is tinted gray. Progress bar while downloading; red message on failure. |
| Use | Switches extraction to this model. Hidden on the active one. |
| Trash | Deletes the file. Confirms first for the active model. Deleting the active model unloads it: the footer turns gray, Main shows Extraction unavailable, and new Batches wait unprocessed until a model is chosen. |
| Download / Cancel | Starts or stops a download. |
| Choose Custom File… (right-aligned under the list) | Picks a local GGUF file and uses it where it is; it isn't copied. It gets a card only if it's in the models folder. |
| Open Models Folder (right-aligned under the list) | Opens the folder in Finder. |

## Advanced

| Section | Controls |
|---|---|
| Morning Brief | "Send every day" toggle, off by default and disabled until your number is found, and a Time picker (8:00 AM by default). While on, the Brief goes out at that time; if the Mac was asleep or FirstFocus wasn't running, at the next wake or launch within four hours of it (never past midnight). At most one a day; a failed send is tried again at the next wake or launch in that window. Turning it on inside the window sends today's if none went out yet; changing the time sends nothing by itself. Edit Format: text around {rest} on its line repeats on every Signal it lists ("- {rest}"). "Sends to your Self-thread": the address of the conversation you have with yourself in Messages (with more than one, the one you wrote in most recently), read each time Advanced opens; not editable, since the Brief only goes to you. With none found it reads "No number found" with a line saying to text yourself once and check Full Disk Access, and the toggle and Send Test are disabled. "Focus Signals to list" picker: Top 3, Top 5, Top 10, All (default); a cut list ends with "+N more in Focus". Edit Format… opens a sheet (by default each Signal is its own plain line): a Message box ({top}, {rest}, {more}, {later}), an Each item field ({n}, {label}, {overdue}) used for every Signal, the first included, a live Preview of the Brief from the current Ranked List, Reset to Default (disabled while unchanged) and Done. Edits save as you type; the "FirstFocus Morning Brief" first line can't be edited. Send Test (disabled with no number found; spinner while sending) texts the Brief built from the Ranked List as it is now, through Messages, whatever the toggle says, and never counts as the day's Brief. The first send brings up macOS's prompt to let FirstFocus control Messages. Status line under it: "Last sent today at 8:00 AM." or "Last send failed … " with the reason (Automation not allowed, Messages not signed in, or Messages couldn't send it); absent before the first send. Footer: texts your Focus list to you through Messages on this Mac, and when a missed Brief still goes out. |
| Lists | Above Focus List. A checkbox per Reminders list by title (the Focus list left out), read each time Advanced opens and working whether or not the Focus list is on. A list is ticked unless you unticked it, so a list made later starts ticked. Unticking a list hides its reminders from FirstFocus at once: Focus, Later, Snoozed, the Checked Off sheet and the Morning Brief; ticking it brings them back. The Focus list leaves an unticked list's reminders alone. A task approved from a message is made in the default list, so it is hidden too if that list is unticked; the default list carries a line saying approved tasks go there, in orange while it is unticked. Unticked lists you had from before this setting existed stay unticked. Footer: what unticking does, and that lists made later start ticked. |
| Focus List | "Keep a Focus list in Reminders" toggle, on by default. While on, every reminder in Focus sits in a Reminders list called Focus (made on first use, in the same account as your default list) and goes back to its own list when it leaves Focus, is snoozed, or is checked off; one whose own list is gone, or that you made in the Focus list, goes to your default list. Putting a reminder in the Focus list yourself, on your phone or in Reminders, moves it to Focus here (it gets a Priority, and a snooze ends); taking one out moves it to Later (its Priority is cleared), unless its due date keeps it in Focus, in which case it goes back. Only reminders from ticked lists move in (see Lists). Unticking a list sends its reminders in the Focus list back to it with their Priority kept; ticking one moves its Focus reminders in. Taking a reminder out of the Focus list into an unticked list takes it out for good: no Priority change, and it doesn't come back even when its due date is near. Messages Suggestions are never in it. Order within the list is Reminders' own, not the Ranked List's. Nothing moves while FirstFocus isn't running. Turning it off moves everything back to its own list and leaves the empty Focus list for you to keep or delete; turning it on again uses the same list. Footer: what the list holds, what moving a reminder in or out of it does. |
| Startup | "Open FirstFocus at login" toggle, turned on once the first time this version runs; after that your choice, here or in System Settings > General > Login Items, stands. Shows what macOS actually has each time Advanced opens. If macOS refuses the change, a line under the toggle says so. |
| Rules | "Add a Rule" field + Add (disabled at 5). Below it, the Rules as a list ("No Rules yet." when empty); on hover each shows a pencil (edit in place: Save / ⏎, Cancel / Esc) and a trash (delete). Proposed Rules: field, Approve, Reject. Propose Rules (enabled after 5 new "Not for me" Corrections; reason shown otherwise). Footer: n of 5 used. |
| Re-extraction | Look back stepper (1 hour to 30 days). Minimum time between runs stepper (0–48 hours). |
| Screening | Screen with Jev toggle, with a one-line disclosure ("Sends message text to TypeSafe AI, with senders anonymized.") and a Help (?) popover holding the full wording; both always visible. While the toggle is on: API key row (Add Key… / Change Key… sheet: key field, Remove Key, Cancel, Save; "Screening stays off until a key is saved." without one). Mode: Shadow / Live (Live disabled until a cutoff is set), one-line summary + Help (?) popover. Cutoff value + Tune Cutoff… (disabled with no key saved, with "Add a key to tune the cutoff." under it; sheet: score histogram split by "Model found work" / "Nothing to do", drag to move the candidate cutoff, readout of what it would Screen, Set Cutoff to x.xx, Done). |
| Quick Capture | Shortcut picker: ⌥Space (default), ⌃⌥Space, ⇧⌘Space. Applies at once. |
| Muted Chats | Every Chat muted from History, by History's name for it (group name, or the other person), alphabetical; "Chat not recorded" when no History row is left. Hovering a name shows the newest message History has for that Chat (group Chats prefixed with who wrote it), or "No recent messages" when it has none. Unmute button on each row: the Chat leaves the list, and History drops its Muted badge and "Earlier" pin. Same effect as Unmute Thread in History. "No muted chats." when there are none. Re-reads each time Advanced opens. Footer: Chats are muted from History; unmuting affects new messages only. |
| Filtered SMS | "Ignore filtered SMS" toggle, on by default. On: texts Messages sorted under Transactions or Promotions (a sender ending "(smsft)" or "(smsfp)") never reach extraction, and the line under the toggle says so; off: they are extracted like any other. Footer: Affects new messages only. |
| Extraction Prompt | Edit Prompt… (sheet: editor, Copy into Editor for an outdated saved prompt, Cancel, Save & Reload ⌘⏎). Reset to Default (confirm). Warning when the saved prompt is outdated. |

## About

| Element | What it does |
|---|---|
| Version line | "FirstFocus 0.1 · built on llama.cpp and Qwen3". |
| Keyboard Shortcuts | Every FirstFocus shortcut, grouped: Anywhere (Quick Capture, showing the preset picked in Advanced) · Quick Capture panel (⏎, Esc) · Suggested Tasks Inbox (↑ ↓, ⏎ Approve, ⌫ or ⌦ Dismiss, Space preview, Esc closes the preview) · Main (New Reminder ⏎, Esc, Checked Off Today ⇧⌘C) · Zen Focus Mode and Minimal View (⇧⌘F, ⇧⌘M, Esc) · Menu bar (⌘R, ⇧⌘E, ⇧⌘L) · Advanced (Add a Rule or save an edited one ⏎, cancel editing Esc; Extraction Prompt ⌘⏎). Stock macOS keys are left out. Read-only. Groups sit in two columns of about equal height (a group never splits); stacked when the window is too narrow. |
| Storage: Database / Models | Path + Show in Finder. Sits left of Acknowledgments; stacked when the window is too narrow. |
| Acknowledgments | llama.cpp, llama.swift, Qwen3-4B-Instruct-2507, Qwen2.5-3B-Instruct, Llama 3.2 3B, with licenses. |

## Other windows and modes

| Element | What it does |
|---|---|
| Quick Capture panel (⌥Space by default, from anywhere; change it in Advanced → Quick Capture) | "What do you need to do?" field. ⏎ creates a reminder; Esc closes. A date phrase shows the same badge as the `+` field and is saved as the due date, cancelled the same way. Warns when Reminders access is missing. |
| Minimal View (⇧⌘M, View menu or toolbar) | Hides the toolbar and sidebar and shows Main (all Sections) at the current window size. Exit with Esc (unless an alert or the Suggestion preview is open), ⇧⌘M, or View → Minimal View. Restores the previous screen. |
| Zen Focus Mode | See the toolbar. Esc leaves it (unless an alert or the Suggestion preview is open); if Minimal View is also on, Esc leaves Zen first. |
| Menu bar: FirstFocus | About FirstFocus (opens the About screen, leaving Zen and Minimal View) · Check for Updates… (Sparkle's window: checking, then either "You're up to date" or the new version with its release notes and Install Update · Skip This Version · Remind Me Later; installing ends with Install and Relaunch) · Hide ⌘H · Hide Others ⌥⌘H · Show All · Quit ⌘Q. |
| Menu bar: File | Re-run Extraction ⌘R (disabled while loading, during backfill, while an intake pass or re-extraction runs, inside the minimum wait, without Full Disk Access, or with no model loaded). While a Messages pass runs, the item names it: "Checking Messages…" for an automatic pass, "Re-extracting…" for a re-extraction, "Checking a Batch…" for This was work · Export History as Markdown… ⇧⌘E · Export History as CSV… (both export the Batches History currently lists). |
| Menu bar: Edit | Undo ⌘Z · Redo ⇧⌘Z · Cut · Copy · Paste · Select All. ⌘Z presses the Undo bar's Undo instead while it shows one and no text field is being edited. |
| Menu bar: View | Zen Focus Mode ⇧⌘F · Minimal View ⇧⌘M · Checked Off Today ⇧⌘C (opens or closes the Checked Off sheet; disabled with nothing checked off today or in Zen, unless the sheet is open) · Show Unfiltered History Log ⇧⌘L (the Zen, Minimal View and History log items have a checkmark when on) · Enter Full Screen (added by macOS). |
