<!-- docs/audits/hammerspoon/2026_09_09/discoveries.md -->

# Hammerspoon investigation discoveries, 2026-09-09

This report preserves investigation evidence and continuation context at topic
commit `137bfbf2a4220c3ccc85d0c17e5d060721a543f4`. It supplements the immutable
[September 8 audit](../2026_09_08/report.md), not a new claim that all findings
are fixed. Check current Git history before using any historical task list.
Durable invariants are routed through [macOS memory](../../../memory/macos-hammerspoon.md).
Private `.rtk/` receipts cited below are supplementary local evidence; this
tracked report preserves the conclusions without requiring those ignored files.

## HS-274: reproduced bug and required safety property

At production commit `1a59e23f0`, the unchanged archived probes were replayed
in separate Lua processes from `static/ergopti_plus/macos`:

```text
lua ../../../docs/audits/hammerspoon/2026_09_08/proofs/duplicate-count.lua
lua ../../../docs/audits/hammerspoon/2026_09_08/proofs/physical-collision.lua
```

The first exited 1 at `remapped output double-counted`: ordinary output=1,
physical=nil; managed output=1, physical=1. The second exited 0 with
physical_space_count=1. No production patch was applied for these observations.

The keylogger expression `condition and nil or keycode` always retains keycode.
Replacing it with global suppression of managed output codes is nevertheless
incorrect. With Escape tap=Space/hold=none and Space tap=none/hold=none, code 49
is a managed output but also a real physical Space. The generator's none/none
path re-emits the original key and tracks its held variable without producing
a physical ledger entry. The archived rejected patch loses that physical input.

The existing shell ledger contains a physical name, or `U:name` for release;
there is no identity shared with the separate Quartz output. Timing, PID,
arrival order, counters, and static generation tokens cannot establish that
identity. A correction needs exact output ownership or a complete authoritative
physical stream while normal remapping continues. Preserve logical text and
non-synthetic classification as well as physical counts. Required coverage
includes passthrough, mixed slots, combos, modifiers, repeats, paused/private
capture, leases, delayed delivery, teardown, and multiple keyboards. Measure
native overhead before introducing a replacement transport.

## Producer capabilities and rejected shortcuts

### EventViewer capture changes the behavior being observed

Reviewed upstream Karabiner-Elements at
`9312593e1a3bf72b94c63c524ebabe2637442e8a`; this is an upstream snapshot, not the
user's installed version. Source paths below are relative to that tree:

- `src/apps/EventViewer/src/EventHistory.swift` receives device ID, usage page,
  usage, and integer value. This alone does not prove passive acquisition.
- `CaptureCoordinator.swift` in the same directory explicitly disables
  remapping temporarily on the selected raw-capture device.
- `EVCoreServiceDaemonClient.swift` calls `krbn_set_hid_capture_target` through
  `TemporarilyIgnoredDeviceManager`.
- `event_viewer.cpp` closes old monitors before `async_temporarily_ignore_device`:
  an ownership handoff, not a subscription to the remapper's active stream.
- `src/share/hid_device_events_monitor.hpp` implements IOHID acquisition,
  device-specific reports and timestamp normalization, not a public passive feed.

