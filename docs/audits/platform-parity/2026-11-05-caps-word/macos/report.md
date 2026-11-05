# macOS CapsWord activation and automatic deactivation audit

Audited source: `f2a7dba5fc580aad61e6a0ed16ede84406aed2b0`.
Date: November 5, 2026. Scope: CapsWord only. No production code or registered
repository tests were changed. The worktree remained at the audited source.

The review follows the actual generated Karabiner graph, its activation tags,
the serialized variable writer, the Hammerspoon watcher, its runtime settings
and real menu callback, and accepted driver output. It contributes 42 qualified
coverage rows and three confirmed owner-level findings. The shared fractional
idle and renamed-magic-label issues are corroborated here without duplicate IDs.

## Evidence boundaries

Five portable programs execute unchanged production owners over explicitly
recorded native ports. `public-idle.lua` uses the existing watcher native-port
fixture with actual settings, manifest renderer and submenu callback. Its save
port acknowledges success/refusal; it does not prove a disk write.
`public-admission.lua` instead uses the **actual serialized KeVariables owner**
and actual control-sentinel owner, with controlled CLI publication/completion,
timers, eventtap and LED requests. This distinguishes the two asynchronous
boundaries rather than treating a CLI's publication as its exit callback.

`public-payload.lua` exercises actual policy, watcher, output relay and the real
TextSender direct-output path. `activation-graph.lua` executes the actual graph
generator and catalogue handler; its Karabiner model is not native Karabiner.
`public-magic-menu.lua` executes the real submenu/settings/watchers and real
terminator rename. The supplied parent-context formatter matches the published
menu callback's star-to-trigger substitution; full Keymap/startup is not claimed.

All five final programs pass in two final bounded dry sweeps, A and B, after the
last new confirmed root. Each receipt records the actual program and output
hashes. Both sweeps cover the findings, positive controls, renamed magic,
fractional idle, generated graph and explicit scope limits; neither surfaced an
additional confirmed root. They are not a proof that every native state is safe.

Fourteen exact registered modules were also run **independently**, each in a
fresh Lua 5.4 process: 148 positive cases, zero failures. Some modules include
broader gesture/writer controls and some cases are lexical/meta checks; this is
not 148 native CapsWord scenarios. `test-results.json` names the modules and
exact test-source hashes. Mechanical false-green detection is within baseline
(0 versus 0); that scanner does not establish semantic adequacy.

No physical macOS application, real Karabiner child, real CapsLock state,
native keyboard/IME payload, real-time latency or long-duration memory behavior
was measured. An optional LuaJIT attempt is a fixture-compatibility diagnostic:
macOS helpers require `table.pack`; only the genuine Lua 5.4 runs are credited.

## CW-M001 — Live idle-delay changes can leave no expiry owner

Severity **medium**, confidence **high**. Additional property:
`live_applied_idle_policy`; no G4 latency assertion.

Precondition matters: **turn off all six CapsWord pointer-termination kinds
before activation**, so moving through/clicking the menu does not already end the
session. Start with idle delay zero and no checked delimiter/fixed exit during
the sequence. These are valid settings, compiled by the actual settings owner.

The actual submenu's one-second preset callback updates the settings owner,
receives successful save acknowledgment and refreshes its menu. The real policy
now says 1000 ms. After the next ordinary letter and more than one second of
controlled inactivity, CapsWord is still active and **no timer exists**.

| Controlled sequence                                                       | Observed owner result                                                       |
| ------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Activate at zero; select one second; type a letter; pass its new deadline | No timer, no clear, active remains true.                                    |
| Activate at ten seconds; select one; type a letter; pass its new deadline | Active remains true; the original ten-second callback finally clears.       |
| Activate at one second; select zero; fire the existing check              | Remains active; the callback consumes its timer and creates no replacement. |
| Activate at one; select zero; consume old check; select one; type         | No timer is reacquired, so the new one-second deadline cannot run.          |
| Activate at one; select ten; fire the first check                         | Re-arms the longer remaining delay and clears at the longer deadline.       |
| Save refuses a zero-to-one change                                         | State and live policy roll back to zero.                                    |
| Change the comma checkbox in the same active session                      | The very next comma clears.                                                 |
| Activate again after selecting one                                        | A new one-second timer is correctly acquired.                               |

