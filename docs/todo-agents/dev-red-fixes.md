<!-- docs/todo-agents/dev-red-fixes.md -->

# Dev red fixes (October 21, 2026)

Reds found on a run of dev alone (39623459261, at 1792356fef) and on the newest dev tip.

## Done

- **Generated `personal_files.lua` and `architecture.md` drift:** b4711585e0 edited the generated
  `personal_files.lua` by hand; its generator now emits the same `NativePath.basename` form, and the
  architecture diagram is regenerated for `adapters.running_application` (40e283e555).
- **macOS fixture scope residue:** the gesture actions, selection translation and typing metrics fixtures
  now own `adapters.running_application` (a8235a27bd). The `number_policy` and `native_path` residues
  and the `test_loaded_physical_termination` logger-dependency failures of that run were already fixed
  on dev by afa00020a6 and 49c2a8e6be.
- **Windows `require_state` ratchet 28 against 27:** the new offender was `infra/json.ahk` (the decode
  tally globals of 8a43bd805c). The tally now lives in a function static captured once per decoder, so
  the count is back to 27 with no baseline or allowlist change (11c3f260b9).
- **Windows `Updater_ParseBody` single-decoder meta test:** the code has one decode path
  (`_Updater_ReleaseMember` then `JsonObjectMembers` then `_JsonParseObject`); the test follows that
  chain and refuses pattern or replacement decodes there (ea080f701b).
- **Updater source seal:** still valid against its pinned base ef238c2758; no reseal needed.
- **Format gate:** the preflight 39631475890 stopped at the Prettier check on `docs/ERGOPTIPLUS_TODO.md`
  of 34e5cb56ee; a later docs commit already reformatted it.
- **Windows `builtin-number-row-magic-owner` (16 cases):** 8a43bd805c scans JSON whitespace with
  `msvcrt\wcsspn`; the passive fixture replayed only `wcscspn`. It now replays both and still refuses
  every other native call (b0d4acd718).

## Remaining

- The macOS hotstring-classification red named in the hand-over does not appear in 39623459261; the next
  full run of the tip decides.
