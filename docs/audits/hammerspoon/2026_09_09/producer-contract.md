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
