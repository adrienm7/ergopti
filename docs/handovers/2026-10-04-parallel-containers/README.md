<!-- docs/handovers/2026-10-04-parallel-containers/README.md -->

# ErgoptiPlus container-stop checkpoint

This is a durable checkpoint requested by the maintainer on 2026-10-04. It
preserves pending source work before the old cloud container is stopped. The
seven feature groups and integration protocol are in [PARALLEL-WORK.md](PARALLEL-WORK.md).
Delta updates (item 22) are withdrawn by decision, not completed implementation.
The other 45 TODO identifiers remain; actual scope is still in
[the checklist](../../ERGOPTIPLUS_TODO.md).

## New-container prompts

Copy the entire prompt for the desired group into a fresh context:

- [Configuration and menus](PROMPT-config-menus.md)
- [Hotstrings](PROMPT-hotstrings.md)
- [Actions and physical bindings](PROMPT-actions.md)
- [AI](PROMPT-ai.md)
- [macOS input and Karabiner](PROMPT-macos-input.md)
- [Release archives and managed networks](PROMPT-release-network.md)
- [Windows native issues](PROMPT-windows-native.md)
- [Integration coordinator](COORDINATOR-PROMPT.md)

Start from the actual current `origin/dev`; historical SHAs below are evidence
and patch preimages, not instructions to replace current upstream work.
No new worker container has been started by publishing these prompts.

## Delivered and validation state

The current corrective commit is `2476b0b2a432599617712c483f0f84ae9b1dad89`:
Windows personal-editor admission now compares already classified content
case-sensitively instead of passing TOML bytes to a file-path comparison helper.
The native fixture's two StrReplace calls put the replacement limit in its
sixth argument. All 151 assertion starts and the seven failing cases remain.
Local selected format, encoding and JS gates pass (356 JS checks); native AHK
execution is pending in the Windows-only manual run
[37223727872](https://github.com/adrienm7/ergopti/actions/runs/37223727872).
Its exact automatic push run 37223712683 was cancelled. Do not describe this
corrected candidate as native-green until the manual run finishes.

The preceding Windows run 37221758669 failed with 9030 passed / 7 failed:
six early production admission failures and one fixture argument failure.
E2E, packaging and installation were skipped. The retained exact receipts and
independent diagnosis are under `evidence/windows102/`.

Linux-only run 37220398897 at `656c63593` completed successfully, including
17 installation variants. macOS-only run 37220040009 at `38e4ec1c4` passed
unit/E2E/package but failed two of eleven installation variants (clean and
Karabiner). The strict native and selected-OS verdicts failed; the AppleEvent
startup timeout's cause is not proved. Do not attribute it to TCC or relax its
original assertions/time budget without evidence. Both manual runs skipped
Release and the unrelated OS lanes.

## Pending candidate recovery

`manifest.json` pins every saved file's SHA-256 and byte count. The original
review receipts, metadata and focused logs are retained byte-exact inside
`evidence.tar.gz`; all `evidence/...` references below refer to that archive.
Extract into an owned temporary directory, never over the working checkout:

````sh
mkdir -p /tmp/ergopti-checkpoint-evidence
tar -xzf docs/handovers/2026-10-04-parallel-containers/evidence.tar.gz -C /tmp/ergopti-checkpoint-evidence
``` The patches are
inactive evidence, not changes installed in the product. Metadata contains
historical `/workspace/...` locations: relocate paths to this checkout and use
the newly installed environment before executing commands. Missing old paths
are not justification to discard source or invent test results. Git history
plus exact patches reconstruct candidates; no old full checkout is required.

1. **macOS archive publication, item 36.** `pending/macos-archive-publication.patch`
   preserves all 19 source paths plus its exact progress note against `cfa404175`.
   Source review approved the bounded migration; the final root gate then failed
   two JS checks: the new publication helper used current-time `new Date()`, and
   `test-macos-swift-launcher-ci.cjs` still looked up the old ZIP-signing step name.
   The same run passed 13879 macOS Lua tests. The two proposed forward repairs
   are in `pending/macos-archive-gate-suggestions.patch`: syntax only, NOT reviewed
   or fully qualified. Recover the source patch excluding its historical TODO
   hunk; append the note to the current item instead. Then apply/review the
   suggestions and run selected gates. Actual Sparkle update and Brew ZIP-install
   to XZ-upgrade acceptance are still unimplemented/unexecuted. Brew plan/handover
   is saved; Sparkle must use a disposable child app with owned installer lifecycle.
   Do not close 36 from direct extraction/signature checks alone.
2. **Program action, item 106.** `pending/run-program106.patch` preserves the
   frozen 62-path action, typed arguments, three native owners, picker and 21
   translations. Focused Linux: 22/0 with real child processes. Focused macOS:
   68/0 with controlled hs.task; actual Cocoa and Windows Job execution are
   UNEXECUTED. Existing assertions and action/localization values are retained.
   Independent review is incomplete: see the saved boundary receipt. Complete
   review and qualify the final composed source before integrating.
3. **Cursor-display window action, item 111.** Prefer
   `pending/linux-window111-after106.patch` only after the exact approved 106
   parent is integrated. `linux-window111-standalone.patch` records the historical
   independent parent, not an alternative to overwrite 106. Focused tests pass
   57/0 on LuaJIT and Lua5.4; old production fails six new cases. Real X11/two-
   display focus, keyboard-grab lifecycle, independent review and full selected
   gates remain pending. Wayland refuses this unsupported action; ordinary
   system Alt+Tab remains separate. Regenerate shared/driver outputs with owners.

For each recovered candidate, compare every owned preimage with actual upstream
and investigate overlap before applying. Preserve old independent corpora and
assertions. Never execute all pending patches in one blind apply or use reset,
clean, stash or force-push. Update the TODO per coherent integration commit.

## Environment and evidence limits

Use cloud-environment-onboarding:setup in the new container; a saved setup draft
is not proof that its install script ran. JS/native suites must run serially
because generated-drift controls temporarily mutate outputs. The old working
canonical TMPDIR was `/var/tmp/ergopti-cloud-validation` with a subprocess reaper;
using the GitHub CLI temporary directory for the whole suite caused a reproduced
false uninstall-fixture failure. Do not delete foreign `.git` directories or
fixtures to fix that precondition. Local Lua tests on Linux do not establish
physical macOS behavior, and native AHK requires Windows execution.
````
