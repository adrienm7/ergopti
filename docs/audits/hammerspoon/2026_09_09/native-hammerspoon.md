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

The workflow selects the [sampled state producer](#sampled-state-producer).
Reuse that archive while its producer sources remain unchanged. Earlier builds
below are historical evidence, not interchangeable runtime selections.

The earlier producer without full inventory or queued cookies is retained by
[build 34723122359](https://github.com/adrienm7/ergopti/actions/runs/34723122359),
at revision `80289309a01ae0a38d66a7687ced39120dccf30f`.
Its archive is 12,183,253 bytes and has SHA-256
`e1628f14a7838c07a50304a9de5346820eb9ec863868b4154b9dd0abb7fc630e`.
The upstream source revision is `9312593e1a3bf72b94c63c524ebabe2637442e8a`.
Local copies of this historical artifact remain
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

## Sampled state producer

Build [34778342181](https://github.com/adrienm7/ergopti/actions/runs/34778342181)
succeeded at `3af6805756e63fdf53ed81aa2fd33ab74b7d9fa6`. It initializes native
monitor state from qualified inventory samples and advances it before lease
storage checks, preserving raw observations. Native C++ regression tests,
compilation of all three products, strict signature verification and the CLI
clock check passed. Runtime input acceptance of this wiring remains pending.

The downloaded archive is 12,190,358 bytes, SHA-256
`028b773f7331388fc98060801b651fac4a34fc0f4857d0963a8c26dd0fb16153`.
All 13 retained headers match the owned sources. This build omitted the new
`hs274-key-state.hpp` from its evidence copies, although producer staging and
compilation include it; its source is retained at the exact Git revision above.
The workflow now also retains that header for future builds. This evidence-only
change does not require rebuilding this archive.

Native signature receipts identify all three products as universal x86_64/arm64
with ad hoc signatures. The CLI clock remains `mach_absolute_time`, numerator
125 and denominator 3; upstream remains
`9312593e1a3bf72b94c63c524ebabe2637442e8a`. Reuse this archive for unchanged
producer sources. It does not prove atomic queue cutover, consumer initial-state
handoff, physical keyboard hardware behavior or production accounting.

## Sampled state runtime acceptance

Both scenarios used producer build `34778342181` and consumer revision
`36f77978b19a29a17d665ad087ddf894bae6cf77`. Their actual input steps succeeded;
their workflows failed separate capability probes. Input is controlled virtual
HID, not a physical keyboard. Preserve these results rather than repeating
unchanged runs when developing the initial-state handoff.

- [Managed run 34779093372](https://github.com/adrienm7/ergopti/actions/runs/34779093372):
  20 raw and 20 stream records for device `4294969040`. Escape cookie 106 and
  Space cookie 109 each retain press/release edges. Hammerspoon counts keycodes
  53 and 49 once each, with zero errors, native AX focus, four privacy phases
  and settled cleanup. Report SHA-256:
  `7b2f70616262e38b71ca91f0d1b16102956e4e1dc4158385cf4bf71157ad2e42`.
- [Held run 34779280247](https://github.com/adrienm7/ergopti/actions/runs/34779280247):
  device `4294968843` has 263 readable elements; only Space cookie 109 is held.
  Its sampled timestamp is `8355748783`, query interval
  `8402757263..8402757332`. Following release request `8413802803`, the same
  cookie retains values 0/1/0 at `8413812489`, `8416099640`, `8418242016`.
  Report SHA-256:
  `1e05fda69f71fcfbe01deaacc385c95759060e91956ba5d6666cf67649d929da`.
  This mode has no Hammerspoon stream consumer and does not prove held-state
  handoff or exclusive physical accounting.

The subsequent frozen-state export is a portable preparation for paged handoff.
It copies each element's current value and observation frontier, rejects an
opening boundary before a query finishes, and preserves distinct cookies sharing
a usage. These native runs predate that export; they do not validate it.

## Queued element identity producer

Build [34773435230](https://github.com/adrienm7/ergopti/actions/runs/34773435230)
succeeded at `fdf68904fd4dd6a7d142a863b018084899c1163a`. It preserves native
element cookies in raw capture and stream records, before the upstream wrapper
discards identity. The independent raw/stream comparison includes those cookies;
historical fixtures retain explicit absence instead of fabricated identities.

The downloaded archive is 12,180,759 bytes, SHA-256
`b6dccdae1ac4d228860af07c94e5ecf69f682d1a03e7ee414c89616614b51930`.
All 13 retained headers match the owned source byte for byte. The three products
contain both x86_64 and arm64 slices; native strict signature verification passed
with ad hoc development signatures. The CLI reports `mach_absolute_time`,
numerator 125 and denominator 3. Upstream remains
`9312593e1a3bf72b94c63c524ebabe2637442e8a`.

Reuse this build for unchanged producer sources. The previous inventory build
does not emit queued cookies and cannot satisfy the new strict stream reader.
Compilation and portable regressions are proven; native remapping acceptance is
recorded below. This does not establish synchronized initial state, normal driver
ownership, or production packaging.

## Queued cookie native acceptance

[Run 34774654702](https://github.com/adrienm7/ergopti/actions/runs/34774654702)
used the verified cookie producer at consumer revision
`136b3190f74051ea5e27ba536273999222997421`. The remapping step succeeded;
the overall workflow failed its separate unprivileged, root and signed-remapper
capability probes. The remapping report contains no observation error.

All 20 raw records retain native cookies and match the fixture subsequence of
the stream exactly. The Escape pair uses cookie 106 and the Space pair cookie
109; both identities match the corresponding usages in the 263-element initial
inventory. Auxiliary records retain their own cookies as well. Hammerspoon
reports one physical Escape and one physical Space, actual native AX focus,
successful private/public/secure/resumed phases and settled shutdown. The
external target also exits zero and settles.

Replay the unmodified capture and wire records in
`tools/diagnostics/fixtures/hs274-native-cookie-capture.json` through
`hs274_stream_test.py`. The fixture retains report and stream hashes, the two
referenced keyboard inventory elements, and the consumer/target receipts.
The replay rejects an altered cookie even when usage, value and sequence match.
This is controlled virtual HID input on native macOS, not physical keyboard
hardware proof or synchronized initial-state ownership.

The same producer and consumer revision also passed the baseline remapping step
in [run 34775242687](https://github.com/adrienm7/ergopti/actions/runs/34775242687),
with Space initially held and explicit kernel state selection. The full readable
263-element inventory has exactly one held leaf: usage 44, cookie 109. All three
later Space edges retain that cookie, with values 0, 1 and 0; all 15 raw records
remain available. This baseline mode does not start the physical stream or the
Hammerspoon consumer, so it does not prove lease cutover behavior.

`tools/diagnostics/fixtures/hs274-native-cookie-held.json` retains the native
baseline probe, held inventory element and complete capture. Its replay in
`hs274_stream_test.py` preserves the initial release and rejects a missing fresh
press even after repairing capture length and sequence numbers. Use these two
cookie fixtures for subsequent state synchronization work instead of rebuilding
the unchanged producer or repeating inventory discovery.

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

## Paged baseline producer build

Native build [34783474637](https://github.com/adrienm7/ergopti/actions/runs/34783474637)
passed at source `79e9c73f6593fa8482030a68919e35f0812a5afd` on 2026-09-13.
Its archive is 12,214,762 bytes with SHA-256
`93c859dfcf29b9440acc706f3cf234558f73e17b2078f20d15d6b64a993a7d7e`.
The downloaded archive matches the retained checksum; all 16 retained headers
byte-match that producer source, including both new baseline transfer headers.
The upstream revision is `9312593e1a3bf72b94c63c524ebabe2637442e8a`.

All three executable archive members contain x86_64 and arm64 slices. Native
signature verification passed with ad hoc signatures; the CLI reported version
1, `mach_absolute_time`, numerator 125 and denominator 3. This is a reusable
development runtime, not a signed production distribution or input acceptance.
The native consumer workflow selects this exact archive because its Lua receiver
requires the paged baseline protocol. Earlier sampled-state archives cannot
serve that live receiver, although historical receipts remain replayable.

The interruption fixture must compare stable producer identity and the exact
next lease independently from its newly sampled baseline. Its new regression
rejects the original whole-envelope comparison; all 37 Python stream tests and
227 JS checks passed before committing that correction. Native input acceptance
of this producer, including inherited held state with Hammerspoon connected,
remains to be demonstrated.

## Paged baseline native acceptance

Run [34813132621](https://github.com/adrienm7/ergopti/actions/runs/34813132621)
used consumer `6021a96857298a0dee212b2802d3cc13a90ae475` and producer
34783474637 on 2026-09-14. Its actual Escape/Space input step succeeded;
the overall workflow failed in separate capability probes. The remap report has
SHA-256 `f5a1d03584d0e33536e52538d00ed59f98ad391de9431dadafee4ecc413639ac`
and no observation error.

Lease 2 transferred 496 rows in eight pages at boundary 9190302605, including
263 released elements on device 4294968848 and 231 on device 4294968018.
The completed baseline preceded 20 raw records matching the independent capture.
Native Hammerspoon credited Escape 53 once and Space 49 once, with zero errors,
trusted native AX focus, all four privacy probe phases, and settled consumer
and context ownership. Lease 3 acquired a distinct boundary, 9219332979, in the
same producer, completed its baseline, then reported explicit `interrupted` loss
when the fixture device closed.

`tools/diagnostics/fixtures/hs274-native-paged-baseline.json` retains both complete
wire streams, independent capture, Hammerspoon receipt and exact provenance.
The Python stream suite replays them, rejects removal of each individual page,
missing completion and unequal raw capture. Replay explicitly uses the archived
runner's UTC clock formatting; using the Windows host time zone incorrectly
rejects otherwise unchanged native application timestamps. All 38 targeted tests
pass, without requiring another macOS run.

This proves the paged protocol for the controlled released-input scenario. It
does not yet prove inherited held-state handoff with Hammerspoon connected,
ordinary driver integration or physical keyboard hardware.

## Held baseline with native Hammerspoon

Run [34814424933](https://github.com/adrienm7/ergopti/actions/runs/34814424933)
used consumer `31479fa99bb45e376485812856a96894eb76322d` and the unchanged
producer 34783474637. The modified HID fixture compiled on macOS and its actual
input step passed. Separate capability probes kept the overall workflow red.
The remap report has no observation error and SHA-256
`01b364ca19c9390e9d193b8aa577dda3f1fc9fba867b719cb596a8c101d7bc65`.

Lease 2 completed 496 baseline rows at boundary 8977339854. Device 4294968821
had 263 elements, with exactly Space usage 44/cookie 109 held, timestamp
8217178168. The other 231-element device had no held key. The fixture requested
release at 8982573430, after the transferred baseline. Its retained cookie 109
then delivered release at 8982618555, fresh press at 8984808892 and release at
8987086379. All 15 stream records match the independent raw capture.

Native Hammerspoon credited only keycode 49 once, with zero errors, trusted AX
focus, verified privacy transitions and settled consumer/context ownership.
The fixture confirmed drain release and metadata restoration. Lease 3 completed
its independent baseline at 9001695049 and reported explicit interrupted loss
when the device closed.

`tools/diagnostics/fixtures/hs274-native-held-consumer.json` retains the complete
consumer stream, raw capture, native input, kernel probe, Hammerspoon receipt and
provenance. The stream suite replays acquisition-before-release, exact raw input,
clock/context/privacy and the single fresh credit; missing fresh input and double
credit are rejected. All 40 targeted stream tests pass on Windows with archived
UTC formatting. Decode the retained raw probe through its reader: JSON object
keys in a previously decoded `held` map become strings on serialization.

This closes the controlled inherited-held-state handoff experiment. Ordinary
driver integration, broader device/key coverage and physical hardware validation
remain separate requirements; the producer still declares `fixture_only`.

## Eight native modifier sides

Run [34816149265](https://github.com/adrienm7/ergopti/actions/runs/34816149265)
used consumer `f1d2491eaf12bdfed39235bfcdded7b4124fff1c` and unchanged producer
34783474637. Native fixture compilation and actual input passed; separate
capability probes left the overall workflow red. The remap report has no
observation error and SHA-256
`b32f44a191b9a93e9813cd4f6b0f48197e4fb4828af7825e39dc157b9169a5eb`.

The fixture sent each of the eight modifier bits down/up independently, followed
by the unchanged Escape/Space collision pairs: 20 input reports and 20 observed
Quartz events. Each modifier's side keycode and aggregate flag edge passed the
native check. Baseline transfer completed 496 rows at boundary 14705213636.
All 52 raw records matched the delivered stream; modifier usages 224 through 231
used cookies 24 through 31, each with one down and one up. The duplicate-usage
array elements in this descriptor did not produce duplicate modifier credits in
this scenario. This evidence does not justify merging arbitrary cookie states.

Hammerspoon credited each modifier and Escape/Space exactly once: ten credits,
zero errors, verified clock/context/privacy, and settled consumer/context owners.
Drain release, metadata restoration and the successor's explicit interrupted
loss were confirmed. `tools/diagnostics/fixtures/hs274-native-modifier-consumer.json`
retains the complete stream, raw capture, Quartz and Hammerspoon receipts with
exact provenance. The modifier suite replays these and rejects every incomplete
prefix through the final trailing auxiliary row; its three tests pass locally.

Simultaneous modifiers, keyboard combinations, repeated reports, multiple active
keyboards and production integration still require their own evidence.

## Overlapping Shift and repeated HID reports

Run [34869741330](https://github.com/adrienm7/ergopti/actions/runs/34869741330)
used consumer `f9186f27f55f5e916fafef4d530343f845393188` and unchanged producer
34783474637. The actual remapping step passed without an observation error;
independent capability probes still leave the overall workflow red. Report SHA-256:
`0a2ffdee6107d5c41e500ecc47c336b5110d7cf9c9add090d735fbd86244db9e`.

The 26 HID reports produced 24 Quartz events. Both Shift sides were independently
pressed, the left side was released while the right remained held, and two
identical held-state reports introduced no extra Quartz press. All 62 raw rows,
including the repeated reports' auxiliary observations, matched the delivered
stream. Hammerspoon credited 12 physical presses: each Shift twice across the
independent and overlap scenarios, the six other modifiers once, and Escape and
Space once each. No consumer error or physical-Space loss occurred.

The 496-row baseline completed at boundary 4896173457; the successor completed
its baseline at 4961788765 before explicit interrupted loss. Clock, native AX
context, privacy transitions, consumer drain and metadata restoration passed.
All three suspended installed executables regained their exact permissions,
and the final runtime inventory was empty.

The first attempt, run 34868282852, preserved the same input but failed isolation
because the development agent launched the installed bundle's permission probe.
Its actual command was retained; it was never accepted as an isolation success.
The disposable executable fence now covers that independent launch route as well
as service registration, without changing the producer or signed HID provider.

`tools/diagnostics/fixtures/hs274-native-overlap-consumer.json` retains the full
raw capture, delivered stream, Quartz/Hammerspoon receipts and isolation evidence.
The shared modifier replay validates both native fixtures and every incomplete
stream prefix. This proves repeated HID report handling, not OS autorepeat;
keyboard combinations, multiple active keyboards, full mapping and production
integration still require validation.