Do not build a runtime physical ledger from EventViewer raw capture on the
assumption that normal remapping remains active.
[Pinned source tree](https://github.com/pqrs-org/Karabiner-Elements/tree/9312593e1a3bf72b94c63c524ebabe2637442e8a).

### Datagram transport does not supply provenance

`to.send_user_command` was introduced in Karabiner 16.0.0, May 3, 2026.
Its default UNIX datagram endpoint is
`/Library/Application Support/org.pqrs/tmp/user/{UID}/user_command_receiver.sock`;
custom endpoints are supported. The pinned
`src/apps/ConsoleUserServer/include/console_user_server/send_user_command_handler.hpp`
serializes configured payload, queues Asio work, and calls `send_to` with a
32 KiB send buffer. Failure is logged; there is no acknowledgement, retry,
or automatically added per-event identity. `operation_type.hpp` does not offer
a general physical-key subscription; `to_event_definition.hpp` accepts the
command event type.
[Command documentation](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/to/send-user-command/),
[release notes](https://karabiner-elements.pqrs.org/docs/releasenotes/#karabiner-elements-1600).

A generation token can reject a stale datagram but cannot label a separately
posted Quartz event. Before using this transport as an accounting authority,
prove complete coverage, loss/disconnection handling, event-time capture and
lease ownership, installed-version support, and native pressure/latency costs.

### A generic first rule blocks later remapping

The documented `from.any` plus `to.from_event` pattern disables subsequent
Complex Modifications; it implements pass-through mode. Prepending a generic
logger using that pattern would block Ergopti and foreign rules. A trailing
logger misses consumed events. Simple Modifications run before Complex
Modifications, and instrumenting only owned rules is not exhaustive.
[from_event contract](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/to/from-event/),
[processing order](https://karabiner-elements.pqrs.org/docs/manual/misc/event-modification-chaining/).
No such rule was installed or used to modify foreign configuration.

### Virtual sender identity is not original physical identity

Mac Mouse Fix at `d55a88324a0c8d4176e2d7550be39b1db7287d85` uses undocumented
Quartz field 87 in `Shared/Constants.h` and `Helper/Utility/EventUtility.m` to
resolve a sender through IOKit. Its `Shared/IOKit/CGEventHIDEventBridge.{h,m}`
also explores private HID bridges. This is evidence for a mouse technique,
not a verified keyboard/Karabiner contract. Both remapped Escape and passthrough
physical Space can leave through the same Karabiner virtual keyboard, so even
reliable virtual-device identity does not resolve the collision. No third-party
implementation, private memory-offset writes, or field-87 production code was
copied into Ergopti.
[Pinned source tree](https://github.com/noah-nuebling/mac-mouse-fix/tree/d55a88324a0c8d4176e2d7550be39b1db7287d85).

## Real macOS GitHub Actions evidence

The user has no personal Mac and requested hosted macOS verification. The
feature branch was published for this purpose; neither dev nor main was pushed.
The experimental commits below have not been integrated into dev at this
snapshot. They contain no HS-274 production correction.

| Commit | Native run | Outcome |
| --- | --- | --- |
| `faae7627c` | [34393307118](https://github.com/adrienm7/ergopti/actions/runs/34393307118) | Swift compilation failed; no native observation. |
| `f6b4037cc` | [34393997495](https://github.com/adrienm7/ergopti/actions/runs/34393997495) | Correct initializer compiled; marker assertion failed before detailed receipts. |
| `60ee54168` | [34394901173](https://github.com/adrienm7/ergopti/actions/runs/34394901173) | Detailed Quartz observations saved; serialization assertions failed. |
| `137bfbf2a` | [34396530965](https://github.com/adrienm7/ergopti/actions/runs/34396530965) | C probe compiled and HID refusal diagnosed; Quartz assertions kept the overall job red. |

The tracked owners are `.github/workflows/hs274-native.yml`,
`tools/diagnostics/hs274-native.swift`, and
`tools/diagnostics/hs274-hid-device.c`. Each published version passed its
selected local verify-change gate with 223 JS checks. Native compilation and
execution occurred on Actions, not in the Windows Lua stubs. These local green
checks do not turn the native experimental failures into passing regressions.

### Quartz: native access works, serialized tags do not survive

Run 34394901173 used macOS 15.7.9, build 24G830. Both UID 501 and root UID 0
had listen/post access and observed the owned tagged Quartz key-down through
a real event tap. Nil, HID, combined, and private sources all retained marker
1163020111, keycode 49 and event type 10 in original and copied events.
All four decoded variants retained keycode/type but lost the marker to zero;
private/HID source state also became zero. Each process attempted 36
comparisons: 32 matched, four decoded-marker comparisons failed.

The correct Swift initializer is `CGEvent(withDataAllocator:data:)`.
Hammerspoon 1.1.1's `extensions/eventtap/libeventtap_event.m` uses the private
source, so that variant matters. A driver search found no production
`asData`/`newEventFromData` call: this serialization result is not an identified
production bug in Ergopti. The probe emits paired key-down/up events and
consumes only its owned marker, with bounded capture and cleanup.

This establishes real Quartz execution on a hosted Mac. It does not establish
physical keyboard input or Karabiner virtual-HID provenance. Receipts retain
`physical_keyboard_validated=false`, `karabiner_virtual_hid_validated=false`,
and `hs274_fixed=false`. Do not return to a blanket "no Mac" blocker, and do
not weaken these experimental assertions merely to make the job green.

### HID: an ordinary probe is refused even as root

Run 34396530965 compiled the C probe with `-Wall -Wextra -Werror`.
Both normal and sudo invocations returned `virtual_device_created=false` and
`input_reports_sent=0`. Filtered kernel logs contain two
`IOHIDResourceDeviceUserClient` diagnostics: `hs274-hid-device is not entitled`.
This is native evidence of the entitlement refusal, not speculation based only
on a null handle. The acquisition probe sends no input reports.

Apple's inspected `IOHIDResourceDeviceUserClient::initWithTask` requires either
`com.apple.hid.manager.user-access-device` or
`com.apple.developer.hid.virtual.device`, with no root exemption in that code.
[Apple source](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDResourceUserClient.cpp).
This does not prove that an existing signed virtual-HID provider cannot work.

Local downloaded receipts are under `.rtk/hs274-native-run-34394901173/` and
`.rtk/hs274-native-run-34396530965/`. Local gate logs are
`.rtk/hs274-native-validation-final.log`,
`.rtk/hs274-native-initializer-validation.log`,
`.rtk/hs274-native-traces-validation.log`, and `.rtk/hs274-hid-validation.log`.
The observations above remain useful after those ignored files or remote
artifacts expire.

## Signed provider follow-up: installation passed, approval pending

The official signed Karabiner-DriverKit-VirtualHIDDevice provider was tested
on a disposable Actions runner. Release v8.5.0 was inspected; its package is
2,089,117 bytes, SHA-256
`d73d6d9428f0f80b87b8a8ba8a1031f2cbc3bc1fa6b74842d1f1b764b2916fc9`,
with tag tree `bdfcb459b2eaca8ccda680a73b0dc898f330f4bb`.
[Official release](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/tag/v8.5.0).

Commit `795ffd1d76166e1c452fa42a07fb39862f3f24de` added
`tools/diagnostics/hs274-provider.py` and the installation/activation workflow
steps. Local Python syntax and all 223 selected JS checks passed. The pinned
package postinstall and Manager App/ExtensionManager/OneShot sources were read
before execution. Postinstall restarts an existing provider daemon; the Manager
waits on an OS delegate, with no internal approval timeout. Its zero exit can
also mean completion after reboot, so the probe checks actual extension state.

[Run 34399357327](https://github.com/adrienm7/ergopti/actions/runs/34399357327)
verified the pinned SHA-256, verified the package signature, and installed it
successfully. `pkgutil` reported a trusted Apple notarization and Developer ID
Installer Fumihiko Takayama, team `G43BCU2T37`. Before activation there were no
system extensions. The Manager did not exit within the external 45-second
limit; the probe killed and reaped that exact process. The resulting state was:

```text
org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0)
[activated waiting for user]
```

The extension was not `[activated enabled]`. The receipt records
`activation_timed_out=true`, `activation_exit=null`,
`extension_activated_and_enabled=false`, and `input_reports_sent=0`.
The overall job failed, with both the original Quartz assertions and the new
activation observation red; artifact upload succeeded. Downloaded evidence is
under `.rtk/hs274-native-run-34399357327/`, with the selected local gate receipt
at `.rtk/hs274-provider-validation.log`.

This distinguishes system approval from the unsigned C probe's entitlement
refusal. Do not repeat installation alone or assume sudo grants that approval.
An approved activation route on a hosted runner has not been established;
the runner's UI automation capability has not been tested. No SIP, TCC, or
signing bypass was attempted. Even successful activation would establish only
a test capability, not original physical provenance or an HS-274 correction.

An older private 15-second, 64-event passive Hammerspoon probe was prepared
for physical Escape/Space but never executed. Its callback arrival timestamps
are not identities. The user has already explained personal hardware is
unavailable; do not restart that clarification loop.

### Normal approval interface observation

Runner-image source at `5b925cc19141e53ef8af6789f8a9de5e14bdf8a1` preconfigures
Accessibility and System Events AppleEvents access for `/usr/bin/osascript`.
This motivated normal UI observation, not a runtime TCC database edit.
[Pinned image configuration](https://github.com/actions/runner-images/blob/5b925cc19141e53ef8af6789f8a9de5e14bdf8a1/images/macos/scripts/build/configure-tccdb-macos.sh).

Commit `d2402105992380719201b1678fc57104c958bf50` passed all 223 selected local
JS checks. Its [run 34400795410](https://github.com/adrienm7/ergopti/actions/runs/34400795410)
installed the provider, then again reached approval timeout. Opening
`x-apple.systempreferences:com.apple.LoginItems-Settings.extension` and taking
a screenshot both exited zero. System Events enumeration of the Settings
window's entire contents failed with AppleEvent error `-10000`; this is not
evidence of an Accessibility permission denial.

The downloaded screenshot was visually inspected. It shows Login Items &
Extensions behind a notification naming Karabiner-VirtualHIDDevice-Manager,
with `OK` and `Open System Settings` buttons. No approval was performed in
that run, and the job remains failure. Artifacts are retained locally in
`.rtk/hs274-native-run-34400795410/`; the local gate receipt is
`.rtk/hs274-provider-ui-validation.log`.

The next diagnostic separates the notification owner from System Settings and
retries a bounded tree read after bringing Settings forward. Any notification
interaction must find the exact provider name and exactly one named navigation
button in the same window; broad clicks or guessed screen coordinates are not
an established approval route. Reading the Settings tree, navigating to the
panel, enabling the provider, and proving native event provenance remain
separate checks.

Commit `041f5446aa5bbd099eebdc628a7ee9acd86287e4` passed the 223 selected
local JS checks. [Run 34401783669](https://github.com/adrienm7/ergopti/actions/runs/34401783669)
then identified the provider notification in `UserNotificationCenter`, verified
its exact provider text and unique `Open System Settings` button, and pressed
that button through AXPress. The retained screenshot confirms the notification
disappeared and Login Items & Extensions became the foreground panel. This
proves normal UI navigation using existing runner permissions, not provider
approval. Its extension state was recorded before that navigation.

The Settings-tree error persisted at AppleScript offsets `311:315`. Extracting
the actual embedded script through Python AST maps those offsets exactly to
`rows` in `set rows to ""`. The initial failure likewise occurred at that name,
not at the tree enumeration. `rows` collides with System Events terminology
inside its tell block. The next correction renames that local report accumulator
to `observationText`; a native rerun must verify the diagnosis. The other
readiness guards are retained. Do not infer an AX permission restriction from
this diagnostic-script failure.

Local artifacts: `.rtk/hs274-native-run-34401783669/`. Local selected gate:
`.rtk/hs274-provider-notification-validation.log`. The overall native job is
still failure; this pass sent no input reports and did not enable the provider.

Commit `e47efd76ce10af33808a5b4c8fda190c6b60a3ec` passed 223 selected local
JS checks. [Run 34403189433](https://github.com/adrienm7/ergopti/actions/runs/34403189433)
no longer failed on the `rows` assignment, confirming that correction. The
notification navigation again passed. The tree read reached the node loop,
then failed with coercion error `-1700` at item 19 (the Wi-Fi sidebar element).
The exception included the actual window element references, including the
Driver Extensions label, the exact Karabiner bundle label, and its following
button in the extensions group. This is evidence of a readable Settings tree,
not a complete passing UI observation or proof that every cached node stays
valid while Settings updates.

Use the observed right-pane extensions group and assert both labels before
acting. Do not enumerate the unrelated sidebar merely to find the provider's
details. Select exactly one button immediately following the exact provider
label; retain refusal if that observed structure changes. The current bounded
diagnostic opens those details but still does not enable a provider checkbox.
Receipt directory: `.rtk/hs274-native-run-34403189433/`; local gate:
`.rtk/hs274-provider-terminology-validation.log`. Native overall conclusion
remains failure, and physical provenance remains unvalidated.

Commit `0b7699b21cb055ac0e66091545aabe5f44d22940` passed 223 selected local
JS checks. [Run 34404407048](https://github.com/adrienm7/ergopti/actions/runs/34404407048)
successfully read the scoped extensions group and pressed the unique details
button immediately following the exact Karabiner bundle label. All five UI
commands exited zero, including the screenshot. The visually inspected image
shows the Driver Extensions sheet with exactly one disabled provider toggle,
its Karabiner bundle label, a details menu and Done. This supplies a concrete
normal UI target for the next bounded activation attempt. It does not prove
activation: the overall job remains failure and the provider was not enabled.
Artifacts: `.rtk/hs274-native-run-34404407048/`; local gate:
`.rtk/hs274-provider-details-validation.log`.

The following attempt must verify the sheet title and exact provider label,
require exactly one checkbox, and press only a disabled checkbox. Re-read
`systemextensionsctl` after the UI action with a bounded wait. The pre-UI
extension state cannot establish the result of an approval performed later.
Retain any authentication prompt as evidence; do not infer activation from a
successful AXPress or silently alter system security settings.

Commit `a92f2d0e7e50165ffe5cf578482fe5e13b75c6c8` passed the three exact-provider
state controls and all 223 selected JS checks. Its
[run 34405918856](https://github.com/adrienm7/ergopti/actions/runs/34405918856)
verified the Driver Extensions sheet, exact bundle label and unique disabled
checkbox. AXPress returned successfully and the diagnostic recorded
`Requested verified provider activation`. All five UI commands exited zero.
Nevertheless, polling actual extension state for ten seconds still returned
`[activated waiting for user]`; `extension_activated_and_enabled` stayed false.
The screenshot was inspected and still shows the disabled toggle, with no
authentication dialog visible. This is an unaccepted activation request, not
proof of approval or a demonstrated missing-password requirement.

No synthetic UI operation here validates physical keyboard provenance. The
overall native job remains failure, `hs274_fixed=false`, and no HID input
reports were sent. Local evidence is in
`.rtk/hs274-native-run-34405918856/`, with local validation at
`.rtk/hs274-provider-enable-validation.log`.

Next inspect the checkbox's actual enabled/action state and native diagnostics
around the attempted activation. A possible differential experiment is a normal
Quartz pointer click bound to the same verified control's current AX geometry;
it has not been attempted and must not use guessed coordinates or be called
physical input. Do not repeat AXPress and infer success from its return value.
The normal approval route remains incomplete, independently of the still
unsolved authoritative physical-event producer design.

Commit `edf454cc15408c3719dc022889e55549ccda221c` preserved the activation
request process through the approval attempt, keeping the same initial
45-second wait. Three local real-child lifetime checks covered normal consumer
work, consumer failure cleanup, and natural process exit; 223 selected JS
checks passed. [Run 34407750828](https://github.com/adrienm7/ergopti/actions/runs/34407750828)
recorded `activation_owner_alive_before_ui=true`, `checkbox_enabled=true`,
and `checkbox_value_before=0`. AXPress still left native state waiting for user
approval. Only after the observation did cleanup terminate and reap the owner
(exit -15, `activation_forced_cleanup=true`). Thus keeping the requester alive
did not resolve the refusal. Do not repeat that hypothesis as the explanation.
Receipts: `.rtk/hs274-native-run-34407750828/` and
`.rtk/hs274-provider-owner-validation.log`.

The next differential probe replaces only the provider checkbox's AXPress
with a synthetic Quartz mouse pair at the center of its freshly read AX
geometry. The verified sheet, exact bundle label, unique enabled checkbox and
live activation owner remain required. Finite coordinates, positive dimensions,
posting access and the primary display boundary are checked before dispatch.
Navigation buttons still use the established AX route. This is not a physical
input test; `CGEventPost` supplies no acknowledgement of UI acceptance, so
post-action native extension state remains authoritative.

### Authentication boundary reached on 2026-09-10

Commit `8d4d8be8b3ee8a5832f84264340319b2b4682f92` passed 223 selected JS
checks. [Run 34408840351](https://github.com/adrienm7/ergopti/actions/runs/34408840351)
compiled the C mouse probe with warnings treated as errors. AX returned the
verified control bounds `(668, 264, 26, 15)`; the helper posted a synthetic
mouse pair at its center. The screenshot was visually inspected and shows a
System Extensions administrator-password prompt, prefilled with the runner's
existing account name Anka. Thus Quartz reached authentication where AXPress
had left the toggle unchanged. No password was supplied in that run. Native
state remained waiting for user approval; the request owner was kept alive
until cleanup and then reaped with exit -15. The overall job remains failure.
Artifacts: `.rtk/hs274-native-run-34408840351/`; local gate:
`.rtk/hs274-provider-quartz-validation.log`.

The following experiment uses a unique temporary administrator on the disposable
runner and normal System Extensions authentication. Its generated password is
masked in Actions logs and redacted from command receipts. Verify the account's
home identity, admin membership and credentials before use; retain it through
native-state observation, then verify account removal. Its isolated home stays
under RUNNER_TEMP until VM disposal. Do not read, guess or reset an existing
account's credentials. This setup still supplies neither a complete physical
producer nor an HS-274 production correction.

## Delivered work: history pointers to avoid duplicate fixes

These are historical references, not a substitute for checking current Git.
All fixes through `1a59e23f0` had been integrated locally into dev before the
native capability experiments. Full receipts remain in their commits and local
`.rtk/` files; no claim of complete module correctness follows from them.

| Commit | Area and regression evidence |
| --- | --- |
| `1a59e23f0` | Tooltip publication callback ownership; 72 cases, 66 failed before fix; HS 9931/1151, E2E 67/67 with one skip. |
| `e53a4686b` | Retry failed tooltip dependency acquisition; 10 cases, five failed before fix; HS 9859/1150 plus JS/E2E. |
| `d48756426` | Isolated native tooltip renderer fixture; two actual scope guards fail when restoration is removed; HS 9849/1149. |
| `9fdd4773d` | Canonical tooltip facade shared with adapter; three original failures; HS 9847/1148 plus JS/E2E. |
| `31a280073` | Typing cache/publication scopes including real transitive modules, io.open and os.remove; old guards failed; HS 9844/1147. |
| `0dabfd0b6` | Shared typing dashboard scenario scope; 16 timer/delivery scenarios preserved; HS 9844/1147. |
| `8fe011be1` | Canonical typing dashboard runtime across restore/keylogger/menu; four regressions; HS 9842/1146 plus E2E. |
| `e59b7129e` | Exact UI-restore storage read/delete committed before reopen; five cases; HS 9838/1145. |
| `1c8830d0b` | UI-restore fixture construction/native/window cache isolation; 15 cases; HS 9833/1144. |
| `7153c5a0d` | Exact menu watcher paths instead of substring matching; eight cases; HS 9818. |
| `8427e4821` | Ignored directory exact/descendant boundary; two cases; HS 9810. |
| `38a5cefcc` | Menu config watcher fixture; nine scope guards and 12 preserved scenarios; HS 9808. |
| `b74daa2a4` | Git/bulk watcher fixture isolation; HS 9799. |

Earlier delivered work includes boot watcher `b9ec0eb99`, self-write watcher
`9a7b220f8`, pause fixture `e92bfd83c`, profile shortcuts `53a1ade52`, profile
delete fixture `64d279337`, onboarding split `6d37cd759` and fixture
`f56c66148`, gesture split `ac75d1a55` and fixture `e78770abe`, source-read
inventory `5b6674a7a`, concat scanner `28f243826`, and Karabiner guard split
`ebaa805e4`. The `--only` selector correction `8be24a1ae` is already delivered;
the historical resume instruction listing it as pending is stale. Historical
HS-267 through HS-273 must likewise be checked against their delivered commits.

## Test isolation and investigation pitfalls

- `helpers.with_fresh_modules` restores exact nil/false/table state but does
  not itself clear modules. `with_stub_scope` journals loader writes, not all
  real require publications; explicitly own real transitive consumers.
- Native consumers may capture `hs` at require time. Reload every such consumer
  during fixture construction. Compare identities with `rawequal`; deep table
  formatting can overflow on cyclic native/module graphs.
- Use the official absolute package paths and `ModuleIsolation.purge` between
  test modules. Relative paths can make config resolve `./_shared` incorrectly.
  Compare unpurged replay failures against baseline before blaming a new fix.
- Stateful `.init` aliases can execute independent facade state despite shared
  low-level modules. This affected both tooltip and typing dashboard ownership.
- A callback or diagnostic sink can publish a successor. Recheck exact ownership
  after both; an older callback must not hide the successor.
- `pcall` success does not mean native acceptance when the result is false/nil.
  A zero-violation source ratchet is not semantic regression proof.
- Final tooltip replay covered eight modules/246 cases, both unpurged forward
  and official-purge reverse. Earlier 164/174 totals describe earlier snapshots.
  Typing consumer replay covered 17 modules/146 cases in both orders.

## Rejected measurements and unqualified hypotheses

The UI-restore defer reentrancy source test is not demonstrated redundant.
A globalized local-latch mutant failed it while all ten behavior cases passed;
other mutations were caught by behavior cases but missed by the source test.
The local probe was `.rtk/probe-ui-restore-meta-overlap.lua`.

Deferred watcher old-callback/new-burst/stop probes all passed (three controls).
No bug was qualified. Menu `reset_menubar` only changes icon/title; stopping
watchers belongs to termination. Project `hs.reload` goes through the
TerminationCoordinator, so its accepted true result must not be confused with
the raw native API. APFS case and symlink watcher hypotheses remain unproven.

MLX compilation reuse increased root peak RAM from about 8.7-8.9 MiB to
14.6-14.9 MiB across 49 cases and was rejected in `c19992184`; see the
[recorded performance report](../../performance/hammerspoon/2026_09_09/mlx_test_compilation/report.md)
and [rejected proposals](../../../memory/rejected_proposals.md).
The JSON span optimization's benefit disappeared when run order was reversed.
Missing-lfs search measurements (49 loads, 1.202 versus 0.820 seconds) do not
authorize negative caching without a dynamic-path/files contract. The concat
scanner's roughly 7.3% small Karabiner sample gain is not a whole-suite or
whole-PC RAM claim. Windows `os.clock` is not the CPU measure used here;
measure root TotalProcessorTime and live PeakWorkingSet64, and separate AHK
activity before attributing machine load to Hammerspoon.

A tooltip standard/stacked publication interruption hypothesis was paused when
HS-274 became the priority. Inspect real TooltipHotstring/Renderer commit
boundaries before calling it a bug: fake rendering after hide is not proof,
and existing native commit guards may already fence it. The watcher fixture
owns `ui.tooltip.init`, not canonical `ui.tooltip`; an experiment using the
canonical facade needs an outer owned module scope. Compare existing facade
ownership, renderer native commit, streaming UI commit, and prediction reset
tests before adding duplicates. No production changes were made for this lead.

## Continuation discipline specific to this campaign

An independent AHK agent can start a gate between observations. Check live
processes immediately before edits and gates; bounded waiters were used to
avoid competing heavy suites. One early small native-probe pairing edit raced
with an AHK start; the next gate correctly refused and later work waited for
idle. Do not kill foreign processes or infer Hammerspoon RAM use from AHK load.

Read Git state afresh in both worktrees. Preserve the four native experimental
commits as experiments until the production correction has its own evidence.
The last inspected main commit was `3e460adf4`; it may have advanced. Rebase
against an inspected pinned SHA and use a guarded fast-forward only when clean.
Do not push release branches or rewrite another agent's state.

For GitHub JSON on Windows, invoke raw `gh` and parse with ConvertFrom-Json:
the RTK PowerShell wrapper can split comma-separated `--json` arguments.
Use RTK for human-readable output, never for parser input. Check the actual
Actions conclusion; successful artifact upload or an isolated successful step
does not make the overall job green.
