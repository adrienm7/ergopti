# 011 — An Ergopti-owned background Karabiner runtime for exact physical-key accounting

| Field        | Value      |
| ------------ | ---------- |
| **Date**     | 2026-09-29 |
| **Status**   | Accepted   |
| **Deciders** | Maintainer |

---

## Context

The macOS tap-holds, combos and navigation layer are Karabiner complex
modifications. Up to `v0.0.0-dev.147` onboarding installs the official
Karabiner-Elements 16.0.0 application (UI, system extension and root grabber)
and ErgoptiPlus merges token-scoped rules into the user's own
`~/.config/karabiner/karabiner.json`. Ergopti never owns a Karabiner process:
that is rule R3, and `tests/meta/test_karabiner_stock_process_isolation.lua`
enforces it.

That arrangement cannot count physical keys exactly (HS-274). Karabiner rewrites
key codes before Quartz sees them, so the keylogger's event tap credits the
remapped output, and a `shell_command` ledger in each tap-hold manipulator also
credits the physical key: every remapped tap is counted twice. Suppressing the
managed output key codes instead loses real presses, because the shipped
defaults send CapsLock to Return and left Command to Backspace while the
physical Return and Backspace pass through unjournaled. Every attribution
heuristic (timing, order, PID, user data, sender identity) was measured and
rejected. The only exact source is a raw HID stream read inside the Karabiner
core, before remapping, with device and element identity: a producer Ergopti
must own. The complete analysis, the rejected paths and the work packages are in
the [HS-274 delivery plan](../../../../docs/handovers/2026-09-29-overnight/hs274-delivery-plan.md);
its section 6 asked the maintainer five questions, answered on 2026-09-29 in the
[decision log](../../../../docs/handovers/2026-09-29-overnight/DECISIONS.md).

## Decision

1. **Runtime.** Karabiner is no longer installed as the Karabiner-Elements
   application. Ergopti runs its own background runtime: the unmodified,
   pqrs-signed Karabiner-DriverKit-VirtualHIDDevice, plus an Ergopti-built
   headless fork of Karabiner-Elements 16.3.0 (`9312593e`) reduced to three
   products (Core-Service in daemon and agent modes, Console-User-Server and
   `karabiner_cli`) and carrying the HS-274 stream. No settings UI, EventViewer,
   Updater or MultitouchExtension is shipped. Ergopti owns the runtime's
   configuration.
2. **Lifetime.** The runtime runs only while Tap-Hold (the remapping that needs
   Karabiner) is enabled. Users with Tap-Hold off never run it; their metrics
   keep the Quartz event tap, which is exact when nothing is remapped.
3. **Coexistence (question 1).** When the runtime runs, Ergopti quits any other
   active Karabiner, under a menu option « close other Karabiner instances »
   that is on by default. A user keeps their own Karabiner by turning Ergopti's
   Tap-Hold off or unticking the option. This deliberately overrides R3 for that
   explicit, default-on option only. With the option off, the owned runtime does
   not fight another grabber: it reports an explicit, named unavailable state.
4. **Branding and signing (question 2).** The pqrs branding of the
   VirtualHIDDevice (hidden manager application, notification, Driver
   Extensions entry) is acceptable. Ergopti does not get an Apple Developer ID:
   the runtime is signed with the stable self-signed Ergopti identity and the
   Gatekeeper and « unidentified developer » friction is accepted.
5. **Fork ownership (question 3).** The maintainer keeps the 16.3.0 fork and
   re-anchors it on each upstream bump.
6. **Metrics semantics (question 4).** Once the stream is active the heatmap is
   physical-only: autorepeat is not credited as presses, and navigation-layer
   letters count as the letters pressed, not as the arrows they produce.
7. **Keys and hardware (question 5).** Everything is counted, the fn/globe key
   and the media (consumer) keys included. Real-Mac acceptance uses the
   internal Mac keyboard, with fn/globe, only.

## Consequences

### Positive

