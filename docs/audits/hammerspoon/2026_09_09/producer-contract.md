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
and rejects duplicate instrumentation. Native lifecycle observation remains
pending; the build evidence below establishes compilation only. Graceful fixture completion requires
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
still requires observation with the updated producer.

The updated producer passed native portable tests, all three component builds
and strict signature checks in [build 34451082836](https://github.com/adrienm7/ergopti/actions/runs/34451082836),
on repository head `34beefdcc4a04aaa071f4f57c0e214f72c629dab`. Its downloaded
archive is 12,155,650 bytes, with SHA-256
`71dce1b9266dc94dd41cc1bc1705d130f7d9789f84a1193f2f47addf40491549`.
All six retained stream headers match the committed sources. The native
observation selects this exact build for readiness, monitor lifetime and
fixture-drain validation.

The corresponding [runtime observation](https://github.com/adrienm7/ergopti/actions/runs/34452515041)
passed its actual remapping/stream step. Independent downloaded raw-log replay
confirmed all 20 records, lease 2, empty successor stderr, graceful CLI exit 143
and the native drain-release receipt. All seven processes were reaped; metadata,
registration helpers and configuration were restored or removed, and the final
runtime inventory was empty. The overall workflow retains separate
Quartz/permission failures. Graceful teardown alone does not prove delivery of
an explicit monitor-interruption notification.

The next observation preserves that successful stream, opens idle lease 3 in
the same producer before releasing the fixture, then requires exactly its opened
frame followed by `lost/interrupted`, the coverage-loss diagnostic and CLI exit
1. The fixture's bounded hold allows the additional observer startup. Portable
tests reject missing, truncated, duplicate, wrong-session and wrong-reason loss
receipts, including a Boolean substituted for the numeric protocol version.
This intentional native interruption remains unverified; it reuses the same
producer archive and does not require recompilation of Karabiner.

That [interruption observation](https://github.com/adrienm7/ergopti/actions/runs/34454746577)
failed before lease 3 opened: its stdout was empty and stderr reported
`No such file or directory`. Independent replay still matched all 20 lease-2
records to the finite capture. All eight processes were reaped, metadata and
registration helpers restored, and configuration removed. The failed report
does not contain a final process-inventory check.

The retained system core log reports `receiver: closed` at 08:23:54.170,
before fixture termination at 08:23:54.539 and general teardown. Upstream maps
this notification to listener accept failure or socket-path health failure;
both remove the owned socket path and schedule a bind retry. The new build
instrumentation records the phase, numeric error and category at those exact
failure sites, preserving recovery behavior. It also retains the vendor diff
in the build receipt. These diagnostics have not yet been compiled or observed
natively. Do not infer the failing branch from timing or add CLI retries to
hide this missing evidence.

The instrumented [build 34456130742](https://github.com/adrienm7/ergopti/actions/runs/34456130742)
passed native compilation and signature verification on head
`bdcad758ac40dc525fe23e21cd8ec578836d2195`. Its downloaded archive is
12,155,984 bytes with verified SHA-256
`1d628c6fede50703aee6a188c8c397ae36e8ab0964e31dc8540f57429f1046a1`.
All six stream headers match the committed sources, and the retained vendor
diff includes both listener-failure diagnostics. The native observation now
selects this exact archive; the failing transport branch remains unobserved.

The [instrumented native observation](https://github.com/adrienm7/ergopti/actions/runs/34458992298)
passed the actual remapping and intentional interruption step. Independent
artifact replay matched all 20 lease-2 records to the finite receipt and
validated exactly `opened` followed by `lost/interrupted` for lease 3 in the
same producer. Drain release, metadata restoration, both registration helpers,
all eight process reaps and an empty final runtime inventory passed. No
listener-failure diagnostic was emitted: the earlier connection anomaly remains
unexplained. Independent Quartz and permission steps still fail globally.

### Observation preparation before acquisition readiness

Ignored keyboards need observation ownership before their monitors can become
ready. The previous client waited for readiness before opening its stream, so
starting these monitors only on stream open would introduce a circular wait.
Status remains read-only. The experimental source now reserves observation
through an exclusive `prepare` request, identified by producer incarnation and
a monotonic preparation ID. Opening requires that identity and ready monitors.
Cancellation, valid stream close and owner disconnect release the reservation;
a stale cancellation cannot release its successor. Values received before
stream open are not replayed as new physical credits.

The CLI prepares, waits and opens under one existing startup deadline. Portable
source tests cover ownership, stale cancellation, read-only status, disconnect
and pre-open data isolation; removing the preparation-ID check makes the test
fail. The successful native run above predates preparation.

### Reserved observation of ignored input

The experimental receiver now refreshes the existing device-grabber policy on
preparation ownership transitions, including owner disconnect. The queued grab
reads current ownership, so a delayed callback cannot apply a captured obsolete
reservation. Only registered fixture devices gain observation, and only when
neither seizure nor temporary ignore is requested. This exclusion preserves the
virtual-output readiness gate: upstream considers observed devices immediately
grabbable before checking whether a virtual output exists. Managed and disabled
devices must retain their original seizure checks.

Portable source tests cover pending acquisition, owned/foreign disconnect,
close, cancellation, monitor retirement/replacement, inventory exhaustion and
the seizure/temporary-ignore matrix. Three isolated mutations removing the
owner, seizure or temporary-ignore guard each compile and fail a behavioral
assertion. Exact-source patch anchors and duplicate-instrumentation refusal
were checked against the pinned entry and receiver sources.

The native workflow accepts an `ignored_fixture` scenario requiring the
development stream. It keeps the same Escape/Space remapping rules but sets the
owned input device to ignored. The native output must then contain exactly
Escape down/up followed by Space down/up, with no physical-ledger rule output.
The existing exact raw-record, stream drain, successor lease, interruption and
cleanup assertions remain required. Python tests independently reject wrong
output keys, contradictory mode receipts and changed provenance flags.
The [native build 34688834371](https://github.com/adrienm7/ergopti/actions/runs/34688834371)
passed portable C++ tests on macOS, exact-source patch application, compilation
of all three components and signature verification on
`6b51bee375b5aa60ac65fc67f7011a1e30d2e233`. Its downloaded archive is
12,167,027 bytes with verified SHA-256
`a313726a4ac2796de3967fc72c08a9b61ad2c4a41fb200766331536261649286`.
All six retained stream headers match committed sources; the retained patch
includes receiver transitions and entry observation policy. The native workflow
now selects this archive. Execution of the ignored scenario remains pending.
This remains fixture-only coverage, without a production Hammerspoon consumer
or physical hardware validation.

### Ignored-input delivery and accepted-peer failure

[Run 34690081261](https://github.com/adrienm7/ergopti/actions/runs/34690081261)
started the ignored fixture monitor as observed, stopped it after the first
client disconnected, and restarted it for lease 2. Native output retained
Escape (53) down/up followed by Space (49) down/up. Independent replay matched
all 20 raw values to lease 2, including auxiliary values and timestamps, with
no overflow or contention. The physical client drained and exited 143.

The third client failed before opening its lease with `No such file or
directory`. This time the retained diagnostic identifies
`phase=accept code=22 category=asio.system`. The listener closed before fixture
teardown. The fixture aborted without drain-release confirmation; metadata,
registration helpers and configuration were restored/removed and all eight
processes were reaped. The report did not reach the final inventory or ledger
assertions. The overall scenario is therefore still red.

The pinned Asio `socket_ops::accept` applies `SO_NOSIGPIPE` to the accepted
socket and propagates failure through the accept callback. Apple's
[socket-option implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/uipc_socket.c)
returns `EINVAL` for a fully shut-down socket. This suggests that a disconnected
accepted peer can be mistaken for a failed listener. The new isolated native
transport test closes a client before acceptance, checks the raw option failure,
and requires a healthy successor and preservation of genuine listener errors.
The workflow currently requires the precise pre-fix failure; native reproduction
of this candidate remains pending. Do not globally ignore `EINVAL` or add client
retries to conceal the distinction.

[Run 34690875541](https://github.com/adrienm7/ergopti/actions/runs/34690875541)
compiled the isolated test and reproduced successful raw acceptance followed
by `SO_NOSIGPIPE=EINVAL`, then asynchronous Asio acceptance reporting code 22.
Its listener-health control was invalid: Darwin's `getsockopt` implementation
does not expose `SO_ACCEPTCONN`. That stopped the test before the successor
assertion, so this run is not a complete regression proof. The test now accepts
and configures a real successor in both baseline and repaired cases.

The exact-source experimental patch normalizes only Darwin `EINVAL` from the
accepted socket's `SO_NOSIGPIPE` setup to `connection_aborted`. Existing Asio
accept handling then discards that aborted peer and continues accepting; errors
from the actual listening socket retain their original identity. Authentication,
server recovery and CLI requests are unchanged. The minimal workflow compiles
the same test against pristine and patched headers, requiring exact baseline
exit 17 and repaired exit zero.

[Run 34691699034](https://github.com/adrienm7/ergopti/actions/runs/34691699034)
passed that paired native proof on `d39ca2298be02b9d07b0d0448c9625b294582f14`.
The original headers returned asynchronous accept error 22 and test exit 17;
the repaired headers accepted the live successor and returned test exit zero.
Both cases verified the healthy listener with actual successor communication
and preserved `EINVAL` from a genuinely non-listening socket. The repaired
asynchronous peer also delivered the expected byte, excluding a false success
that simply exposes the dead peer.

[Build 34691771255](https://github.com/adrienm7/ergopti/actions/runs/34691771255)
passed native C++ tests, exact-source instrumentation, all three sequential
component builds and signature verification on the same commit. The downloaded
archive is 12,167,081 bytes with verified SHA-256
`b49289ad42bd42cd343abadea36c9ae8a79a4dacdd3677f6c7fdc4ba216ec9cf`.
All six retained stream headers match the owned sources, and the retained Asio
diff contains the accepted-peer repair. The native workflow selects this build
for the next complete ignored-input replay. That replay remains pending;
the isolated transport proof does not establish complete physical accounting.

### Repaired ignored replay and process-role ambiguity

[Run 34699072353](https://github.com/adrienm7/ergopti/actions/runs/34699072353)
on `431e60085692a9d3567b640b47a438d8aaa72cf3` opened lease 3 and received its
`lost/interrupted` terminal frame. The ignored fixture exited zero, released
its drain and restored metadata. Escape 53 and Space 49 retained their exact
down/up output pairs; the empty ledger assertion passed. Independent replay of
the retained daemon and stream logs matched all 20 raw values to lease 2,
including timestamps and auxiliary values, with zero overflow and contention.

The scenario still failed its `after-input` inventory: stock Core-Service PID
5332 appeared alongside the three expected development processes. The helper
execution and disabled-service checks immediately preceding that inventory
passed. All eight owned processes were reaped and both helpers restored, but
the exception prevented the final inventory assertion. Do not call this a
complete isolation success or discard the unexpected process.

Pinned upstream `core_service/agent/permission_checker.hpp` directly opens the
installed Core-Service bundle through Launch Services with `permission-check`
arguments, independently of service registration. Without granted bundle
permissions it repeats that check after one second. This supplies a concrete
candidate for the extra executable; the recorded inventory lacks arguments
and cannot establish PID 5332's actual role. The fixture now retains a second
untruncated PID/parent/arguments snapshot before rejecting a foreign executable.
That snapshot is diagnostic only: process exit or PID reuse cannot authorize
an exception to isolation. Portable tests require preservation of both a
successful query and a failed query while keeping the original rejection.

### Managed replay with repaired transport

[Run 34700043424](https://github.com/adrienm7/ergopti/actions/runs/34700043424)
on `80cd0548192dab92f34e5817d7aa314986e12231` passed the complete remapping
scenario (step 19) using build 34691771255. Escape produced Space and the actual
Space retained its own down/up pair. The ledger contained exactly `escape` and
`U:escape`. All 20 raw records matched the stream, with zero overflow and
contention. Lease 3 opened and terminated with `lost/interrupted`; the fixture
confirmed drain release and metadata restoration. All eight owned processes
were reaped, both registration helpers restored, configuration removed, and
the final native runtime inventory was empty.

The unexpected stock executable did not appear in the sampled inventories,
so this run does not identify the earlier PID or rule out a transient bundle
permission probe. The stricter diagnostic remains in place. The overall run
failed the separate Quartz and permission checks (steps 8, 9 and 18); success
of step 19 establishes this fixture scenario only. Complete physical inventory,
held-key initialization, modifiers/repeats, privacy invalidation and the
production Hammerspoon consumer remain required before closing HS-274.

### Keyboard-interface inventory expansion

The experimental monitor selection now includes upstream keyboard and consumer
interfaces except those identified as Karabiner virtual outputs. The source
retains at most 64 monitors; the existing exhaustion path interrupts coverage
instead of silently omitting a device. Every selected pending monitor remains
part of readiness, including ignored devices that require owned observation.
Pure pointing/gamepad interfaces are outside this selection; this is not a
claim of complete physical input or hardware authenticity.

The finite native reference remains restricted to the independently identified
renamed fixture. A shared input router forwards every selected value to its
source monitor but mirrors only reference values to that finite capture. The
two-monitor C++ regression reproduces reference overflow with unconditional
mirroring, then verifies independent per-reference and global stream sequences
after the repair. The Python verifier compares the fixture subsequence while
retaining and validating every global record, including interleaved devices.
Its existing native managed receipt replay remains unchanged.

Portable routing/source and Python tests pass; pinned monitor transformation
and duplicate-instrumentation refusal pass. Native compilation and execution
of the expanded inventory remain pending. The protocol continues to advertise
only the experimentally established `fixture_only` coverage. Startup discovery
completeness, held state and other physical-accounting requirements remain open.
