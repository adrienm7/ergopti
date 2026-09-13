<!-- docs/audits/hammerspoon/2026_09_09/native-hammerspoon.md -->

# HS-274 native Hammerspoon evidence and reuse

This is a continuation record, not a declaration that HS-274 is fixed.
Reconcile the current branch and workflow with Git before executing anything.
The [investigation](discoveries.md) and [producer contract](producer-contract.md)
own the earlier acquisition experiments and rejected approaches.

## What the tests actually establish

| Layer | Evidence | Limit |
| --- | --- | --- |
| Windows Lua/Python tests | Real delivery, transport, accounting and context modules with explicit native doubles | Cannot prove Hammerspoon APIs, Accessibility permission or HID acquisition |
| GitHub Actions macOS | Actual Hammerspoon, Quartz, IOKit and the owned Karabiner runtime | Input comes from a controlled virtual HID fixture, not physical keyboard hardware |
| Production driver | Existing keylogger remains the ordinary counting path | Complete physical stream startup and exclusive accounting are not integrated |

The expression `condition and nil or keycode` always retains `keycode`. Replacing
it with global suppression loses real Space when remapped Escape also emits
Space. Preserve real physical input, logical text and non-synthetic classification.
Neither successful UI clicks nor `fixture_only` receipts justify production admission.

## Reuse the verified producer

The unchanged producer is retained by
[build 34723122359](https://github.com/adrienm7/ergopti/actions/runs/34723122359),
at revision `80289309a01ae0a38d66a7687ced39120dccf30f`.
Its archive is 12,183,253 bytes and has SHA-256
`e1628f14a7838c07a50304a9de5346820eb9ec863868b4154b9dd0abb7fc630e`.
The upstream source revision is `9312593e1a3bf72b94c63c524ebabe2637442e8a`.
The workflow pins this artifact and validates it before use. Local copies remain
under `.rtk/hs274-producer-build-34723122359/`; do not delete them as cleanup.
Do not rebuild for changes confined to Python admission or Lua consumers.
Artifact expiry is not evidence of changed producer behavior: check the retained
archive and hash before considering a rebuild.

Reusable owners are in `tools/diagnostics/`: the `hs274_stream*` protocol and
patch tools, `hs274_hammerspoon.py`, `hs274-hammerspoon.lua`, `hs274-context.lua`,
`hs274-context-probe.lua`, and the `hs274_accessibility*` helpers and tests.
The driver's `physical_delivery`, `physical_transport`, `physical_context` and
`physical_clock` modules are exercised separately from their native adapters.

## Retained native admission observation

[Run 34737254371, attempt 2](https://github.com/adrienm7/ergopti/actions/runs/34737254371/attempts/2)
ran at `73577984af62dbd9b7d2aa8a81e1b50d80ee604f`.
Job `103704621060` obtained a runner and failed. The earlier queued job
`103670745627` was cancelled by the maintainer; it is not the handle to monitor.
Always inspect `run_attempt` and the latest jobs after a rerun.

The [original screenshot](hs274-picker-attempt2.png) shows the owned Hammerspoon
application selected in the native Open dialog, with Open enabled. The
[minimal receipt](hs274-admission-attempt2.json) preserves authentication,
selection and the three subsequent admission results without temporary credentials.
The picker returned `application_selected`, but all three permission scans
returned `missing_application`. The primary failure was ordinary Accessibility
approval; the Lua stop-while-waiting message was a cleanup consequence.

Full downloaded artifacts remain under
`.rtk/hs274-native-run-34737254371-attempt2/`.
The screenshot and minimal receipt are tracked here so GitHub artifact expiry
and ignored-file cleanup cannot erase this observation.

## Do not repeat these rejected diagnoses

- The file picker is a standalone Open window, not a sheet of Accessibility.
- The verified provider sheet has one unlabelled AXButton. Its screenshot
  identified Done; querying a nonexistent button title did not establish identity.
- System Events dictionary names can shadow script variables. `buttons` and
  `rows` caused errors; changing permissions would not fix those scripting errors.
- After authentication, observe retirement of the sheet through its window
  owner. Querying a retired Modify Settings child produced AppleEvent errors.
- Three successful scans still found no Hammerspoon row. More polling alone
  has not resolved admission; do not increase timeouts without new evidence.
- Native preflight once failed because macOS resolves `/var` through `/private/var`.
  Skipped acquisition steps resulted from that failure, not ignored dispatch booleans.
  Inspect the earliest failed step before interpreting later `always()` branches.
- Hammerspoon's native JavaScript success callback can supply exactly `{code=0}`.
  The existing `webview_result` adapter handles that sentinel; do not restore
  a blanket non-nil-error rejection or weaken acceptance of actual errors.

## Current experiment and next evidence

The updated helper keeps the temporary authorizing account alive through selection
and permission observation. Previously it was deleted immediately after the
authentication sheet closed. A local integration test failed on that ordering;
the updated tests cover cleanup on both successful admission and selection failure.
[Run 34750872746](https://github.com/adrienm7/ergopti/actions/runs/34750872746)
tested that lifetime change at `50f89f7229a1527e89f982a0c519399047752de7`.
Authentication succeeded and account cleanup completed, but all three admission
scans again returned `missing_application`. Keeping the account alive did not
resolve the native failure; do not repeat that experiment unchanged.
[Run 34751707052](https://github.com/adrienm7/ergopti/actions/runs/34751707052)
then captured the screen immediately after Open closed. The [retained screenshot](hs274-picker-after-open.png)
showed the original eleven application rows without Hammerspoon; the native
window list contained only Accessibility and reported zero sheets. There was
no observed secondary authentication dialog. Do not add another authentication
flow on that assumption. The next diagnostic reads the copied bundle metadata,
checks its signature and retains scoped TCC messages on admission failure.
Neither experiment proves global trust or closes HS-274.

The supervisor signals `permission_ready` only after ordinary UI approval.
Lua then independently checks actual Accessibility trust before creating the
input fixture. Native context tests must subsequently verify public, private,
secure-field and resumed capture, with real AX focus and event timestamps.

Still required before production: complete initial held-key state, device and
usage coverage, keyboard-type-aware conversion, repeat/modifier/combo behavior,
multiple keyboards, startup/stop ownership, exclusive physical credits, native
cost measurements and a distributable runtime. The baseline probe samples only
Escape and Space. Monitor readiness is not a complete held-key inventory.
Apple's device-specific ISO conversion is documented in
[IOHIDKeyboard.cpp](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/IOHIDFamily/IOHIDKeyboard.cpp);
do not infer physical identity from layout-dependent characters.

Keep one heavy validation active at a time and preserve the other agent's AHK
work. Rebase and fast-forward locally. Publish only the feature branch when
native validation requires it; no push to `dev` or `main` is authorized.