- One authoritative physical source while a capture is admitted: the stream
  credits, Quartz and the ledger do not, so HS-274 cannot recur by construction.
- The user's `~/.config/karabiner` is no longer rewritten by Ergopti in owned
  mode, and no personal-rule surgery is needed there.
- If Ergopti dies, the daemon stops grabbing when its console-user peer closes,
  so the keyboard returns to native input without a guardian heartbeat.

### Negative / Trade-offs

- Ergopti maintains a fork and re-anchors about nine upstream files per bump.
- Without a Developer ID, `SMAppService.daemon` may refuse the self-signed
  runtime; the fallback is an administrator-prompted
  `launchctl bootstrap system`, and Login Items show an unidentified developer.
- Because the runtime is self-signed, the upstream `same_team_id` check (which
  trusts every peer when the daemon has no verified Team ID) must be replaced by
  a designated-requirement check pinned to the Ergopti certificate leaf before
  anything ships; otherwise any process of the console user could read the raw
  keystroke stream.
- The default-on option quits a user's own Karabiner; the menu must say so.
- Only the internal keyboard is validated on hardware. ISO versus ANSI external
  keyboards, Bluetooth and two keyboards at once rely on virtual fixtures.

### Neutral

- Shared mode (the official 16.0.0 install and merged rules) stays the
  production path until the owned runtime passes native and real-Mac
  acceptance. New flags default to today's behaviour and use key names no older
  build ever wrote, so shared-mode generator output and boot stay identical.
- VirtualHIDDevice version skew (only one version can be active system-wide) was
  not part of the original answers. On 2026-10-04 the maintainer chose to block
  an incompatible runtime with an explicit explanation and offer an update
  only after confirmation. The owned mode must expose that named unavailable
  state; an automatic driver replacement is not authorized by detection.
- Counts are exact only inside an admitted capture. Before approval, during
  stream loss or with the option off while another Karabiner holds the
  keyboards, the gaps are recorded explicitly and never reconstructed.

## Alternatives considered

| Alternative                                                                    | Why rejected                                                                                                                                           |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| kanata on the VirtualHIDDevice                                                 | Its TCP protocol exports no raw key event; tap-hold, combos and lease semantics would be rewritten, and the Linux kanata path was retired as unusable. |
| Keep the official application and install the fork over it                     | Ships the UI and the Updater, which can replace the fork with official binaries, and installs over the user's own Karabiner.                           |
| Keep a user with their own Karabiner on shared mode (plan recommendation Q1-a) | The maintainer preferred one runtime with an explicit, default-on option to close other instances.                                                     |
| Suppress the managed output key codes in the event tap                         | Loses real Space, Return and Backspace presses, which the shipped defaults make collide with remapped outputs.                                         |
| Attribute origin by timing, order, PID, user data or sender identity           | Real runs produced identical fields for a remapped Escape and a physical Space.                                                                        |
| An Ergopti DriverKit extension or `IOHIDUserDevice`                            | Needs Apple entitlements and a Developer ID; refused even as root.                                                                                     |
| Obtain an Apple Developer ID for notarization and `SMAppService.daemon`        | Declined by the maintainer.                                                                                                                            |

## Evidence in the codebase

- The plan and its work packages:
  `docs/handovers/2026-09-29-overnight/hs274-delivery-plan.md` (section 6
  records these answers).
- The realigned invariants: `docs/memory/macos-hammerspoon.md`
  (`project-hs-owned-remap-runtime`, `project-hs-karabiner-exact-lease-isolation`,
  `project-hs-fork-admission-in-both-launch-modes`).
- The dual-mode description: `static/ergopti_plus/macos/platform/remap/README.md`
  and `static/ergopti_plus/macos/launcher/README.md`.
- R3 stays enforced for stock processes by
  `static/ergopti_plus/macos/tests/meta/test_karabiner_stock_process_isolation.lua`
  until the owned runtime lands together with the exact code it must allow.
