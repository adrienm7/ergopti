<!-- docs/design/metrics-suspend-and-reset-session.md -->

# Metrics pause and session reset (PAR-50)

Two rows of the Metrics menu, `metrics_suspend` and `metrics_reset_session`,
exist on all three drivers with one meaning. Audit rows S5 and M10 of
`docs/audits/2026-10-24-cross-os-parity.md` are the evidence: before this
change they were Linux-only, and the Linux pause borrowed the password-field
flag.

## Pause

A pause is a state of its own. It is held apart from three other things that
also stop recording, and none of them can start, end or read it:

| Other cause                                   | Owner                                          |
| --------------------------------------------- | ---------------------------------------------- |
| Driver pause (the global Suspend)             | the script, `A_IsSuspended` / `script_control` |
| Secure field, private window, system-auth app | the privacy filters                            |
| Excluded application                          | the exclusion list                             |

Rules, replayed by `_shared/tests/corpus/metrics/collection_session_vectors.json`:

1. While paused, nothing the user types, clicks or scrolls is recorded or
   counted, and nothing typed meanwhile is recovered on resume.
2. Pausing first stores the text already typed, so the boundary never splits or
   discards it. Resuming back-fills nothing.
3. Leaving a secure field does not resume a pause, and resuming does not clear
   a secure field. A secure field never reports a pause.
4. It is idempotent, never persisted, and cleared on every start: a launch
   records as the stored settings say.
5. Rows that close an interval accepted before the pause (`session_end`,
   `idle_end`, lifecycle markers on Windows) are still written, because a
   `session_start` without its end poisons every active-time aggregate.
6. Hotstrings, predictions and shortcuts keep working: only the metrics stop.

Where each driver gates it:

| Driver  | State                            | Gate                                                                                                                  |
| ------- | -------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Linux   | `_suspended` in `keystats.lua`   | `may_record()`, the single decision point                                                                             |
| macOS   | `CoreState.collection_suspended` | `privacy_context.allows_logging`, which the keystroke handler, every synthetic sink and `may_persist` already consult |
| Windows | `KLCollection.suspended`         | `KL_CaptureHeld()` in the typing hook and the mouse sources, and `KL_AppendLog` for every entry                       |

## Session reset

Ends the current typing session exactly as the idle timeout would, then
restarts the live figures from zero. Stored history is never deleted.

1. The pending text is stored first.
2. An open session gets its own `session_end` (on Windows through the session
   owner, so the close is retried if refused). With no open session nothing is
   written.
3. The live typing-speed window and the session counters restart at zero.
4. A refused close refuses the reset and changes nothing; it never forces.
5. It works while paused or in a secure field and changes neither.

Linux keeps its earlier shape (it refuses while a flush is owed) because its
store is written from the same process.

## Hot-path cost

The gate adds one boolean read next to the existing pause read in each capture
path. On Windows a function call stands in for the read, measured on this host
at about 1.1 microseconds over the bare `A_IsSuspended` read (3 million
iterations, `scratchpad/bench_capture_held.ahk`), against keystroke work in
milliseconds. macOS and Linux add one table-field read inside code that already
reads several.
