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

[Run 34757432296](https://github.com/adrienm7/ergopti/actions/runs/34757432296),
job `103724131144`, at `771e3d0f91b843f00398de17175947d09107eba5`,
reported matching expected and foreground PID 6234 (Hammerspoon), window ID 62,
and true Accessibility and DOM focus. Both the own-application focused-element
query and system focused-application query returned `Messaging failed`.
This is not evidence of a different application stealing foreground focus.

The replacement fixture hosts ordinary and secure Cocoa fields in a separate
native process. Python owns its exact executable and bounded cleanup around the
whole Hammerspoon lifetime. Sequenced, atomically published commands select only
fixed public/private/secure/resumed states; receipts identify PID and window.
These receipts do not admit capture: Hammerspoon must independently obtain the
exact external AX window and text field, and the existing context observer must
record all four privacy transitions. Native input transport and accounting are
unchanged. The target never reads or reports field text. A target failure remains
an error even if consumer cleanup also fails. The Swift target must compile and
the complete fixture must execute on macOS before this replacement is validated.

## External target acceptance on native macOS

[Run 34758957794](https://github.com/adrienm7/ergopti/actions/runs/34758957794),
job `103728210889`, at `4fc8a8cfa3dc25a25820b59cde352612db2e6b4f`,
compiled the Cocoa target and passed the actual Escape/Space remapping step.
The [retained native receipt](hs274-external-target-success.json) preserves the
complete Hammerspoon result and target settlement with the source artifact hash.
Actual Accessibility trust was true; expected and focused AX window IDs were 46,
and the focused role was `AXTextField`. The independent context observer recorded
private/public/secure/resumed as false/true/false/true in observations 2 through 5.
Denied observations retained no application or epoch metadata. Original timestamp
conversion used the native Mach ratio 125/3; final physical credits were exactly
one Escape (53) and one Space (49). The consumer and context settled, and target
PID 4295 exited zero. This validates the external fixture and its two-key native
delivery path, not physical keyboard hardware or production-wide admission.

The overall workflow was red because the separate Quartz capability probes
(ordinary and root) and installed remapper permission probe failed. The actual
owned development remapping step was independently green; do not report the
whole workflow as green or remove those other probes to obtain that label.
The earlier dispatch 34758792872 unexpectedly referenced the previous revision;
it was cancelled and confirmed terminal before this replacement was dispatched.
Check the run's actual `head_sha` before interpreting any new native result.

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

## Expanded keyboard inventory build

[Build 34761359374](https://github.com/adrienm7/ergopti/actions/runs/34761359374)
passed native C++ tests, source instrumentation, all three component builds,
the actual CLI clock check and signature verification on
`2631806e1942e745bab849638e795d4c0b5ede30`. The downloaded archive is
12,179,381 bytes, with SHA-256
`eb768951172f9dfa70c24d0b0e98b2c009e11455eb8bcff9482530389a7a8096`.
All 13 retained capture headers match the owned sources. All three executables
are universal arm64/x86_64 development binaries with ad hoc signatures; this
is not a distributable signed production release. The clock receipt remains
`mach_absolute_time`, version 1, numerator 125 and denominator 3.

This producer retains `HS274_KEY_INVENTORY` observations for all selected
monitors, alongside the existing independent Escape/Space baseline probe.
The bounded collector checks keyboard leaf descriptors, read status and cookie,
binary values, duplicate usages/cookies and query ordering. Exhaustion remains
invalid even if its exception is caught. Native observation now requires readable
fixture inventories and retains other devices and monitor restarts too.

Compilation establishes that the actual IOKit calls build, not that a complete
inventory has been acquired successfully. Native execution with this archive
remains pending. Sequential per-element reads are not an atomic snapshot and
must be reconciled with queued values before production held-state admission.
Do not rerun the new inventory scenario against the earlier archive: its missing
inventory marker must fail the new evidence requirement. Reuse this build for
subsequent Python/Lua changes that leave its producer sources unchanged.

## Native inventory identity refusal

[Run 34762554442](https://github.com/adrienm7/ergopti/actions/runs/34762554442)
on `7d449e1fa6084f1135fecaec1add42cb7a62a41d` preserved one physical Escape and
one physical Space through Hammerspoon, all four privacy transitions and settled
consumer/target lifetimes. The remapping step nevertheless failed its new
inventory requirement: the controlled keyboard exhausted the 256-element bound.
The [retained refusal](hs274-inventory-refusal.json) includes exact samples and
hashes of the full source reports; do not relabel that run as successful.

The native descriptor exposes usages 224 through 231 as separate scalar and
array leaves. For usage 224, cookie 24 is a scalar bit and cookie 289 is an array
leaf with report count 32. Both reads succeeded. The truncated inventory retained
256 elements but only 248 distinct usages; another device returned 231 readable
elements. Usage count is therefore not element count, and a repeated usage is
not evidence that an element observation is a duplicate.

The correction preserves all distinct cookies and still rejects duplicate
cookies. A named diagnostic capacity bounds storage independently of the usage
range; version 2 publishes that capacity so the reader does not duplicate it.
Portable regressions retain independently valued scalar/array modifier elements,
accept a controlled 263-element descriptor and preserve explicit exhaustion.
The modifier regression fails on the previous collector. Native rebuilding and
execution of this correction remain pending. This changes inventory readability,
not physical credit ownership or synchronization with queued events.

Dispatch 34762400048 referenced the previous revision despite a matching branch
API response after publication. It was cancelled and confirmed terminal before
34762554442 was dispatched on the correct revision. Always inspect the run SHA.

[Build 34770142859](https://github.com/adrienm7/ergopti/actions/runs/34770142859)
passed native tests, instrumentation, all three component builds, the CLI clock
check and signature verification on `e3ec78844e47c645f827f0e5e327032137861828`.
Its verified archive is 12,179,413 bytes with SHA-256
`ca40025466114b9cab5b3975c70d910f3e59e41166423d397d7a2228f06f9f2b`.
All 13 retained headers match the owned sources. The three executables are
universal arm64/x86_64 development binaries with ad hoc signatures; the clock
receipt remains version 1, `mach_absolute_time`, numerator 125, denominator 3.
The workflow selects this archive for inventory receipt version 2. Physical
stream framing remains version 1; these are separate protocols. Native input
acceptance of the cookie/capacity correction is recorded below. Reuse this archive
while its producer sources remain unchanged.

## Complete fixture inventory acceptance

[Run 34771083506](https://github.com/adrienm7/ergopti/actions/runs/34771083506)
and [held-input run 34771337304](https://github.com/adrienm7/ergopti/actions/runs/34771337304)
both passed the owned remapping step on
`194524752b7267520954fb6d07a3f4b0262cdea3`, using the same verified producer.
Both workflows remained red on the separate capability probes; the remapping
receipts contain no observation error.

Each run retained 263 fixture elements with 263 unique cookies and 255 usages,
including both scalar and array leaves for modifier usages 224 through 231.
Enumeration completed without exhaustion and the inventories were readable.
A second device supplied 231 readable elements in each run; it did not provide
the controlled input, so this is not proof of two active physical keyboards.

The Hammerspoon scenario preserved one Escape credit and one Space credit,
all four privacy transitions, true native AX focus and settled consumer/target
lifetimes. In the held-input scenario the fixture's complete inventory contained
exactly one down element, Space at cookie 109. The independent kernel baseline
confirmed held Space, and the later release and fresh Space pair were preserved
in the 15-row raw receipt. No reconstruction from Quartz output was needed.

The shared `tools/diagnostics/fixtures/hs274-native-inventories.json` retains all
four inventories, the native input receipts, relevant consumer/baseline results
and source hashes. `hs274-stream-inventory-test.cpp` replays every native element
through the real collector and checks the controlled held state;
`hs274_inventory_test.py` checks complete transport retention. Query this corpus
by device/cookie or run its tests rather than loading it wholesale into context.

This establishes full enumeration for the controlled descriptor in these two
scenarios. It does not establish atomic synchronization with pending HID values,
lease-opening state, ordinary driver integration, all hardware descriptors or
exclusive production physical credits. Retain those requirements from the
producer contract; do not promote `fixture_only` based on this acceptance.
