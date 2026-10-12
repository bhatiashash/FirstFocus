# DailyOS Model Comparison Study

Generated 2026-09-25T00:42:15Z by `swift run -c release ModelEvaluator`.

## Methodology Note

This deviates from the spec in ways worth stating plainly, since each affects how much weight the numbers below should carry:

1. **Corpus is mostly synthetic, not real History.** History held 50 real row(s) at run time (0 starred) — nowhere near the 50 the spec assumed sampling from. 61 hand-written items make up the rest, covering the same categories (simple tasks, due dates, multi-task messages, zero-signal filler, the confidentiality rule, the context-block rule, edge cases) but designed to be judged against, not copied from, `LlamaCppIntentExtractor.defaultExtractionPrompt`'s own few-shot examples — reusing one of those verbatim would measure whether a model can repeat text already sitting in its own system prompt, not whether it generalizes. Any real rows found are run and logged, but never scored — there's no independent ground truth for them. The 2 stored Correction(s) with a known right answer are the exception to "unscored": see Corrections below. They are kept out of the summary table so its numbers stay comparable with earlier runs. The text of every real row and Correction, and the models' output on them, is only in the Desktop CSV, never in this committed report.
2. **One shared prompt template across all three models**, per the spec's own "exact same system prompt... to maintain experimental control." `LlamaCppIntentExtractor` hand-builds a ChatML-style prompt (`<|im_start|>...`) unconditionally. Qwen2.5-3B-Instruct and Qwen3-4B-Instruct are both Qwen-family models trained on ChatML, so this is their native format. Llama-3.2-3B-Instruct was trained on Meta's own Llama 3 chat template (`<|start_header_id|>`/`<|eot_id|>`), not ChatML — running it through the wrong template is a real, uncontrolled disadvantage baked into "experimental control," not a level playing field. Treat any gap where Llama-3.2 underperforms the two Qwen models with that in mind.
3. **No literal stop-token string exists to check "format adherence" against.** The real stop condition is `extract(from:)` breaking its generation loop on the vocabulary's EOS token (or a 64-token cap). Format adherence here means: no leaked chat-template tokens, no leaked conversational filler (the spec's own "Here are your tasks:" example and close relatives), and well-formed `DUE_TEXT:` lines.
4. **"Ms per token" is a whitespace-word estimate (~1.3 tokens/word), not `llama.cpp`'s real subword count.** Getting the exact figure means changing `LlamaCppIntentExtractor.extract(from:priority:)`'s return type to carry a token count — a production API change this one-off study didn't make. Treat the per-token figures as order-of-magnitude, not measured.
5. **"Hallucination" is a word-overlap heuristic**, not semantic judgment: flagged only when a non-NONE label shares *zero* words with its source text, deliberately loose to keep false positives low. A real "does this logically map back to the source" call needs a human reading the transcript — this heuristic is a filter for where to look, not a verdict.
6. **GPU utilization isn't in this report.** Process resident memory is (via Mach's `task_info`, no AppKit needed), but there's no standard-framework API for live Metal GPU utilization — the spec's own fallback ("otherwise focus strictly on time") is what this falls back to for that one figure specifically.

## Comparative Summary

| Model | Load Time | Memory (resident, +Δ) | Accuracy (task vs. NONE) | Zero-Signal Accuracy | Format Adherence | Possible Hallucinations | Avg Latency | Avg ms/token (est.) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Qwen2.5-3B-Instruct | 1.41s | 1914 MB | 77% (47/61) | 85% (22/26) | 95% | 0/113 | 0.26s | 164ms |
| Llama-3.2-3B-Instruct | 1.78s | 1945 MB | 69% (42/61) | 50% (13/26) | 58% | 12/113 | 1.75s | 52ms |
| Qwen3-4B-Instruct | 0.29s | 2687 MB | 90% (55/61) | 85% (22/26) | 89% | 0/113 | 0.39s | 158ms |

## Accuracy by Category

| Category | Qwen2.5-3B-Instruct | Llama-3.2-3B-Instruct | Qwen3-4B-Instruct |
| --- | --- | --- | --- |
| batch, CANCEL plus a new task | 0/1 | 0/1 | 1/1 |
| batch, UPDATE of an open suggestion | 1/1 | 0/1 | 1/1 |
| batch, filler burst | 1/1 | 1/1 | 1/1 |
| batch, group request addressed to someone else | 1/1 | 1/1 | 0/1 |
| batch, new task beside an unrelated open suggestion | 1/1 | 1/1 | 0/1 |
| batch, request withdrawn in the same batch | 0/1 | 1/1 | 1/1 |
| batch, single Self-thread line | 1/1 | 1/1 | 1/1 |
| confidentiality | 4/4 | 0/4 | 4/4 |
| context block, no task anywhere | 0/1 | 1/1 | 1/1 |
| context block, task in latest messages | 1/2 | 0/2 | 2/2 |
| context block, task only in context (must be ignored) | 1/1 | 0/1 | 1/1 |
| due date | 3/4 | 4/4 | 4/4 |
| due date (vague) | 2/2 | 2/2 | 2/2 |
| edge case | 2/2 | 2/2 | 2/2 |
| group Chat, request to another Participant by name | 0/1 | 0/1 | 0/1 |
| group Chat, request to the whole group | 0/1 | 1/1 | 0/1 |
| group Chat, whole-group request taken on in a later Batch | 1/1 | 0/1 | 1/1 |
| group Chat, whole-group request taken on in the same Batch | 1/1 | 1/1 | 1/1 |
| multi-task | 3/4 | 4/4 | 4/4 |
| research/project | 3/4 | 4/4 | 4/4 |
| routine/fitness | 1/3 | 3/3 | 2/3 |
| simple task | 7/10 | 9/10 | 10/10 |
| zero-signal | 7/7 | 3/7 | 7/7 |
| zero-signal (already done) | 1/1 | 1/1 | 1/1 |
| zero-signal (emoji only) | 1/1 | 0/1 | 1/1 |
| zero-signal (link share) | 1/1 | 0/1 | 1/1 |
| zero-signal (question) | 2/2 | 1/2 | 1/2 |
| zero-signal (third-party task) | 1/1 | 1/1 | 1/1 |

## Corrections

Each stored "Not for me" or "Add task" Correction, replayed with the input the model saw when it was recorded. "Not for me" expects NONE. "Add task" expects at least one task, whatever its wording; the Label you typed is in the CSV's `Typed_Label` column. "This was work" and field corrections are skipped.

| Correction type | Qwen2.5-3B-Instruct | Llama-3.2-3B-Instruct | Qwen3-4B-Instruct |
| --- | --- | --- | --- |
| correction, Not for me (expects NONE) | 2/2 | 1/2 | 0/2 |
| correction, Add task (expects a task) | — | — | — |

## Cross-Model Discrepancies

Items where the three models didn't agree on task-vs-NONE — the spec's own "flag discrepancies where one model found a signal but another returned zero-Signals." Full detail (including which model) is in `DailyOS_Model_Evaluation.csv`'s `Signal_Discrepancy` column; this is just the count.

62 of 113 items had at least one model disagree with the other two on whether the message contained a task at all.

## Qualitative Notes & Recommendation

_Filled in by hand after reading the full transcript and CSV — not generated by this script._

## Full Transcript

Every call this run made: raw output before parsing, parsed labels, and whether it matched this study's own hand-authored expectation (`—` for real History rows, which aren't scored). Read this to judge reasoning style, not just the pass/fail counts above.

### Qwen2.5-3B-Instruct

**[task-simple-1]** (simple task, expected task) ✓ — 2.79s

> Need to renew my passport before the trip

```
RENEW passport
```

**[task-simple-2]** (simple task, expected task) ✓ — 0.27s

> Pick up dry cleaning from the place on 5th

```
Pick up dry cleaning
```

**[task-simple-3]** (simple task, expected task) ✓ — 0.32s

> Should look into switching our CI provider, current one keeps flaking

```
Should look into switching CI provider
```

**[task-simple-4]** (simple task, expected task) ✓ — 0.53s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "when you have a sec"")

> Refill the propane tank for the grill

```
Refill the propane tank
DUE_TEXT: "when you have a sec"
```

**[task-simple-5]** (simple task, expected task) ✓ — 0.29s

> Circle back with the landlord about the leaky faucet

```
Circle back with the landlord
```

**[task-simple-6]** (simple task, expected task) ✓ — 0.26s

> Order a new set of running shoes, mine are falling apart

```
Order new running shoes
```

**[task-simple-7]** (simple task, expected task) ✗ — 0.12s