This is not inferred from cross-OS uniformity. macOS's submenu explicitly says a
change applies at once; `infra/capsword_auto_off.lua` and menu-state application
say the next event uses it. Windows's documented next-activation snapshot is a
separate mechanism. The macOS owner changes the policy immediately, but does not
notify the timer owner. Only activation starts a missing idle clock. Key/output
callbacks update activity without acquiring/rescheduling the idle capability.
Existing callbacks read the new policy, explaining the asymmetric results above.

It is silent because successful policy application/save acknowledgment is not a
timer receipt. No callback exists in the zero-to-positive case to diagnose the
missing owner. A regression must drive these exact actual-menu transitions,
next-key activity, save rollback, next activation, duplicate/stale callbacks and
teardown. Evidence: `public-idle.lua` and its final A/B outputs.

## CW-M002 — A previous inactive pointer event masks a new session's exit

Severity **low**, confidence **high**. Additional property:
`checked_pointer_deactivation`. Timings below are controlled clock readings,
not measured native event intervals.

With checked pointer kinds and idle zero, deliver mouse motion while CapsWord
is inactive at time 1000.00. No writer is needed, but the watcher still stamps
its 100 ms throttle. Deliver a valid activation control edge at 1000.01 and one
checked pointer event at 1000.05. Actual watcher/KeVariables execution leaves the
new session active, with zero clear tasks and zero LED-off requests. The program
covers left/right/middle click, gesture and scroll events in this window.

The same click after a fresh activation without that previous inactive event
clears; a click at the exact 100 ms boundary clears; a typed space inside the
pointer interval clears when there is no pending writer. These controls isolate
the pointer gate from ownership, policy validity and delimiter behavior.

`deactivate_capsword` updates `_capsword_last_check_ns` before discovering that
there is no active intent to clear. A new activation does not reset it. The
throttle covers discrete clicks and gestures as well as repeated motion. The
ignored event is neither logged nor retained; a later motion may clear but does
not replay that single event. Regression should preserve cheap motion throttling
while testing the new session's first checked discrete event and disabled-kind
controls. Evidence: `public-admission.lua` and final A/B outputs.

## CW-M003 — An older pending clear masks a newer activation's delimiter

Severity **medium**, confidence **high**. **G3**, with the additional property
`capsword_deactivation_admission`. This is a conditional asynchronous-ordering
finding, not a native timing or capitalization claim.

The valid native ordering is precise:

1. An active CapsWord receives a pointer exit and queues a real serialized clear.
2. The native CLI port publishes that exact scoped `capsword = 0` payload, but
   its completion callback has not yet been delivered.
3. Only now does the deployed `variable_unless = 1` activation rule permit a
   fresh activation. Its control tag is admitted by the actual exact-token owner.
4. A checked space arrives before the previous clear's completion callback.
5. The previous child exits successfully, **without applying its payload twice**.

The real variable owner now knows activation 1, but `_capsword_check_pending`
still belongs to the previous asynchronous clear. Even an immediate typed
terminator returns at that flag: no new clear is queued and no immediate LED-off
is requested. The old callback correctly avoids applying a stale LED effect to
the newer revision, then releases the flag. It never retries the dropped space.
A later second space does clear. With idle zero and no later exit, the dropped
termination has no recovery timer.

The reproduction does **not** assert that a fresh activation is possible while
the native graph still has variable 1: in that earlier interval CapsLock takes
the graph's deactivation path. Splitting publication from completion is essential
to the valid scenario. Existing tests send their next pointer only after old
settlement, so they miss this interleaving.

Regression must retain/admit the newest exact-generation deactivation intent,
including a delimiter in acknowledged driver output, while guarding stale LED
writes, wrong tokens, native publication ordering and teardown. Evidence:
`public-admission.lua`; its actual writer-native port fixture source is retained
in the authenticated source receipts.

