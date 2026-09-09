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

## Next experiment, prepared but not executed

Investigate the official signed Karabiner-DriverKit-VirtualHIDDevice provider
on a disposable Actions runner. Release v8.5.0 was inspected; its package is
2,089,117 bytes, SHA-256
`d73d6d9428f0f80b87b8a8ba8a1031f2cbc3bc1fa6b74842d1f1b764b2916fc9`,
with tag tree `bdfcb459b2eaca8ccda680a73b0dc898f330f4bb`.
[Official release](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/tag/v8.5.0).

Before installing, inspect the pinned package postinstall and Manager Swift
activation code. Verify the package hash and signature, bound activation time,
retain system-extension status and logs, and clean up only owned processes.
The README documents Manager `activate`, then the root VirtualHIDDevice daemon
and a root client. Do not bypass SIP, TCC, or signing. No package was installed
in this investigation. Successful activation would establish a test capability,
not solve producer identity or prove the HS-274 correction by itself.

An older private 15-second, 64-event passive Hammerspoon probe was prepared
for physical Escape/Space but never executed. Its callback arrival timestamps
are not identities. The user has already explained personal hardware is
unavailable; do not restart that clarification loop.

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