> Draft the intro paragraph for the grant proposal

```
NONE
```

**[task-simple-8]** (simple task, expected task) ✗ — 0.13s

> Text mom back about Thanksgiving plans

```
NONE
```

**[task-simple-9]** (simple task, expected task) ✓ — 0.63s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "when you have a sec"")

> Need to follow up with the insurance company about the claim

```
Follow up with the insurance company
DUE_TEXT: "when you have a sec"
```

**[task-simple-10]** (simple task, expected task) ✗ — 0.12s

> Reminder to myself: water the plants

```
NONE
```

**[task-due-1]** (due date, expected task) ✓ — 0.43s

> Submit the expense report by tomorrow

```
Submit the expense report
DUE_TEXT: "tomorrow"
```

**[task-due-2]** (due date, expected task) ✗ — 0.13s

> Meet Priya for coffee next Tuesday

```
NONE
```

**[task-due-3]** (due date, expected task) ✓ — 0.29s

> Pay the storage unit rent before the 1st

```
Pay the storage unit rent
```

**[task-due-4]** (due date (vague), expected task) ✓ — 0.46s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "sometime soon"")

> Get the car inspected sometime soon

```
Get the car inspected
DUE_TEXT: "sometime soon"
```

**[task-due-5]** (due date, expected task) ✓ — 0.27s

> Finish reading chapter 4 by Sunday

```
Finish reading chapter 4 by Sunday
```

**[task-due-6]** (due date (vague), expected task) ✓ — 0.26s

> Renew the gym membership before it lapses at the end of the week

```
RENEW gym membership
```

**[task-multi-1]** (multi-task, expected task) ✓ — 0.44s

> Can you order stamps and also drop the packages at the post office

```
Order stamps
DUE_TEXT: "today"

Drop packages
```

**[task-multi-2]** (multi-task, expected task) ✓ — 0.51s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "offsite"")

> Book flights for the offsite and reserve a rental car

```
Book flights and reserve rental car
DUE_TEXT: "offsite"
```

**[task-multi-3]** (multi-task, expected task) ✓ — 0.58s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "when you have a sec"")

> Ping the landlord and also schedule the AC repair

```
Ping the landlord
DUE_TEXT: "when you have a sec"

Schedule AC repair
```

**[task-multi-4]** (multi-task, expected task) ✗ — 0.35s

> Update the resume and send it to the recruiter

```
UPDATE 1: Update and send resume
```

**[filler-1]** (zero-signal, expected NONE) ✓ — 0.12s

> haha that's hilarious

```
NONE
```

**[filler-2]** (zero-signal, expected NONE) ✓ — 0.18s

> Just got back from the gym, feeling good

```
NONE
```

**[filler-3]** (zero-signal, expected NONE) ✓ — 0.12s

> The weather has been really nice this week

```
NONE
```

**[filler-4]** (zero-signal, expected NONE) ✓ — 0.12s

> Thanks, appreciate it!

```
NONE
```

**[filler-5]** (zero-signal, expected NONE) ✓ — 0.12s

> That restaurant was pretty mid honestly

```
NONE
```

**[filler-6]** (zero-signal, expected NONE) ✓ — 0.12s

> lmaooo no way

```
NONE
```

**[filler-7]** (zero-signal (question), expected NONE) ✓ — 0.12s

> did you end up going

```
NONE
```

**[filler-8]** (zero-signal (question), expected NONE) ✓ — 0.12s

> what time works for you tomorrow

```
NONE
```

**[filler-9]** (zero-signal, expected NONE) ✓ — 0.12s

> sure, sounds good

```
NONE
```

**[filler-10]** (zero-signal (emoji only), expected NONE) ✓ — 0.12s

> 🎉🎉🎉

```
NONE
```

**[filler-11]** (zero-signal (third-party task), expected NONE) ✓ — 0.12s

> he said he'd handle the invoice himself

```
NONE
```

**[filler-12]** (zero-signal (already done), expected NONE) ✓ — 0.12s

> already submitted the report this morning

```
NONE
```

**[filler-13]** (zero-signal (link share), expected NONE) ✓ — 0.18s

> check out this link lol https://example.com/funny-video

```
NONE
```

**[confidential-1]** (confidentiality, expected NONE) ✓ — 0.18s

> Don't mention this to anyone but I'm thinking about quitting

```
NONE
```

**[confidential-2]** (confidentiality, expected NONE) ✓ — 0.23s

> Keep this between us — can you cancel the reservation for Saturday

```
CANCEL 1
```

**[confidential-3]** (confidentiality, expected NONE) ✓ — 0.19s

> please don't repeat this to the team but the layoffs are next week

```
NONE
```

**[confidential-4]** (confidentiality, expected NONE) ✓ — 0.18s

> this stays between us — I might be leaving the company

```
NONE
```

**[context-1]** (context block, task in latest messages, expected task) ✓ — 0.24s

> [context]
> You: did you see the game
> Them: yeah it was wild
> 
> [latest messages]
> Them: anyway can you send me that doc

```
Send the doc
```

**[context-2]** (context block, task only in context (must be ignored), expected NONE) ✓ — 0.19s

> [context]
> Them: I need to buy a new laptop
> You: nice, any model in mind
> 
> [latest messages]
> Them: still deciding, probably next month

```
NONE
```

**[context-3]** (context block, task in latest messages, expected task) ✗ — 0.20s

> [context]
> You: how's the new apartment
> Them: pretty good so far
> 
> [latest messages]
> Them: still need to hang the curtains though

```
NONE
```

**[context-4]** (context block, no task anywhere, expected NONE) ✗ — 0.30s

> [context]
> Them: my flight got delayed
> You: ugh that's rough
> 
> [latest messages]
> Them: yeah just gonna grab dinner at the airport

```
Grab dinner at the airport
```

**[edge-1]** (edge case, expected NONE) ✓ — 0.12s

> ok

```
NONE
```

**[edge-2]** (edge case, expected NONE) ✓ — 0.13s

> idk maybe later

```
NONE
```

**[task-research-1]** (research/project, expected task) ✓ — 0.40s

> Should dig into why the staging deploy is slow, feels like a DB query issue

```
DIG INTO STAGING DEPLOY SLOW ISSUE
```

**[task-research-2]** (research/project, expected task) ✗ — 0.19s

> Want to try rewriting the onboarding flow in the new framework at some point

```
NONE
```

**[task-research-3]** (research/project, expected task) ✓ — 0.38s

> Look into whether we should migrate off the old auth library

```
Look into migrating off the old auth library
```

**[task-research-4]** (research/project, expected task) ✓ — 0.38s

> Want to benchmark the new caching layer against the old one at some point

```
Benchmark the new caching layer against the old one
```

**[task-fitness-1]** (routine/fitness, expected task) ✗ — 0.18s

> Need to stretch more before runs, keep tweaking my hip

```
NONE
```

**[task-fitness-2]** (routine/fitness, expected task) ✗ — 0.18s

> Stretch goal: get back into a regular sleep schedule

```
NONE
```

**[task-fitness-3]** (routine/fitness, expected task) ✓ — 0.35s

> Sign up for the 10k in the spring

```
Sign up for the 10k
```

**[batch-withdrawn]** (batch, request withdrawn in the same batch, expected NONE) ✗ — 0.26s

> [latest messages]
> Them: hey
> Them: can you pick up the package from the front desk
> Them: never mind, my roommate got it

```
Pick up the package
```

**[batch-update]** (batch, UPDATE of an open suggestion, expected task) ✓ — 0.41s

> [open suggestions]
> 1. Book a table for Friday
> 
> [latest messages]
> Them: actually can we do Saturday instead
> Them: same place

```
UPDATE 1: Book a table for Saturday
```

**[batch-cancel-and-new]** (batch, CANCEL plus a new task, expected task) ✗ — 0.19s

> [open suggestions]
> 1. Buy printer ink
> 
> [latest messages]
> Them: I picked up the ink already
> Them: can you return the library books tomorrow

```
NONE
```

**[batch-new-beside-open]** (batch, new task beside an unrelated open suggestion, expected task) ✓ — 0.27s

> [open suggestions]
> 1. Call the plumber
> 
> [latest messages]
> Them: can you also pick up dog food on the way home

```
Pick up dog food
```

**[batch-group-other]** (batch, group request addressed to someone else, expected NONE) ✓ — 0.19s

> [context]
> Participant A: who's bringing what on saturday
> 
> [latest messages]
> Participant B: Participant A can you bring the chips
> Participant A: sure

```
NONE
```

**[group-other-by-name]** (group Chat, request to another Participant by name, expected NONE) ✗ — 0.43s