## Explicit differences, controls and unresolved intent

- **Catalogue aliases:** common `caps_word` is Windows/Linux; macOS's equivalent
  is `capsword`. Separate IDs are not a missing capability. macOS native actions
  are `holdable = false`; no Linux `while_released` equivalent is promised.
- **Activation versus toggle:** the actual macOS catalogue handler writes 1
  after accepted dispatch and requests CapsLock true only after successful,
  current-revision settlement. Native graph activation has a `variable_unless`
  guard. Re-invoking the catalogue action is therefore not a generic toggle.
  Cross-OS product intent needs separate adjudication.
- **Preexisting CapsLock:** generated key activation/exit each emit one CapsLock
  key plus control tag. The catalogue handler asks for true; a watcher-owned
  clear asks for false and holds no prior-lock snapshot. The graph model does
  not establish what a real initial-ON CapsLock does. This remains an observed
  owner difference/native receiving gap, not a confirmed universal user-lock bug.
- **Stopped watcher:** teardown removes the output observer, listener, idle/LED
  timers, touch hook and native eventtap, retaining refused capabilities for
  retry. It does not itself request CapsLock restoration. Broader lease/native
  behavior remains qualified; a clean stop receipt is not a physical LED receipt.
- **Pointer kinds:** all declared kinds are tested with enabled/disabled controls.
  Bare touch uses the gestures engine hook. An absent gestures engine logs an
  explicit warning; this is not proof that a native touch occurred.
- **Delimiters:** actual owners clear on checked NBSP, narrow NBSP, multistring
  carriers, CR, LF and Tab. Letters and empty/invalid output do not clear. ETX
  does not match; no actual keypad-Enter payload is claimed.
- **Modifiers:** this watcher subscribes keyDown, not flagsChanged/keyUp, so pure
  modifier transitions do not refresh its idle clock. Whether every OS must
  count those transitions is an unresolved semantic comparison.
- **Synthetic output:** real TextSender accepted direct text reaches the relay;
  refused text does not. Expansion source reports `logical_text` only after its
  canonical commit. This does not certify clipboard/native application receiving.
- **Shared tiny-positive delay:** 0 means never; 0.0001 compiles to zero ms but a
  zero-delay callback; 0.001 compiles to one ms. The shared reviewer owns the
  cross-driver root. No duplicate macOS ID is introduced here.
- **Renamed magic label:** after the actual terminator rename to section sign,
  the real submenu displays `§ : Magic key`, but selecting it still compiles the
  policy's previously captured literal star. Section sign keeps CapsWord on;
  star clears it. AHK's explicit built-in/literal policy comment means this
  needs a truthful-label/literal-versus-dynamic decision, not an assumed command
  to change all engines to dynamic magic matching. Shared root only.

## Rejected hypotheses and remaining qualification

The historical JSON anchor's Space/Enter/Tab/g/v/click exits are **not** all
deployed: the actual generator removes the settings-owned subset. Reporting
those raw-template exits as current behavior would be false. An old clear's LED
callback is revision-gated; a stopped-generation callback cannot clear a new
lease. No CLI variable read is attempted. Pointer events without an owned active
intent do not alter personal CapsLock by themselves. A refused text emission
never reaches the CapsWord output relay. These refutations are backed by actual
owner controls, not absent strings alone.

There is no G4 performance measurement, no memory-growth measurement and no
native desktop certification. The source receipts authenticate 46 named files,
including test/fixture owners, not every transitive dependency. Prior canonical
audit reports and the root TODO were searched for CapsWord roots; no earlier
confirmed root matching the three above was located. Earlier native TODOs about
pointer cancellation are receiving debt, not proof those paths are already safe.

`coverage.json`, `findings.json`, `source-hashes.json`, `test-results.json`, and
`dry-A/receipt.json` / `dry-B/receipt.json` retain machine-readable boundaries.
