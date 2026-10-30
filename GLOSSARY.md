# FirstFocus

FirstFocus turns reminders and Messages conversations into a focused task list. This language names the feedback and Focus movement decisions shared by the app and its tests.

## Feedback

**Batch**:
A group of messages judged together for work the user needs to do.

**Suggestion**:
A task inferred from Messages that the user has not yet approved as a reminder.

**Correction**:
The user's judgment that a Batch was misclassified or that its proposed task was wrong. It supplies an example for future judgments.

**Batch feedback**:
The user's judgment of a Batch together with the changes to its Suggestions that express that judgment.

**Not for me**:
Feedback that a Batch's inferred work is not for the user, combining a false-positive Correction with dismissal of that Batch's open Suggestions.

**Feedback ownership**:
The association between a feedback action and the changes it made. Undo reverses those changes only while a later action has not superseded them.

## Focus movement

**Focus list**:
The list in Reminders that FirstFocus keeps aligned with its current Focus tasks.

**Home list**:
The list a reminder returns to after FirstFocus temporarily places it in the Focus list. A later manual move to another list establishes the user's newer choice of home.
_Avoid_: original list, when referring to the home after a newer manual move

**Focus placement**:
The association between a reminder managed by the Focus list and its home. It distinguishes FirstFocus's movement from the user's manual movement.