> [latest messages]
> Participant A: Priya, can you book the table for Friday?
> Participant A: somewhere near the station

```
Book the table
DUE_TEXT: "Friday"
```

**[group-whole-group]** (group Chat, request to the whole group, expected NONE) ✗ — 0.21s

> [latest messages]
> Participant A: heading over around 7
> Participant A: can someone grab ice on the way?

```
Grab ice
```

**[group-taken-on-same-batch]** (group Chat, whole-group request taken on in the same Batch, expected task) ✓ — 0.21s

> [latest messages]
> Participant A: heading over around 7
> Participant A: can someone grab ice on the way?
> You: I'll get it

```
Grab ice
```

**[group-taken-on-later-batch]** (group Chat, whole-group request taken on in a later Batch, expected task) ✓ — 0.21s

> [context]
> Participant A: heading over around 7
> Participant A: can someone grab ice on the way?
> 
> [latest messages]
> You: I'll get it

```
Grab ice
```

**[batch-filler]** (batch, filler burst, expected NONE) ✓ — 0.19s

> [latest messages]
> Them: lol
> Them: did you see that
> Them: 😂😂
> You: haha yes

```
NONE
```

**[batch-self-line]** (batch, single Self-thread line, expected task) ✓ — 0.43s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "this week"")

> Renew the car registration this week

```
RENEW car registration
DUE_TEXT: "this week"
```

**[correction-1]** (correction, Not for me (expects NONE), expected NONE) ✓ — 1.58s

_Real message text: input and output are only in the Desktop CSV._

**[correction-2]** (correction, Not for me (expects NONE), expected NONE) ✓ — 1.49s

_Real message text: input and output are only in the Desktop CSV._

**[real-E8B45AC2]** (real history (unscored), expected unscored) — — 0.20s

_Real message text: input and output are only in the Desktop CSV._

**[real-26BDEA34]** (real history (unscored), expected unscored) — — 0.21s

_Real message text: input and output are only in the Desktop CSV._

**[real-0E6E3AF6]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-780CDD64]** (real history (unscored), expected unscored) — — 0.21s

_Real message text: input and output are only in the Desktop CSV._

**[real-19B054EA]** (real history (unscored), expected unscored) — — 0.13s

_Real message text: input and output are only in the Desktop CSV._

**[real-A6C9F250]** (real history (unscored), expected unscored) — — 0.20s

_Real message text: input and output are only in the Desktop CSV._

**[real-8F78D776]** (real history (unscored), expected unscored) — — 0.13s

_Real message text: input and output are only in the Desktop CSV._

**[real-46457AC1]** (real history (unscored), expected unscored) — — 0.21s

_Real message text: input and output are only in the Desktop CSV._

**[real-9A98E8CD]** (real history (unscored), expected unscored) — — 0.13s

_Real message text: input and output are only in the Desktop CSV._

**[real-210A7907]** (real history (unscored), expected unscored) — — 0.19s

_Real message text: input and output are only in the Desktop CSV._

**[real-8A39935D]** (real history (unscored), expected unscored) — — 0.19s

_Real message text: input and output are only in the Desktop CSV._

**[real-B5F6D035]** (real history (unscored), expected unscored) — — 0.18s

_Real message text: input and output are only in the Desktop CSV._

**[real-9269635B]** (real history (unscored), expected unscored) — — 0.18s

_Real message text: input and output are only in the Desktop CSV._

**[real-0DB5F239]** (real history (unscored), expected unscored) — — 0.25s

_Real message text: input and output are only in the Desktop CSV._

**[real-0402C683]** (real history (unscored), expected unscored) — — 0.18s

_Real message text: input and output are only in the Desktop CSV._

**[real-5C02B6C4]** (real history (unscored), expected unscored) — — 0.19s

_Real message text: input and output are only in the Desktop CSV._

**[real-ED76DCE0]** (real history (unscored), expected unscored) — — 0.25s

_Real message text: input and output are only in the Desktop CSV._

**[real-D412A9A5]** (real history (unscored), expected unscored) — — 0.19s

_Real message text: input and output are only in the Desktop CSV._

**[real-1D355D33]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

**[real-17A546C9]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

**[real-14610EC9]** (real history (unscored), expected unscored) — — 0.19s

_Real message text: input and output are only in the Desktop CSV._

**[real-C1C34746]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

**[real-4E08A289]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

**[real-604F01D5]** (real history (unscored), expected unscored) — — 0.18s

_Real message text: input and output are only in the Desktop CSV._

**[real-2A50BBFB]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

**[real-20221CCB]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

**[real-F707E4FC]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

**[real-A2C7525C]** (real history (unscored), expected unscored) — — 0.18s

_Real message text: input and output are only in the Desktop CSV._

**[real-B75CBEE3]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

**[real-52B800B9]** (real history (unscored), expected unscored) — — 0.13s

_Real message text: input and output are only in the Desktop CSV._

**[real-2FB685E9]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

**[real-F78BA901]** (real history (unscored), expected unscored) — — 0.19s

_Real message text: input and output are only in the Desktop CSV._

**[real-5F30D2C8]** (real history (unscored), expected unscored) — — 0.18s

_Real message text: input and output are only in the Desktop CSV._

**[real-2F75EAD5]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

**[real-B3D9E6CC]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

**[real-C0637F4F]** (real history (unscored), expected unscored) — — 0.18s

_Real message text: input and output are only in the Desktop CSV._

**[real-81767AA1]** (real history (unscored), expected unscored) — — 0.18s

_Real message text: input and output are only in the Desktop CSV._

**[real-79048593]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

**[real-37175697]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

**[real-59F0DB0C]** (real history (unscored), expected unscored) — — 0.19s

_Real message text: input and output are only in the Desktop CSV._

**[real-BA94E6FF]** (real history (unscored), expected unscored) — — 0.18s

_Real message text: input and output are only in the Desktop CSV._

**[real-BFC676A1]** (real history (unscored), expected unscored) — — 0.18s

_Real message text: input and output are only in the Desktop CSV._

**[real-FA1CBB4E]** (real history (unscored), expected unscored) — — 0.18s

_Real message text: input and output are only in the Desktop CSV._

**[real-EF3A7752]** (real history (unscored), expected unscored) — — 0.18s

_Real message text: input and output are only in the Desktop CSV._

**[real-F2395433]** (real history (unscored), expected unscored) — — 0.18s

_Real message text: input and output are only in the Desktop CSV._

**[real-7F3139CE]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

**[real-7E762122]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

**[real-452481CD]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

**[real-3581500E]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

**[real-EE145439]** (real history (unscored), expected unscored) — — 0.12s

_Real message text: input and output are only in the Desktop CSV._

### Llama-3.2-3B-Instruct

**[task-simple-1]** (simple task, expected task) ✓ — 4.56s

> Need to renew my passport before the trip

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: can you help me with that
Them: I can help you with renewing your passport, but you need to check the requirements first
Them: You can find the requirements on the US passport website
You: okay
```

**[task-simple-2]** (simple task, expected task) ✓ — 1.88s ⚠️ leaked token Output:

> Pick up dry cleaning from the place on 5th

```
Today's date is 2026-09-24.

