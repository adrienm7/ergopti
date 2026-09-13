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

[Run 34752471752](https://github.com/adrienm7/ergopti/actions/runs/34752471752)
verified the exact copied bundle: Hammerspoon 1.1.1, identifier
`org.hammerspoon.Hammerspoon`, strict signature verification exit zero and
Developer ID team `VQCYSNZB89`. The scoped two-minute TCC log query exceeded
its five-second deadline. This is a diagnostic timeout, not a TCC refusal
reason. The collector now retains bounded partial output on timeout; older
receipts lost that output, so its absence cannot establish a silent native log.

[Run 34753282480](https://github.com/adrienm7/ergopti/actions/runs/34753282480)
at `8ce06ada7a0e6d63ea3b350f32b016660613ab5f`, job `103713317246`,
completed with the same admission failure. This time the TCC query completed
with exit zero. Its retained tail was truncated, but contains four explicit
`handle_TCCAccessCopyInformation(): failed to find an Application URL for bundle ID: org.hammerspoon.Hammerspoon.`
messages. The [minimal native receipt](hs274-tcc-bundle-resolution.json) retains
those exact lines, the signature result and the source artifact hash.
This is evidence of failed bundle URL resolution during TCC enumeration; it
does not yet prove why resolution failed or which registration change fixes it.
Next inspect resolution of the exact copied bundle in its launch context,
then test one targeted change. Do not repeat file-picker, account-lifetime or
signature-corruption hypotheses without changed evidence. The unchanged
producer archive remains reusable. The diagnostic change passed twelve local
Python tests and the selected 225-check JS gate before this native run.

The next experiment calls the documented `LSRegisterURL` for the exact owned
copy before launch and retains `NSWorkspace` bundle resolution before and after.
A zero registration status must be followed by the exact resolved copy path;
command failure, timeout and foreign or missing resolution stop admission.
This changes no TCC permission and cannot substitute for the subsequent native
Accessibility check. The local launch-order regression fails without registration;
native execution is still required to establish whether this resolves TCC's error.

[Run 34754395332](https://github.com/adrienm7/ergopti/actions/runs/34754395332),
job `103716208790`, tested that call at
`b83ed70abbe20c2ffbc1e19585a38f4d7b209c8b`. The native script executed
successfully and returned `{identifier: "org.hammerspoon.Hammerspoon",
before: null, status: 0, after: null}`. The exact-resolution guard stopped
before launch, as required. Explicit registration under the macOS temporary
directory did not make the bundle discoverable in this observation.
The next experiment changes only the owned directory parent to `~/Applications`;
it still allocates a unique child and keeps the same registration and trust
checks. This tests a location hypothesis, not a proven system-wide exclusion
rule for temporary paths. Never overwrite another Hammerspoon installation.

[Run 34754991511](https://github.com/adrienm7/ergopti/actions/runs/34754991511),
job `103717754654`, tested the new location at
`afa7aa48b6fde3927c1a9a5a3bc89eac44f2e586`. Registration now resolved the
exact owned copy under `/Users/runner/Applications/`. The ordinary Accessibility
scan found Hammerspoon enabled, without the previous missing-application error.
Actual Hammerspoon trust nevertheless stayed false through the bounded
post-approval check. No physical capture was admitted. Keep these results
distinct: native bundle resolution and UI state succeeded; process trust did not.

The next experiment settles the exact waiting Hammerspoon process after UI
approval, then launches the same copy and configuration once. Failure to settle
must prevent replacement and preserve the primary failure. The new process must
still establish actual Accessibility trust; restarting is not a permission grant.
Pinned Hammerspoon `MJAccessibilityUtils.m` calls `AXIsProcessTrustedWithOptions`
directly on every check, so a Lua cache is not the cause. Native validation must
determine whether a fresh process changes the observed trust result.

[Run 34755533559](https://github.com/adrienm7/ergopti/actions/runs/34755533559),
job `103719145066`, tested the restart at
`6e9cf688ff3db3a73df3ea80599ddbfbeaed0137`. The exact previous owner (PID
11587) settled, UI state was enabled, but the replacement still failed the
native trust check. Restarting alone did not resolve this failure.
The supervisor now retains TCC evidence before cleanup on consumer failure too,
not only on rejected UI admission. An additional bounded query follows the
exact currently owned PID's TCC message identifiers and Hammerspoon attribution;
diagnostic failure must not replace the primary failure or prevent cleanup.

[Run 34755981881, attempt 2](https://github.com/adrienm7/ergopti/actions/runs/34755981881/attempts/2),
job `103720782490`, at `c2a0a87d0175154a4871cb5d34528318ca8fcc2f`,
retained TCC decisions for exact owner PID 4066. Attribution names the owned
Hammerspoon as accessor, requestor and responsible process; its Developer ID
requirement matches with status zero. Accessibility nevertheless reports
`Denied (System Set)`, `authValue=0`, `authReason=4`. The separate Apple platform
signature mismatch does not invalidate Hammerspoon's Developer ID signature.
Attempt 1 stopped before Hammerspoon because an unexpected remapper peer was
running; the unchanged isolation guard stayed enabled for the fresh-run retry.

The existing-row approval path previously clicked a disabled Hammerspoon row
and accepted its displayed value of one without authenticating. Authentication
only existed for Add application. A newly clicked row now returns a distinct
pending result, authenticates through the verified sheet owner, then reads the
permission again while the temporary account remains alive. Already-enabled
rows remain separate. The local regression exercises both authentication
success and rejection without invoking the file picker. Native execution must
still establish that the pending sheet explains the observed TCC denial.

[Run 34756732271](https://github.com/adrienm7/ergopti/actions/runs/34756732271),
job `103722276281`, at `79ff44db16e933364afafd9b27a4afec846d9701`,
confirmed successful existing-row authentication and actual Hammerspoon
`field_focus.accessibility=true`. The permission blocker is crossed in this
native observation. The later failure is exact AX field focus: DOM focus was
true and fixture window ID was 61, but no focused window ID or AX role arrived.
Do not repeat permission, signature, registration or restart experiments for
this distinct failure. The fixture now retains AX errors and foreground process
identity when focus expires. Pinned `libwebview.m` already uses
`makeKeyAndOrderFront` in `show()`; missing window activation cannot be inferred
merely from the Lua method name. Self-AX observation limitations remain a
hypothesis until the actual errors or an independent observation establish them.

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
