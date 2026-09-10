<!-- docs/audits/hammerspoon/2026_09_09/producer-contract.md -->

# HS-274 producer contract proposal

Status: investigation proposal, not an implemented interface or production fix.
No upstream issue, pull request or external message has been submitted.

## Evidence and scope

[Native run 34416730491](https://github.com/adrienm7/ergopti/actions/runs/34416730491)
and its post-rebase repeat
[34418176002](https://github.com/adrienm7/ergopti/actions/runs/34418176002)
both passed the actual remapping fixture. A controlled Escape tap and a separate
Space tap both produced Space down/up through the same Karabiner output device,
with identical observed keycode, user-data, PID and numeric-field-87 values.
Only Escape appeared in the shell ledger. All controlled configuration,
metadata and supervised-process cleanup checks passed.

This disproves classifying the two origins by those output fields. It does not
prove that every conceivable native integration is impossible. Full run results
remain failure for the separately retained Quartz serialization and Launch
Services permission checks. The fixture is virtual; physical hardware and native
Hammerspoon execution have not been validated.

## Required information

The preferred boundary is an opt-in physical event stream from the remapper,
before Simple and Complex Modifications. Logical text remains on the existing
Hammerspoon path. Physical counts must have one authoritative source while its
coverage is proven; adding a second stream to the existing credits would repeat
the original bug.

The stream needs these explicit fields and transitions:

- A negotiated protocol version, producer epoch and monotonically increasing
  sequence number. An epoch change cannot silently reuse old held-key state.
- Device identity, HID usage page/usage, event edge/value and original monotonic
  event timestamp. Arrival time at the consumer is not the event timestamp.
- A device inventory and coverage state, including ignored/unseized keyboards,
  connection/removal and unsupported input paths. Observing only matched Ergopti
  manipulators is not complete physical coverage.
- Subscription start/stop, initial held-key state, disconnect and explicit gap
  detection. Overflow or a slow reader must neither stall key delivery nor claim
  that every event was delivered.
- Capture lease ownership and privacy/disabled-session handling. No old buffered
  event may become a fresh physical press after pause, restart or lease change.

These are proposed semantics, not commands currently supported by Karabiner.
An official CLI streaming command could broker the existing signed IPC boundary
and let Hammerspoon consume a supervised stdout stream without another native
module. Its authentication, lifetime and backpressure contracts still need an
implementation and verification.

## Source integration points and cautions

The inspected upstream revision is Karabiner-Elements 16.3.0,
`9312593e1a3bf72b94c63c524ebabe2637442e8a`.

`device_grabber::hid_values_arrived` receives original device IDs, timestamps,
events and edges before it copies entries into `merged_input_event_queue_`.
This is a concrete place to investigate publication. Instrumenting only the
existing enabled/seized branch would omit ignored keyboards and is therefore
not a complete implementation of the proposed contract.

`codesign_manager::same_team_id` explicitly supports processes without a verified
Team ID. Both `core_service_daemon_client::async_start` and the daemon's
`receiver` constructor use it to authenticate the peer. A signed stock client
therefore rejects an ad hoc development daemon even though the daemon accepts
that client. Build the core, ConsoleUserServer and CLI together for a disposable
prototype; do not remove the upstream authentication checks. Their XcodeGen
projects already select ad hoc signing (`CODE_SIGN_IDENTITY: '-'`). This is not
a signed, supported production package.

The pinned upstream CI uses macOS 15, Xcode 26.0, recursive submodules and
XcodeGen. Component Makefiles check two signing environment variables, update
version resources, build the shared Duktape library, generate the Xcode project
and invoke `xcodebuild`. The investigation workflow
`.github/workflows/hs274-producer-build.yml` prepares shared inputs once and
builds only those three components sequentially with two compiler jobs. It
retains verified build products and signatures without installing or launching
them. A successful build establishes compiler feasibility only: IPC, input
permissions, signed provider interoperability and complete physical delivery
still require native execution with the eventual producer implementation.

Ordinary parallel IOHID observers cannot simply be assumed to survive seizure:
Apple's inspected user-client implementation disables their queues. Forcing
Karabiner's Quartz fallback is also not equivalent: its queue entries use device
ID zero, so original per-device conditions and overlapping device state cannot
be assumed preserved. Do not change the user's remapping mode to make this
accounting test pass.

## Acceptance evidence before a production change

1. Demonstrate complete, ordered physical delivery while the real remapper keeps
   its behavior, including remapped/passthrough keys, mixed slots, modifiers,
   combos, repeat policy, ignored devices and multiple keyboards.
2. Make the original duplicate-count reproduction fail before the consumer fix
   and pass afterward; keep the physical-Space collision proof passing. Preserve
   logical text and nonsynthetic classification independently of physical credit.
3. Exercise partial reads, consumer exceptions, sequence gaps, stale epochs,
   pause/privacy boundaries, teardown and successor ownership with isolated
   shared fixtures. Unsupported coverage must be explicit, not a false success.
4. Measure native input latency and producer/consumer CPU and memory with and
   without the stream, using paired and reversed runs. Logging must not add an
   unbounded queue or block the input callback.
5. Validate the actual Hammerspoon consumer on macOS. Windows fixtures and a
   virtual input source do not replace the remaining native/hardware evidence.

The development build succeeded in
[run 34420100132](https://github.com/adrienm7/ergopti/actions/runs/34420100132).
The native observation workflow now offers an explicit `development_build`
dispatch input. It reuses that exact artifact, verifies its independently
recorded archive hash and all three signatures, and selects the core, console
server and CLI together. An incomplete artifact fails instead of falling back
to installed official peers. Native observation is dispatch-only to avoid
repeating costly installations on unrelated feature pushes.

The isolated development runtime passed its actual remapping step in
[run 34431487246](https://github.com/adrienm7/ergopti/actions/runs/34431487246).
Direct native permissions were granted; expected development peers were present
during input and absent after cleanup. Both fixture key pairs were preserved.
The overall workflow still failed its independent Quartz serialization and
Launch Services permission checks. This remains virtual-input evidence, not
hardware or native Hammerspoon validation.

Upstream startup re-registers installed service-manager applications, undoing
a one-shot launchctl disable. The isolated CI fixture temporarily removes the
two registration helpers' execute bits, verifies native refusal, then restores
their exact modes after stopping its processes. Raw service states and executable
inventories verify the scope. No authentication check or signed HID provider
executable is changed.

The next build can explicitly opt into a bounded capture of the named fixture
through `raw_capture`. Instrumentation targets
`hid_device_events_monitor::input_values_arrived` before timestamp normalization;
the later entry callback already receives normalized timestamps. Records preserve
optional usage metadata and original decoded HID timestamps. An append-only
memory buffer publishes an immutable prefix; overflow and unexpected concurrent
writers are counted, and output occurs at shutdown, outside input callbacks.
This is a finite observation with fixture-only coverage, not a physical-stream
interface. No production consumer or modified production dependency is selected.

The instrumented build passed native compilation, portable capture tests and
signature verification in
[run 34433549314](https://github.com/adrienm7/ergopti/actions/runs/34433549314).
The development observation now selects that exact checksum-verified artifact
and requires a lossless physical capture from the core-daemon log after cleanup,
independently of the retained Quartz/ledger checks. The first instrumented
[runtime observation](https://github.com/adrienm7/ergopti/actions/runs/34435298332)
preserved remapping and cleanup but produced no capture receipt: the core exited
by SIGTERM before its normal return. This does not establish an empty capture.

A lightweight [shutdown reproduction](https://github.com/adrienm7/ergopti/actions/runs/34436249873)
passed all three direct children but interrupted all three sudo children. The
upstream signal monitor restores default handlers after the first termination
signal, so another signal can abort its graceful shutdown. The supervisor now
sends initial TERM only to the sudo leader for forwarding; direct processes
still receive a group signal, and timeout escalation still targets the group.
The [native shutdown replay](https://github.com/adrienm7/ergopti/actions/runs/34436643337)
passed all six direct/sudo cases after this change.

The next [instrumented runtime](https://github.com/adrienm7/ergopti/actions/runs/34436745312)
exited the daemon normally and emitted 20 records with zero overflow/contention.
Both remapped output pairs and the exact Escape ledger were preserved; runtime
inventory was empty after cleanup. The original capture verdict was too strict:
page 7 also contained auxiliary usage -1 elements and inactive usage 1 states.
The [USB HID usage table](https://www.usb.org/sites/default/files/hut1_21_0.pdf)
defines keyboard usages 1, 2 and 3 as error conditions, not ordinary keys.

`tools/diagnostics/fixtures/hs274-native-capture.json` preserves all 20 decoded
records from that run without changing values, identity, order or timestamps.
The corrected fixture-only verdict retains auxiliary elements and inactive
error states, rejects active errors and still requires the exact four decoded
Escape/Space transitions. Its regression fails before this change and passes
afterward; replaying the unmodified daemon log also passes. The workflow itself
remains a recorded failure, and no production consumer has been implemented.

## Continuous session prototype

`tools/diagnostics/hs274-stream-session.hpp` supplies experimental fixed storage
owned by one dispatcher and one authenticated peer lease. Only one nonempty
batch may await acknowledgement; records remain occupied until the exact batch
is acknowledged. Overflow and sequence exhaustion invalidate the session.
Release erases retained values, and a successor rejects old lease operations.
Lease numbers are local to one object: the eventual wire protocol must also
carry a fresh producer incarnation across process restarts.

Portable behavioral tests cover reuse of the bounded queue, stale ownership,
unacknowledged batches, loss and serial exhaustion. Removing the pending-batch
guard or overflow fault makes those tests fail. These tests also passed natively
in the stream build described below.
The explicit `stream_capture` build input now prepares an experimental wiring
through the same authenticated receiver and a dedicated `--hs274-capture`
CLI mode. It requires `raw_capture`; ordinary builds remain unchanged. Receiver
destruction or peer closure revokes ownership, and each receiver generates a
UUID incarnation. The CLI permits one pending request, writes outside the IPC
dispatcher and acknowledges only a completely published batch. This candidate
passed native tests, all three component builds and strict signature checks in
[build 34440804010](https://github.com/adrienm7/ergopti/actions/runs/34440804010).
The downloaded archive and all four stream headers were independently verified.

The controller's real JSON/MessagePack tests preserve uint64/int64 extremes as
decimal strings and replay all 20 native fixture records in acknowledged batches.
The source preflight succeeds for both finite and stream modes, rejects repeated
instrumentation and rejects a dirty late CLI target before writing any header.
These local checks do not validate the native CLI, initial held state, complete
device coverage, privacy boundaries or stream performance. The native observation
now selects that exact archive, separates CLI stdout and stderr, and requires an
opened handshake before fixture injection. Its final verdict compares every
delivered record with the independent finite capture, including timestamps and
auxiliary metadata, and checks graceful CLI termination.

The stream observation step in [run 34443176811](https://github.com/adrienm7/ergopti/actions/runs/34443176811)
passed: all 20 streamed records matched the independent finite capture exactly,
with zero overflow/contention, empty CLI stderr and graceful exit 143. All six
supervised processes were reaped and the final runtime inventory was empty.
The global workflow retained its separate Quartz/permission failures. This is
native delivery for the virtual fixture, not complete physical-device coverage
or Hammerspoon consumption.

The next observation closes a CLI output pipe before launch, requires an explicit
output-disconnection failure and then requires lease 2 from the same isolated
daemon before injecting the fixture. Local subprocess tests cover the harness's
closed pipe, unexpected success, unrelated failure and bounded timeout cleanup.
The [native disconnect run](https://github.com/adrienm7/ergopti/actions/runs/34444726282)
passed that observation: the first CLI exited 1 with the expected diagnostic,
the successor acquired lease 2 and delivered all 20 records exactly. Independent
downloaded raw-log replay passed; all seven processes were reaped and cleanup
completed. The global workflow retained the separate Quartz/permission failures.
Slow-reader behavior and actual Hammerspoon consumption remain unverified.

## Coverage interruption boundary

The pinned `device_grabber_details/entry.hpp` reserves observation for the
Karabiner virtual device. Configured-ignored and temporarily-ignored physical
keyboards are neither observed nor seized; `make_grabbable_state` consequently
stops their monitor. Disabled physical keyboards instead remain seized so their
input can be suppressed. Removing the fixture-name filter cannot establish
complete physical coverage. Non-seizing acquisition of ignored keyboards and
explicit lifecycle readiness are still required.

The session/controller now exposes interruption of the current lease. It clears
retained values, rejects further reads and acknowledgements, preserves an earlier
fault and returns `lost/interrupted` on the wire. Restoring acquisition must not
revive the interrupted lease. Native acquisition still owns readiness checks
before permitting a successor; this method alone provides no coverage inventory
or new-device readiness guarantee. Portable tests exercise interruption with an
outstanding batch, stale successor requests and real MessagePack responses.
A compiled no-op interruption mutation fails the session assertion.

The source owner now tracks a bounded inventory of registered monitors. Opening
requires a nonempty inventory with every registered monitor started; adding,
stopping or retiring a monitor interrupts the active lease. Monitor handles hold
weak references to their original source, so callbacks and destruction from an
old receiver cannot mutate its successor. Unexpected device identity removes
readiness; inventory exhaustion remains unavailable until source replacement.
The native patch connects started, stopped, error and dispatcher teardown to
these handles. The experimental runtime still permits exactly one renamed
fixture; this is neither all-device discovery nor a held-key baseline.

Portable source tests cover two monitors, pending startup, interrupted batches,
device mismatch, retirement, bounded inventory and callbacks after receiver
replacement. The pinned monitor transformation accepts the inspected source
and rejects duplicate instrumentation. Native compilation and lifecycle
observation remain pending; the verified native build predates this addition
and must not be cited as validation of it. Graceful fixture completion requires
keeping its monitor alive until the consumer has drained; otherwise teardown
can interrupt an outstanding batch.

The authenticated `status` request now reports the producer incarnation,
registered monitor readiness and inventory exhaustion without acquiring a lease
or disturbing an active capture. The CLI validates that readiness agrees with
the inventory and waits on the same connection before opening. Status requests,
connection/response waits and the final open share one steady-clock deadline;
polling does not renew the startup budget. Malformed replies, changed producer,
exhaustion and transport failures are terminal. The source still rechecks
readiness when processing open.

Portable tests call the actual source status path and startup helper with a
controlled clock. They cover pending-to-ready transitions, exact expiry, late
ready responses, transport-error propagation, missing fields, duplicate device
IDs and inconsistent inventory. Native CLI execution of this new startup path
remains pending.

The native input fixture's `--remap-hold` mode now retains its renamed device
after releasing both keys, until the supervisor explicitly confirms drain or
aborts; a bounded wait also restores it after supervisor failure. The supervisor
waits for the complete shape of the retained native reference, including trailing
auxiliary values, then reaps the CLI with its expected graceful exit before
releasing the fixture. Final verification still compares every streamed record,
including original timestamps and device identity, against the independent
finite capture. Portable Python tests cover complete/prefix/malformed drain data
and cleanup ordering. Reinstating the old Space-up-only completion predicate
fails the new trailing-record assertion. Native execution of this coordination
still requires the next coherent producer build and observation.