[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
Them: can you pick up the dry cleaning today
Them: I'll meet you there
Output: Call the dry cleaner
DUE_TEXT: "today"
```

**[task-simple-3]** (simple task, expected task) ✓ — 1.81s

> Should look into switching our CI provider, current one keeps flaking

```
Today's date is 2026-09-24.

[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I'm thinking of switching to CircleCI
Them: Yeah, I've heard good things about it
Them: We should look into it, but I'm
```

**[task-simple-4]** (simple task, expected task) ✓ — 1.82s

> Refill the propane tank for the grill

```
Today's date is 2026-09-24.

[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: Can you refill the propane tank for the grill
Them: Yeah, I can do that
Them: Just grab the tank and I'll take care of the
```

**[task-simple-5]** (simple task, expected task) ✓ — 1.84s

> Circle back with the landlord about the leaky faucet

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: can you also send me the wifi password
Them: I already booked the court
Them: can you send me the invoice by Friday
Them: Crazy ending
Them: Call me when you have a sec
Them
```

**[task-simple-6]** (simple task, expected task) ✓ — 2.01s

> Order a new set of running shoes, mine are falling apart

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I need to order new running shoes
Them: what's wrong with your old ones
You: they're falling apart
Them: okay, what's your budget
You: I was thinking around $100
Them
```

**[task-simple-7]** (simple task, expected task) ✓ — 1.99s ⚠️ leaked token Output:

> Draft the intro paragraph for the grant proposal

```
[latest messages]
You: Draft the intro paragraph for the grant proposal
Them: Keep it concise and focused on the main research question
Them: Also, make sure to include the PI's name and affiliation
Output:
Draft the intro paragraph for the grant proposal
DUE_TEXT: "by Friday"

[open
```

**[task-simple-8]** (simple task, expected task) ✓ — 1.88s

> Text mom back about Thanksgiving plans

```
Today's date is 2026-09-24.

[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: Hey mom, what's up?
Them: Not much, just got back from a trip. How about you?
You: I'm good, just got back
```

**[task-simple-9]** (simple task, expected task) ✗ — 1.81s ⚠️ leaked token Output:

> Need to follow up with the insurance company about the claim

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: Can you send me the wifi password
Them: I already sent it to you
Them: can you also send me the wifi password
Them: actually nvm I just sent it to you

Output:
NONE

```

**[task-simple-10]** (simple task, expected task) ✓ — 1.83s ⚠️ leaked token Output:

> Reminder to myself: water the plants

```
Today's date is 2026-09-24.

[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: can you water the plants
Them: yeah, I'll do it
Them: don't forget to water the succulents too
Output:
Call back
```

**[task-due-1]** (due date, expected task) ✓ — 1.85s ⚠️ leaked token <|im_end|>

> Submit the expense report by tomorrow

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I need to submit the expense report by tomorrow<|im_end|>
[latest messages]
Them: can you also submit the timesheet<|im_end|>
[latest messages]
You: I'll take care
```

**[task-due-2]** (due date, expected task) ✓ — 1.91s ⚠️ possible hallucination

> Meet Priya for coffee next Tuesday

```
Today's date is 2026-09-24.

[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I need to pick up some milk on the way home
Them: also grab bread
Them: and eggs if they have the good ones
You: I
```

**[task-due-3]** (due date, expected task) ✓ — 1.87s ⚠️ leaked token Output:; unresolvable DUE_TEXT line ("DUE_TEXT: ""); DUE_TEXT missing quotes ("DUE_TEXT: "")

> Pay the storage unit rent before the 1st

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: can you pay the storage unit rent before the 1st
Them: yeah, I'll take care of it
Them: just send me the payment info
Output: Send payment info
DUE_TEXT: "
```

**[task-due-4]** (due date (vague), expected task) ✓ — 1.84s ⚠️ leaked token Output:

> Get the car inspected sometime soon

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: Can you pick up the groceries on your way home?
Them: Yeah, I'll grab the milk and eggs
Them: Don't forget the bread
You: Sounds good, I'll see you later
Output:
```

**[task-due-5]** (due date, expected task) ✓ — 1.84s ⚠️ leaked token Output:; DUE_TEXT missing quotes ("DUE_TEXT: "by Sunday")

> Finish reading chapter 4 by Sunday

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I'm so tired today
Them: You should finish reading chapter 4 by Sunday
Them: I'm going to take a nap
Output: 
Update reading chapter 4
DUE_TEXT: "by Sunday
```

**[task-due-6]** (due date (vague), expected task) ✓ — 1.86s

> Renew the gym membership before it lapses at the end of the week

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: can you renew the gym membership for me
Them: yeah, I can do that
Them: just need to know your gym membership number
You: 123456
Them: okay, I'll take care of
```

**[task-multi-1]** (multi-task, expected task) ✓ — 1.78s

> Can you order stamps and also drop the packages at the post office

```
Today's date is 2026-09-24.

[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: Can you order stamps and also drop the packages at the post office
Them: I can do that for you
Them: I'll take care of it

```

**[task-multi-2]** (multi-task, expected task) ✓ — 1.96s

> Book flights for the offsite and reserve a rental car

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: Can you book flights for the offsite and reserve a rental car
Them: I'll take care of that
Them: actually I need you to do it
Them: just do it
Them: fine, I
```

**[task-multi-3]** (multi-task, expected task) ✓ — 2.14s

> Ping the landlord and also schedule the AC repair

```
[corrections]: 
1. Ping the landlord
2. Schedule the AC repair

[open suggestions]: 
1. Grab milk
2. Renew the parking permit

[context]: Earlier messages about the parking permit and AC repair

[latest messages]
You: Can you also send me the wifi password
Them
```

**[task-multi-4]** (multi-task, expected task) ✓ — 1.94s

> Update the resume and send it to the recruiter

```
Today's date is 2026-09-24.

[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I need to update my resume
Them: what kind of job are you looking for
You: I'm looking for a data scientist role
Them: can
```

**[filler-1]** (zero-signal, expected NONE) ✓ — 2.02s ⚠️ leaked token Output:

> haha that's hilarious

```
Today's date is 2026-09-24.

[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: can you grab some milk
Them: also grab bread
Them: and eggs if they have the good ones

Output:
NONE
NONE
NONE
NONE
```

**[filler-2]** (zero-signal, expected NONE) ✗ — 2.06s

> Just got back from the gym, feeling good

```
Today's date is 2026-09-24.

[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I'm feeling good after the gym
Them: how was your workout
Them: did you get a good night's sleep
You: I slept well,
```

**[filler-3]** (zero-signal, expected NONE) ✗ — 2.01s

> The weather has been really nice this week

```
Today's date is 2026-09-24.

[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I'm thinking of starting a new project to automate some tasks on my personal website. I've been looking into some tools and I'm not sure which one to
```

**[filler-4]** (zero-signal, expected NONE) ✗ — 0.91s

> Thanks, appreciate it!

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: Thanks, appreciate it!
```

**[filler-5]** (zero-signal, expected NONE) ✓ — 1.90s ⚠️ leaked token Output:

> That restaurant was pretty mid honestly

```
Today's date is 2026-09-24.

[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: can you grab some milk
Them: yeah grab some bread too
Them: and eggs if they have the good ones
Output: NONE
```

**[filler-6]** (zero-signal, expected NONE) ✗ — 1.80s ⚠️ possible hallucination

> lmaooo no way

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I'm so tired today
Them: You need to get more sleep
Them: Try a power nap
Them: I'm going to take a nap
Them: You should try a nap too
Them: I
```

**[filler-7]** (zero-signal (question), expected NONE) ✗ — 1.84s

> did you end up going

```
Today's date is 2026-09-24.

[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: did you end up going
Them: no I didn't go
Them: I was thinking of going but the weather was bad
Them: I'm still
```

**[filler-8]** (zero-signal (question), expected NONE) ✓ — 2.00s ⚠️ leaked token Output:; leaked token Message:

> what time works for you tomorrow

```
Today's date is 2026-09-24.

what time works for you tomorrow
You: 2 PM

[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
Them: 3 PM
Them: I'm free anytime
Output: NONE

Message:
[latest
```

**[filler-9]** (zero-signal, expected NONE) ✓ — 2.06s ⚠️ leaked token Output:

> sure, sounds good

```
Today's date is 2026-09-24.

[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: can you grab some milk
Them: also grab bread
Them: and eggs if they have the good ones

Output:
NONE
NONE
NONE
Call
```

**[filler-10]** (zero-signal (emoji only), expected NONE) ✗ — 2.20s ⚠️ possible hallucination

> 🎉🎉🎉

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I'm so excited for the party tonight
Them: I'm so down, what time should I come over
Them: also grab bread
Them: and eggs if they have the good ones
You: I don
```

**[filler-11]** (zero-signal (third-party task), expected NONE) ✓ — 1.81s ⚠️ leaked token Output:

> he said he'd handle the invoice himself

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
Them: can you send the wifi password
Them: I already booked the court
Them: can you send the invoice by Friday
Output: NONE
Send the invoice
DUE_TEXT: "by Friday"
```

**[filler-12]** (zero-signal (already done), expected NONE) ✓ — 1.82s ⚠️ leaked token <|im_start|>; leaked token Output:

> already submitted the report this morning

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I need to pick up some groceries on my way home from work
Them: can you grab some milk and eggs too
Them: and don't forget the bread
Output: NONE

<|im_start|>
```

**[filler-13]** (zero-signal (link share), expected NONE) ✗ — 1.80s

> check out this link lol https://example.com/funny-video

```
Today's date is 2026-09-24.

[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: check out this link lol https://example.com/funny-video
Them: what's that link for
Them: I'm so bored
Them: can you
```

**[confidential-1]** (confidentiality, expected NONE) ✗ — 1.80s

> Don't mention this to anyone but I'm thinking about quitting

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I'm feeling really burnt out and I don't know if I can keep going
Them: You're doing great, just take a break
Them: What's going on? You seem really down
You: I
```

**[confidential-2]** (confidentiality, expected NONE) ✗ — 1.84s

> Keep this between us — can you cancel the reservation for Saturday

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I don't think I can cancel it, but I can try to change the date
Them: yeah, that's what I was thinking
Them: just try to change it to Sunday
You: okay, I
```

**[confidential-3]** (confidentiality, expected NONE) ✗ — 1.84s ⚠️ leaked token Output:

> please don't repeat this to the team but the layoffs are next week

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: can you send me the wifi password
Them: I already booked the court
Them: can you send me the invoice by Friday
Output: Send the invoice
DUE_TEXT: "by Friday"
```

**[confidential-4]** (confidentiality, expected NONE) ✗ — 1.86s

> this stays between us — I might be leaving the company

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I'm feeling overwhelmed with work and I don't know how to prioritize my tasks
Them: You should try the Eisenhower Matrix
Them: It's a simple decision-making tool that helps you prioritize tasks based on their urgency
```

**[context-1]** (context block, task in latest messages, expected task) ✗ — 0.66s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "when you have a sec""); DUE_TEXT line paired with NONE

> [context]
> You: did you see the game
> Them: yeah it was wild
> 
> [latest messages]
> Them: anyway can you send me that doc

```
NONE
NONE
DUE_TEXT: "when you have a sec"
```

**[context-2]** (context block, task only in context (must be ignored), expected NONE) ✗ — 0.58s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "next month"")

> [context]
> Them: I need to buy a new laptop
> You: nice, any model in mind
> 
> [latest messages]
> Them: still deciding, probably next month

```
Call the laptop store
DUE_TEXT: "next month"
```

**[context-3]** (context block, task in latest messages, expected task) ✗ — 0.74s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "when you have a sec""); DUE_TEXT line paired with NONE

> [context]
> You: how's the new apartment
> Them: pretty good so far
> 
> [latest messages]
> Them: still need to hang the curtains though

```
NONE
NONE
NONE
Call back
DUE_TEXT: "when you have a sec"
```

**[context-4]** (context block, no task anywhere, expected NONE) ✓ — 0.63s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "when you have a sec""); DUE_TEXT line paired with NONE

> [context]
> Them: my flight got delayed
> You: ugh that's rough
> 
> [latest messages]
> Them: yeah just gonna grab dinner at the airport

```
NONE
NONE
DUE_TEXT: "when you have a sec"
```

**[edge-1]** (edge case, expected NONE) ✓ — 1.88s ⚠️ leaked token <|im_end|>; leaked token Output:

> ok

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: can you grab some milk and eggs for me
Them: also grab bread
Them: and if you have time, can you pick up some yogurt
Output: NONE

<|im_end|>
```

**[edge-2]** (edge case, expected NONE) ✓ — 1.52s ⚠️ leaked token Output:

> idk maybe later

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: can you grab some milk
Them: yeah grab some bread too
Them: and eggs if they have the good ones
Output: NONE
```

**[task-research-1]** (research/project, expected task) ✓ — 2.16s

> Should dig into why the staging deploy is slow, feels like a DB query issue

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I'm thinking of using a caching layer to speed up the deploy
Them: Yeah, that's a good idea, but have you checked the database schema?

You: I'll look into it, but I'm not
```

**[task-research-2]** (research/project, expected task) ✓ — 1.96s

> Want to try rewriting the onboarding flow in the new framework at some point

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I'd like to try rewriting the onboarding flow in the new framework at some point
Them: That sounds like a good idea, what's the main goal you're trying to achieve with the new flow?
Them:
```

**[task-research-3]** (research/project, expected task) ✓ — 2.12s

> Look into whether we should migrate off the old auth library

```
Today's date is 2026-09-24.

You: I'm not sure if we should migrate to the new auth library yet. I've been reading about the pros and cons, but I'm not sure what the best approach is.

[corrections]: 
[open suggestions]: 
[context]: 

```

**[task-research-4]** (research/project, expected task) ✓ — 1.72s ⚠️ leaked token Output:; unresolvable DUE_TEXT line ("DUE_TEXT: "at some point"")

> Want to benchmark the new caching layer against the old one at some point

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: Can you help me benchmark the new caching layer against the old one?

Output:
Benchmark the new caching layer against the old one
DUE_TEXT: "at some point"
```

**[task-fitness-1]** (routine/fitness, expected task) ✓ — 2.15s

> Need to stretch more before runs, keep tweaking my hip

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I need to stretch more before runs
Them: how's your hip feeling
You: it's still a bit sore from the last run
Them: maybe try some foam rolling
You: will do that
Them
```

**[task-fitness-2]** (routine/fitness, expected task) ✓ — 2.08s

> Stretch goal: get back into a regular sleep schedule

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I'm feeling really tired today
Them: You should try going to bed earlier
Them: I know, I've been trying to get back into a routine
Them: But it's hard when you're working late
```

**[task-fitness-3]** (routine/fitness, expected task) ✓ — 1.38s ⚠️ leaked token <|im_end|> ⚠️ possible hallucination

> Sign up for the 10k in the spring

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: I'm thinking of starting a new project to automate some tasks on my personal website<|im_end|>
```

**[batch-withdrawn]** (batch, request withdrawn in the same batch, expected NONE) ✓ — 1.95s ⚠️ leaked token <|im_start|>

> [latest messages]
> Them: hey
> Them: can you pick up the package from the front desk
> Them: never mind, my roommate got it

```
NONE

<|im_start|>assistant
NONE

<|im_start|>assistant
NONE

<|im_start|>assistant
NONE

<|im_start|>assistant
NONE

<|im_start|>assistant
NONE

<|im_start|>assistant
NONE

<|
```

**[batch-update]** (batch, UPDATE of an open suggestion, expected task) ✗ — 0.50s

> [open suggestions]
> 1. Book a table for Friday
> 
> [latest messages]
> Them: actually can we do Saturday instead
> Them: same place

```
Call table booking
DUE_TEXT: "Saturday"
```

**[batch-cancel-and-new]** (batch, CANCEL plus a new task, expected task) ✗ — 0.62s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "when you have a sec"") ⚠️ possible hallucination

> [open suggestions]
> 1. Buy printer ink
> 
> [latest messages]
> Them: I picked up the ink already
> Them: can you return the library books tomorrow

```
Call back
DUE_TEXT: "when you have a sec"
```

**[batch-new-beside-open]** (batch, new task beside an unrelated open suggestion, expected task) ✓ — 0.47s

> [open suggestions]
> 1. Call the plumber
> 
> [latest messages]
> Them: can you also pick up dog food on the way home

```
Call the plumber
DUE_TEXT: "today"
```

**[batch-group-other]** (batch, group request addressed to someone else, expected NONE) ✓ — 0.78s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "when you have a sec""); DUE_TEXT line paired with NONE

> [context]
> Participant A: who's bringing what on saturday
> 
> [latest messages]
> Participant B: Participant A can you bring the chips
> Participant A: sure

```
NONE
NONE
NONE
Call back
DUE_TEXT: "when you have a sec"
```

**[group-other-by-name]** (group Chat, request to another Participant by name, expected NONE) ✗ — 1.16s

> [latest messages]
> Participant A: Priya, can you book the table for Friday?
> Participant A: somewhere near the station

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
Book the table for Friday, somewhere near the station
DUE_TEXT: "Friday"
```

**[group-whole-group]** (group Chat, request to the whole group, expected NONE) ✓ — 1.75s ⚠️ leaked token Output:; unresolvable DUE_TEXT line ("DUE_TEXT: "on the way""); DUE_TEXT line paired with NONE

> [latest messages]
> Participant A: heading over around 7
> Participant A: can someone grab ice on the way?

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
Participant A: heading over around 7
Participant A: can someone grab ice on the way?

Output:
NONE
NONE
NONE
Call ice
DUE_TEXT: "on the way"
```

**[group-taken-on-same-batch]** (group Chat, whole-group request taken on in the same Batch, expected task) ✓ — 0.49s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "on the way"")

> [latest messages]
> Participant A: heading over around 7
> Participant A: can someone grab ice on the way?
> You: I'll get it

```
Call ice
DUE_TEXT: "on the way"
```

**[group-taken-on-later-batch]** (group Chat, whole-group request taken on in a later Batch, expected task) ✗ — 0.81s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "when they arrive""); DUE_TEXT line paired with NONE

> [context]
> Participant A: heading over around 7
> Participant A: can someone grab ice on the way?
> 
> [latest messages]
> You: I'll get it

```
NONE
NONE
NONE
Call the ice delivery person
DUE_TEXT: "when they arrive"
```

**[batch-filler]** (batch, filler burst, expected NONE) ✓ — 1.92s

> [latest messages]
> Them: lol
> Them: did you see that
> Them: 😂😂
> You: haha yes

```
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE
NONE

```

**[batch-self-line]** (batch, single Self-thread line, expected task) ✓ — 1.90s

> Renew the car registration this week

```
[corrections]: 
[open suggestions]: 
[context]: 
[latest messages]
You: can you also send me the wifi password
Them: can you call the mechanic today
Them: actually nvm I just called them
Them: are you free
Them: can you call the mechanic today
Them
```

**[correction-1]** (correction, Not for me (expects NONE), expected NONE) ✓ — 1.87s ⚠️ DUE_TEXT line paired with NONE

_Real message text: input and output are only in the Desktop CSV._

**[correction-2]** (correction, Not for me (expects NONE), expected NONE) ✗ — 1.71s

_Real message text: input and output are only in the Desktop CSV._

**[real-E8B45AC2]** (real history (unscored), expected unscored) — — 1.90s

_Real message text: input and output are only in the Desktop CSV._

**[real-26BDEA34]** (real history (unscored), expected unscored) — — 2.16s

_Real message text: input and output are only in the Desktop CSV._

**[real-0E6E3AF6]** (real history (unscored), expected unscored) — — 1.84s

_Real message text: input and output are only in the Desktop CSV._

**[real-780CDD64]** (real history (unscored), expected unscored) — — 1.85s

_Real message text: input and output are only in the Desktop CSV._

**[real-19B054EA]** (real history (unscored), expected unscored) — — 1.80s

_Real message text: input and output are only in the Desktop CSV._

**[real-A6C9F250]** (real history (unscored), expected unscored) — — 1.82s

_Real message text: input and output are only in the Desktop CSV._

**[real-8F78D776]** (real history (unscored), expected unscored) — — 1.79s ⚠️ leaked token Output:

_Real message text: input and output are only in the Desktop CSV._

**[real-46457AC1]** (real history (unscored), expected unscored) — — 1.88s

_Real message text: input and output are only in the Desktop CSV._

**[real-9A98E8CD]** (real history (unscored), expected unscored) — — 1.79s ⚠️ leaked token Output:

_Real message text: input and output are only in the Desktop CSV._

**[real-210A7907]** (real history (unscored), expected unscored) — — 1.95s

_Real message text: input and output are only in the Desktop CSV._

**[real-8A39935D]** (real history (unscored), expected unscored) — — 2.05s

_Real message text: input and output are only in the Desktop CSV._

**[real-B5F6D035]** (real history (unscored), expected unscored) — — 2.08s ⚠️ leaked token <|im_end|>; leaked token <|im_start|>; unresolvable DUE_TEXT line; DUE_TEXT line paired with NONE

_Real message text: input and output are only in the Desktop CSV._

**[real-9269635B]** (real history (unscored), expected unscored) — — 1.93s

_Real message text: input and output are only in the Desktop CSV._

**[real-0DB5F239]** (real history (unscored), expected unscored) — — 1.94s

_Real message text: input and output are only in the Desktop CSV._

**[real-0402C683]** (real history (unscored), expected unscored) — — 1.87s ⚠️ leaked token <|im_end|>; leaked token <|im_start|>; unresolvable DUE_TEXT line; DUE_TEXT line paired with NONE

_Real message text: input and output are only in the Desktop CSV._

**[real-5C02B6C4]** (real history (unscored), expected unscored) — — 1.99s

_Real message text: input and output are only in the Desktop CSV._

**[real-ED76DCE0]** (real history (unscored), expected unscored) — — 1.96s

_Real message text: input and output are only in the Desktop CSV._

**[real-D412A9A5]** (real history (unscored), expected unscored) — — 1.98s

_Real message text: input and output are only in the Desktop CSV._

**[real-1D355D33]** (real history (unscored), expected unscored) — — 1.88s ⚠️ leaked token <|im_end|>; leaked token <|im_start|>

_Real message text: input and output are only in the Desktop CSV._

**[real-17A546C9]** (real history (unscored), expected unscored) — — 1.90s ⚠️ leaked token <|im_end|>; leaked token <|im_start|>

_Real message text: input and output are only in the Desktop CSV._

**[real-14610EC9]** (real history (unscored), expected unscored) — — 1.92s

_Real message text: input and output are only in the Desktop CSV._

**[real-C1C34746]** (real history (unscored), expected unscored) — — 2.09s ⚠️ leaked token <|im_end|>; leaked token <|im_start|>

_Real message text: input and output are only in the Desktop CSV._

**[real-4E08A289]** (real history (unscored), expected unscored) — — 1.88s ⚠️ leaked token Output:

_Real message text: input and output are only in the Desktop CSV._

**[real-604F01D5]** (real history (unscored), expected unscored) — — 2.36s

_Real message text: input and output are only in the Desktop CSV._

**[real-2A50BBFB]** (real history (unscored), expected unscored) — — 1.66s ⚠️ leaked token Output:

_Real message text: input and output are only in the Desktop CSV._

**[real-20221CCB]** (real history (unscored), expected unscored) — — 1.85s

_Real message text: input and output are only in the Desktop CSV._

**[real-F707E4FC]** (real history (unscored), expected unscored) — — 1.87s

_Real message text: input and output are only in the Desktop CSV._

**[real-A2C7525C]** (real history (unscored), expected unscored) — — 1.88s

_Real message text: input and output are only in the Desktop CSV._

**[real-B75CBEE3]** (real history (unscored), expected unscored) — — 1.91s

_Real message text: input and output are only in the Desktop CSV._

**[real-52B800B9]** (real history (unscored), expected unscored) — — 1.85s ⚠️ leaked token Output: ⚠️ possible hallucination

_Real message text: input and output are only in the Desktop CSV._

**[real-2FB685E9]** (real history (unscored), expected unscored) — — 1.86s ⚠️ possible hallucination

_Real message text: input and output are only in the Desktop CSV._

**[real-F78BA901]** (real history (unscored), expected unscored) — — 0.46s ⚠️ leaked token <|im_end|>

_Real message text: input and output are only in the Desktop CSV._

**[real-5F30D2C8]** (real history (unscored), expected unscored) — — 1.56s

_Real message text: input and output are only in the Desktop CSV._

**[real-2F75EAD5]** (real history (unscored), expected unscored) — — 1.83s ⚠️ possible hallucination

_Real message text: input and output are only in the Desktop CSV._

**[real-B3D9E6CC]** (real history (unscored), expected unscored) — — 1.87s ⚠️ leaked token Output:

_Real message text: input and output are only in the Desktop CSV._

**[real-C0637F4F]** (real history (unscored), expected unscored) — — 1.85s

_Real message text: input and output are only in the Desktop CSV._

**[real-81767AA1]** (real history (unscored), expected unscored) — — 1.83s ⚠️ possible hallucination

_Real message text: input and output are only in the Desktop CSV._

**[real-79048593]** (real history (unscored), expected unscored) — — 1.63s

_Real message text: input and output are only in the Desktop CSV._

**[real-37175697]** (real history (unscored), expected unscored) — — 1.53s ⚠️ leaked token Output:

_Real message text: input and output are only in the Desktop CSV._

**[real-59F0DB0C]** (real history (unscored), expected unscored) — — 1.84s ⚠️ leaked token Output:

_Real message text: input and output are only in the Desktop CSV._

**[real-BA94E6FF]** (real history (unscored), expected unscored) — — 1.28s ⚠️ leaked token Output:

_Real message text: input and output are only in the Desktop CSV._

**[real-BFC676A1]** (real history (unscored), expected unscored) — — 1.15s ⚠️ leaked token Output:

_Real message text: input and output are only in the Desktop CSV._

**[real-FA1CBB4E]** (real history (unscored), expected unscored) — — 1.12s ⚠️ leaked token Output:

_Real message text: input and output are only in the Desktop CSV._

**[real-EF3A7752]** (real history (unscored), expected unscored) — — 1.79s

_Real message text: input and output are only in the Desktop CSV._

**[real-F2395433]** (real history (unscored), expected unscored) — — 1.81s

_Real message text: input and output are only in the Desktop CSV._

**[real-7F3139CE]** (real history (unscored), expected unscored) — — 1.84s ⚠️ possible hallucination

_Real message text: input and output are only in the Desktop CSV._

**[real-7E762122]** (real history (unscored), expected unscored) — — 1.91s ⚠️ possible hallucination

_Real message text: input and output are only in the Desktop CSV._

**[real-452481CD]** (real history (unscored), expected unscored) — — 1.86s ⚠️ possible hallucination

_Real message text: input and output are only in the Desktop CSV._

**[real-3581500E]** (real history (unscored), expected unscored) — — 1.80s

_Real message text: input and output are only in the Desktop CSV._

**[real-EE145439]** (real history (unscored), expected unscored) — — 1.80s

_Real message text: input and output are only in the Desktop CSV._

### Qwen3-4B-Instruct

**[task-simple-1]** (simple task, expected task) ✓ — 3.92s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "before the trip"")

> Need to renew my passport before the trip

```
Renew my passport
DUE_TEXT: "before the trip"
```

**[task-simple-2]** (simple task, expected task) ✓ — 0.81s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "from the place on 5th"")

> Pick up dry cleaning from the place on 5th

```
Pick up dry cleaning  
DUE_TEXT: "from the place on 5th"
```

**[task-simple-3]** (simple task, expected task) ✓ — 0.34s

> Should look into switching our CI provider, current one keeps flaking

```
Research CI provider options
```

**[task-simple-4]** (simple task, expected task) ✓ — 0.42s

> Refill the propane tank for the grill

```
Refill the propane tank for the grill
```

**[task-simple-5]** (simple task, expected task) ✓ — 0.54s

> Circle back with the landlord about the leaky faucet

```
Circle back with the landlord about the leaky faucet
```

**[task-simple-6]** (simple task, expected task) ✓ — 0.43s

> Order a new set of running shoes, mine are falling apart

```
Order a new set of running shoes
```

**[task-simple-7]** (simple task, expected task) ✓ — 0.31s

> Draft the intro paragraph for the grant proposal

```
Draft intro paragraph for grant proposal
```

**[task-simple-8]** (simple task, expected task) ✓ — 0.31s

> Text mom back about Thanksgiving plans

```
Text mom back about Thanksgiving plans
```

**[task-simple-9]** (simple task, expected task) ✓ — 0.49s

> Need to follow up with the insurance company about the claim

```
Follow up with the insurance company about the claim
```

**[task-simple-10]** (simple task, expected task) ✓ — 0.21s

> Reminder to myself: water the plants

```
Water the plants
```

**[task-due-1]** (due date, expected task) ✓ — 0.53s

> Submit the expense report by tomorrow

```
Submit the expense report
DUE_TEXT: "by tomorrow"
```

**[task-due-2]** (due date, expected task) ✓ — 0.57s

> Meet Priya for coffee next Tuesday

```
Meet Priya for coffee
DUE_TEXT: "next Tuesday"
```

**[task-due-3]** (due date, expected task) ✓ — 0.75s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "before the 1st"")

> Pay the storage unit rent before the 1st

```
Pay the storage unit rent
DUE_TEXT: "before the 1st"
```

**[task-due-4]** (due date (vague), expected task) ✓ — 0.57s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "sometime soon"")

> Get the car inspected sometime soon

```
Get the car inspected
DUE_TEXT: "sometime soon"
```

**[task-due-5]** (due date, expected task) ✓ — 0.54s

> Finish reading chapter 4 by Sunday

```
Read chapter 4
DUE_TEXT: "by Sunday"
```

**[task-due-6]** (due date (vague), expected task) ✓ — 0.90s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "before it lapses at the end of the week"")

> Renew the gym membership before it lapses at the end of the week

```
Renew gym membership
DUE_TEXT: "before it lapses at the end of the week"
```

**[task-multi-1]** (multi-task, expected task) ✓ — 0.54s

> Can you order stamps and also drop the packages at the post office

```
Order stamps and drop off packages at the post office
```

**[task-multi-2]** (multi-task, expected task) ✓ — 0.57s

> Book flights for the offsite and reserve a rental car

```
Book flights for the offsite and reserve a rental car
```

**[task-multi-3]** (multi-task, expected task) ✓ — 0.44s

> Ping the landlord and also schedule the AC repair

```
Ping the landlord  
Schedule AC repair
```

**[task-multi-4]** (multi-task, expected task) ✓ — 0.63s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "to the recruiter"")

> Update the resume and send it to the recruiter

```
Update the resume
DUE_TEXT: "to the recruiter"
```

**[filler-1]** (zero-signal, expected NONE) ✓ — 0.15s

> haha that's hilarious

```
NONE
```

**[filler-2]** (zero-signal, expected NONE) ✓ — 0.24s

> Just got back from the gym, feeling good

```
NONE
```

**[filler-3]** (zero-signal, expected NONE) ✓ — 0.15s

> The weather has been really nice this week

```
NONE
```

**[filler-4]** (zero-signal, expected NONE) ✓ — 0.15s

> Thanks, appreciate it!

```
NONE
```

**[filler-5]** (zero-signal, expected NONE) ✓ — 0.15s

> That restaurant was pretty mid honestly

```
NONE
```

**[filler-6]** (zero-signal, expected NONE) ✓ — 0.15s

> lmaooo no way

```
NONE
```

**[filler-7]** (zero-signal (question), expected NONE) ✓ — 0.15s

> did you end up going

```
NONE
```

**[filler-8]** (zero-signal (question), expected NONE) ✗ — 0.65s

> what time works for you tomorrow

```
Update 1: Schedule meeting tomorrow  
DUE_TEXT: "tomorrow"
```

**[filler-9]** (zero-signal, expected NONE) ✓ — 0.16s

> sure, sounds good

```
NONE
```

**[filler-10]** (zero-signal (emoji only), expected NONE) ✓ — 0.15s

> 🎉🎉🎉

```
NONE
```

**[filler-11]** (zero-signal (third-party task), expected NONE) ✓ — 0.15s

> he said he'd handle the invoice himself

```
NONE
```

**[filler-12]** (zero-signal (already done), expected NONE) ✓ — 0.15s

> already submitted the report this morning

```
NONE
```

**[filler-13]** (zero-signal (link share), expected NONE) ✓ — 0.23s

> check out this link lol https://example.com/funny-video

```
NONE
```

**[confidential-1]** (confidentiality, expected NONE) ✓ — 0.23s

> Don't mention this to anyone but I'm thinking about quitting

```
NONE
```

**[confidential-2]** (confidentiality, expected NONE) ✓ — 0.23s

> Keep this between us — can you cancel the reservation for Saturday

```
NONE
```

**[confidential-3]** (confidentiality, expected NONE) ✓ — 0.24s

> please don't repeat this to the team but the layoffs are next week

```
NONE
```

**[confidential-4]** (confidentiality, expected NONE) ✓ — 0.24s

> this stays between us — I might be leaving the company

```
NONE
```

**[context-1]** (context block, task in latest messages, expected task) ✓ — 0.31s

> [context]
> You: did you see the game
> Them: yeah it was wild
> 
> [latest messages]
> Them: anyway can you send me that doc

```
Send that doc
```

**[context-2]** (context block, task only in context (must be ignored), expected NONE) ✓ — 0.25s

> [context]
> Them: I need to buy a new laptop
> You: nice, any model in mind
> 
> [latest messages]
> Them: still deciding, probably next month

```
NONE
```

**[context-3]** (context block, task in latest messages, expected task) ✓ — 0.31s

> [context]
> You: how's the new apartment
> Them: pretty good so far
> 
> [latest messages]
> Them: still need to hang the curtains though

```
Hang the curtains
```

**[context-4]** (context block, no task anywhere, expected NONE) ✓ — 0.24s

> [context]
> Them: my flight got delayed
> You: ugh that's rough
> 
> [latest messages]
> Them: yeah just gonna grab dinner at the airport

```
NONE
```

**[edge-1]** (edge case, expected NONE) ✓ — 0.15s

> ok

```
NONE
```

**[edge-2]** (edge case, expected NONE) ✓ — 0.15s

> idk maybe later

```
NONE
```

**[task-research-1]** (research/project, expected task) ✓ — 0.81s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "feels like a DB query issue"")

> Should dig into why the staging deploy is slow, feels like a DB query issue

```
Dig into staging deploy slowdown
DUE_TEXT: "feels like a DB query issue"
```

**[task-research-2]** (research/project, expected task) ✓ — 0.43s

> Want to try rewriting the onboarding flow in the new framework at some point

```
Research the new framework onboarding flow
```

**[task-research-3]** (research/project, expected task) ✓ — 0.55s

> Look into whether we should migrate off the old auth library

```
Research whether we should migrate off the old auth library
```

**[task-research-4]** (research/project, expected task) ✓ — 0.54s

> Want to benchmark the new caching layer against the old one at some point

```
Research the new caching layer performance against the old one
```

**[task-fitness-1]** (routine/fitness, expected task) ✗ — 0.24s

> Need to stretch more before runs, keep tweaking my hip

```
NONE
```

**[task-fitness-2]** (routine/fitness, expected task) ✓ — 0.54s

> Stretch goal: get back into a regular sleep schedule

```
Stretch goal: Get back into a regular sleep schedule
```

**[task-fitness-3]** (routine/fitness, expected task) ✓ — 0.84s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "in the spring"")

> Sign up for the 10k in the spring

```
Sign up for the 10k
DUE_TEXT: "in the spring"
```

**[batch-withdrawn]** (batch, request withdrawn in the same batch, expected NONE) ✓ — 0.25s

> [latest messages]
> Them: hey
> Them: can you pick up the package from the front desk
> Them: never mind, my roommate got it

```
NONE
```

**[batch-update]** (batch, UPDATE of an open suggestion, expected task) ✓ — 0.82s

> [open suggestions]
> 1. Book a table for Friday
> 
> [latest messages]
> Them: actually can we do Saturday instead
> Them: same place

```
UPDATE 1: Book a table for Saturday

DUE_TEXT: "Saturday"
```

**[batch-cancel-and-new]** (batch, CANCEL plus a new task, expected task) ✓ — 0.79s

> [open suggestions]
> 1. Buy printer ink
> 
> [latest messages]
> Them: I picked up the ink already
> Them: can you return the library books tomorrow

```
CANCEL 1
Return the library books
DUE_TEXT: "tomorrow"
```

**[batch-new-beside-open]** (batch, new task beside an unrelated open suggestion, expected task) ✗ — 0.79s

> [open suggestions]
> 1. Call the plumber
> 
> [latest messages]
> Them: can you also pick up dog food on the way home

```
UPDATE 1: Call the plumber and pick up dog food on the way home
```

**[batch-group-other]** (batch, group request addressed to someone else, expected NONE) ✗ — 0.32s

> [context]
> Participant A: who's bringing what on saturday
> 
> [latest messages]
> Participant B: Participant A can you bring the chips
> Participant A: sure

```
Bring the chips
```

**[group-other-by-name]** (group Chat, request to another Participant by name, expected NONE) ✗ — 0.67s

> [latest messages]
> Participant A: Priya, can you book the table for Friday?
> Participant A: somewhere near the station

```
Book table near the station
DUE_TEXT: "Friday"
```

**[group-whole-group]** (group Chat, request to the whole group, expected NONE) ✗ — 0.61s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "around 7"")

> [latest messages]
> Participant A: heading over around 7
> Participant A: can someone grab ice on the way?

```
Grab ice
DUE_TEXT: "around 7"
```

**[group-taken-on-same-batch]** (group Chat, whole-group request taken on in the same Batch, expected task) ✓ — 0.60s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "around 7"")

> [latest messages]
> Participant A: heading over around 7
> Participant A: can someone grab ice on the way?
> You: I'll get it

```
Grab ice
DUE_TEXT: "around 7"
```

**[group-taken-on-later-batch]** (group Chat, whole-group request taken on in a later Batch, expected task) ✓ — 0.28s

> [context]
> Participant A: heading over around 7
> Participant A: can someone grab ice on the way?
> 
> [latest messages]
> You: I'll get it

```
Grab ice
```

**[batch-filler]** (batch, filler burst, expected NONE) ✓ — 0.24s

> [latest messages]
> Them: lol
> Them: did you see that
> Them: 😂😂
> You: haha yes

```
NONE
```

**[batch-self-line]** (batch, single Self-thread line, expected task) ✓ — 0.57s ⚠️ unresolvable DUE_TEXT line ("DUE_TEXT: "this week"")

> Renew the car registration this week

```
Renew the car registration
DUE_TEXT: "this week"
```

**[correction-1]** (correction, Not for me (expects NONE), expected NONE) ✗ — 2.31s

_Real message text: input and output are only in the Desktop CSV._

**[correction-2]** (correction, Not for me (expects NONE), expected NONE) ✗ — 2.44s ⚠️ unresolvable DUE_TEXT line

_Real message text: input and output are only in the Desktop CSV._

**[real-E8B45AC2]** (real history (unscored), expected unscored) — — 0.24s

_Real message text: input and output are only in the Desktop CSV._

**[real-26BDEA34]** (real history (unscored), expected unscored) — — 0.25s

_Real message text: input and output are only in the Desktop CSV._

**[real-0E6E3AF6]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-780CDD64]** (real history (unscored), expected unscored) — — 0.24s

_Real message text: input and output are only in the Desktop CSV._

**[real-19B054EA]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-A6C9F250]** (real history (unscored), expected unscored) — — 0.24s

_Real message text: input and output are only in the Desktop CSV._

**[real-8F78D776]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-46457AC1]** (real history (unscored), expected unscored) — — 0.25s

_Real message text: input and output are only in the Desktop CSV._

**[real-9A98E8CD]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-210A7907]** (real history (unscored), expected unscored) — — 0.25s

_Real message text: input and output are only in the Desktop CSV._

**[real-8A39935D]** (real history (unscored), expected unscored) — — 0.25s

_Real message text: input and output are only in the Desktop CSV._

**[real-B5F6D035]** (real history (unscored), expected unscored) — — 0.24s

_Real message text: input and output are only in the Desktop CSV._

**[real-9269635B]** (real history (unscored), expected unscored) — — 0.25s

_Real message text: input and output are only in the Desktop CSV._

**[real-0DB5F239]** (real history (unscored), expected unscored) — — 0.33s

_Real message text: input and output are only in the Desktop CSV._

**[real-0402C683]** (real history (unscored), expected unscored) — — 0.23s

_Real message text: input and output are only in the Desktop CSV._

**[real-5C02B6C4]** (real history (unscored), expected unscored) — — 0.25s

_Real message text: input and output are only in the Desktop CSV._

**[real-ED76DCE0]** (real history (unscored), expected unscored) — — 0.33s

_Real message text: input and output are only in the Desktop CSV._

**[real-D412A9A5]** (real history (unscored), expected unscored) — — 0.25s

_Real message text: input and output are only in the Desktop CSV._

**[real-1D355D33]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-17A546C9]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-14610EC9]** (real history (unscored), expected unscored) — — 0.23s

_Real message text: input and output are only in the Desktop CSV._

**[real-C1C34746]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-4E08A289]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-604F01D5]** (real history (unscored), expected unscored) — — 0.24s

_Real message text: input and output are only in the Desktop CSV._

**[real-2A50BBFB]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-20221CCB]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-F707E4FC]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-A2C7525C]** (real history (unscored), expected unscored) — — 0.23s

_Real message text: input and output are only in the Desktop CSV._

**[real-B75CBEE3]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-52B800B9]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-2FB685E9]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-F78BA901]** (real history (unscored), expected unscored) — — 0.69s

_Real message text: input and output are only in the Desktop CSV._

**[real-5F30D2C8]** (real history (unscored), expected unscored) — — 0.24s

_Real message text: input and output are only in the Desktop CSV._

**[real-2F75EAD5]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-B3D9E6CC]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-C0637F4F]** (real history (unscored), expected unscored) — — 0.23s

_Real message text: input and output are only in the Desktop CSV._

**[real-81767AA1]** (real history (unscored), expected unscored) — — 0.24s

_Real message text: input and output are only in the Desktop CSV._

**[real-79048593]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-37175697]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-59F0DB0C]** (real history (unscored), expected unscored) — — 0.30s

_Real message text: input and output are only in the Desktop CSV._

**[real-BA94E6FF]** (real history (unscored), expected unscored) — — 0.25s

_Real message text: input and output are only in the Desktop CSV._

**[real-BFC676A1]** (real history (unscored), expected unscored) — — 0.24s

_Real message text: input and output are only in the Desktop CSV._

**[real-FA1CBB4E]** (real history (unscored), expected unscored) — — 0.24s

_Real message text: input and output are only in the Desktop CSV._

**[real-EF3A7752]** (real history (unscored), expected unscored) — — 0.24s

_Real message text: input and output are only in the Desktop CSV._

**[real-F2395433]** (real history (unscored), expected unscored) — — 0.24s

_Real message text: input and output are only in the Desktop CSV._

**[real-7F3139CE]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-7E762122]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-452481CD]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

**[real-3581500E]** (real history (unscored), expected unscored) — — 0.16s

_Real message text: input and output are only in the Desktop CSV._

**[real-EE145439]** (real history (unscored), expected unscored) — — 0.15s

_Real message text: input and output are only in the Desktop CSV._

