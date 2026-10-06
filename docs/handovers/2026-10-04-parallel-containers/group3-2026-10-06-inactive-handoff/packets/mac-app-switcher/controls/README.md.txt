# Private macOS native switcher broker preparation

This packet implements a shared single-operation broker and a macOS facade. It
is outside the repository and has not been integrated. It does not enable a
feature, replace existing previous-window actions, change action data, or qualify
physical input. TODO 111 remains partial.

The software separates four receipts: post admission, actual tagged observation,
HID plus combined-session release, and a changed frontmost PID. Only after the
last three are acknowledged and the exact input and timer owners are physically
retired does it publish `switched`. A callback records arrival only; subsequent
edges are posted by the broker timer, outside the native observation callback.

## Native input dependency

The actual SyntheticInput adapter currently exports none of the following
methods. The facade refuses initialization and remains unavailable without the
complete set. These names are a proposed Group5 contract, pending its ownership
agreement; they are not implemented by test doubles in production.

| Proposed method | Required contract |
| --- | --- |
| `system_switcher_available()` | Literal true only for a genuinely supported tagged native path, including required observation and physical-state capabilities. |
| `prepare_system_switcher(attempt, on_observed, admission)` | Store the exact attempt before every native acquisition. Refusal or a throw leaves acquired input, event tap, sampling task, and fence debt addressable by that attempt. Require fresh HID and combined-session state before taking modifier ownership. |
| `post_system_switcher_edge(attempt, ordinal)` | Post only the exact admitted attempt after its source admission callback succeeds. Ordinals 1–4 mean explicit Command flagsChanged down, Tab keyDown with Command, Tab keyUp with Command, and explicit Command flagsChanged up. Paired strokes with flags alone do not implement this contract. |
| `system_switcher_observation_current(attempt, ordinal)` | Literal true only for the exact native event tag, PID, event type, modifier state, sequence, and retained session. PID, timing, or a successful post alone is insufficient. Call `on_observed(attempt, ordinal)` only to record observed arrival. |
| `system_switcher_release_current(attempt)` | Fresh actual HID and combined-session confirmation that owned Command/Tab state has retired, without releasing a physically held or foreign key. |
| `cancel_system_switcher(attempt)` | Revoke ordinary emission for this attempt before cleanup callbacks. |
| `retire_system_switcher(attempt)` | Literal true only after input, tap, sampling task, native timer, and fence retirement is acknowledged. False or an exception retains the exact attempt for retry; missing observation is not retirement. |

The provider must honor its own exact native ownership and source guards, even
when the broker's admission callback previously passed. An input cancellation
request is logical revocation; it cannot substitute for the retirement receipt.
The final publication `cached()` callback must be a pure terminal seal supplied
by the source owner, not another native read. All opaque identities use raw
identity. Cleanup invokes captured provider functions, never replacement owners.

## Timing and lifecycle

The facade takes required finite positive `deadline_sec` and `poll_sec` values,
with polling no greater than the deadline. It uses actual TimerScheduler.every,
its `(handle, committed)` contract, strict cancel acknowledgement, and
TimerScheduler.awake_time. No shared timing source is changed. The controlled
fixtures specify 50 ms polling; this is not a product default.

Existing canonical `llm.poll_interval_ms = 50` belongs to LLM polling, and the
`gestures.aux_shell_*` values belong to shell cleanup. Neither is honestly a
native switcher policy. Root must admit an appropriate canonical timing policy
before product initialization. Diagnostic 20 ms polling and its literal timeout
are not borrowed.

Pause revokes the facade generation before native callbacks and retries exact
retirement. Resume cannot bypass an outstanding operation. Refused timer startup
with a live returned handle is retained. A constructor that throws without a
cleanup handle remains unknown debt; this is fail-closed, rather than claiming
absence. Actual TimerScheduler catches native construction/start failures and
returns its retained handle, so that unexpected-port path is not used as a
substitute for its real ownership contract.

## Qualification

Run the exact controlled cohort with activation:

```sh
. /workspace/.ergopti-cloud/activate.sh
python3 /workspace/.ergopti-cloud/preparations/group3-macos-product-global-switcher/run_focused.py
```

Final Lua 5.4: 31 passed, 0 failed. These include two actual TimerScheduler adapter
cases with controlled native start/stop boundaries. Shared broker LuaJIT: 21
passed, 0 failed. Mac facade and timer adapter are qualified with the supported
Lua 5.4 ABI, not claimed as native Hammerspoon execution.

Three independent omission controls retain the same test bodies: moving the
native callback after the terminal source seal produces 30/1; ignoring the input
retirement ACK produces 27/4; removing tagged-arrival admission produces 30/1.
Those are intentional failed controls, not failing final tests. No old assertion,
corpus, native runner, adapter, manifest, timing source, or repository file was
modified. Root full gates, actual macOS native input/Dock observation, installation,
and hardware validation have not been run for this preparation.

The fifth manual CI receipt remains historical evidence for its exact source,
not qualification of this new product broker. Its native global switcher was
`native_observation_not_qualified`; this packet does not infer a TCC cause or
replace it with a claimed successful native operation.
