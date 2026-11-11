# Gestures and touchpad event ownership: Windows, macOS, Linux and shared

Audited source: `0ca3803f` (`claude/ergopti-todo-parity-audit`, from `dev`
`adfc5569`). Date: November 11, 2026.

The register's next module after the hotstring cascade. Windows
(`windows/modules/gestures/*.ahk`) is the read-only reference; the Linux
decoder, incremental tracker, manager and click hold
(`linux/modules/gestures/`), the macOS engine and geometry
(`macos/modules/gestures/`) and the shared modules (`_shared/lua/gestures/`)
were compared with it. Candidates were replayed through the real Linux
tracker and manager under LuaJIT and the real macOS engine under Lua 5.4 with
the `tests.stubs.hs` harness of `test_incremental_tab_step.lua`. No touchpad,
evdev/uinput, Hammerspoon touch device or AHK was executed: these are source
and engine counterexamples. The 2026-11-04 findings (LG-001/002, MG001/002,
WG-001 to 003) were not recounted.

## Source census reconciliation

`tools/audit/source-areas.py --ref HEAD` gives 377 areas against the 363 of
the last pinned census (`2026-11-05-native-ui/source-areas.json`): 14 new, none
removed, 212 changed, as the two earlier November 10-11 campaigns recorded. The
gesture areas changed are Linux `modules/gestures` (12 members) and
`ui/gesture_conflicts.lua`, macOS `modules/gestures` (11) and
`ui/gesture_conflict_notice.lua`, shared `lua/gestures` (3) and Windows
`modules/gestures` (7) and `ui/gesture_conflicts.ahk`.

## Fixed (macOS, Linux and shared)

| Id      | Sequence                                                                                  | Windows                                                   | Before                                                                                         | Regression               |
| ------- | ----------------------------------------------------------------------------------------- | --------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------ |
| GSS-001 | Three-finger incremental swipe toward right_up, 1.5 mm per axis per frame, 0.02 mm jitter | No diagonal slots                                         | Signed by dx + dy, noise on that axis: false reversals, 7 of 12 steps (macOS), 9 of 12 (Linux) | `diagonal-axis-travel`   |
| GSM-001 | Slow right_up swipe, 0.8 mm per axis per frame, right_up bound                            | No diagonal slots                                         | macOS locked the vertical axis in the diagonal band, then refused the swipe at commit: 0       | `diagonal-decided-axis`  |
| GSL-001 | Slow 45 degree or 26.6 degree drifting swipe, incremental                                 | No diagonal slots                                         | Linux restarted its count each time the name turned diagonal: no step while moving             | `diagonal-decided-axis`  |
| GSL-002 | A gesture holds the left or right button (`left_click_toggle`), then any key is pressed   | `click.ahk` `GestureOnKeyDown`: the key press releases it | Linux kept the button down until another toggle, a pause or a disable                          | `click-hold-key-release` |

GSS-001: `gestures.direction.along` projects a displacement on the
direction's own axis; both drivers count and detect reversals with it.
GSM-001 and GSL-001 share one root: inside the band where a diagonal-sector
swipe is classified on its dominant straight axis, a moving swipe locked or
restarted on that guess. `gestures.direction.decided_axis` answers nil there;
the Linux tracker counts only a decided axis, the macOS lock of three fingers
or more waits for one (`Geometry.lockDir`), and a pair keeps its immediate
lock, which is what makes it a scroll. A swipe whose final classification is a
diagonal now runs the diagonal slot on both drivers while it moves, as their
commit already classified it. A 26.6 degree drift with right_up unbound first
fired nothing on either (coordinator default); decided by the maintainer on
2026-11-11: it falls back to the dominant straight slot on macOS and Linux,
live and completed, while a bound diagonal still wins inside the band
(`diagonal-unbound-fallback`). GSL-002: the daemon's
physical key observer releases the held buttons ahead of its privacy gate.

## Decisions pending (behaviour left unchanged)

- **GSD-1, x1 swipes fired while moving.** macOS fires an x1 action live and
  re-arms it (`engine.lua` x1 branch of `triggerLiveAxisIfNeeded`), so one
  touch that goes right then back left fires two; Windows and Linux fire one
  action from the finished swipe.
- **GSD-2, the Linux swipe threshold in device units.** Already recorded as
  policy (linux-gestures report). Since the contact-join change
  `start_reading` reads the pad's resolution but still creates the decoder
  without `swipe_threshold`: the tracker counts millimetres while the
  decoder's swipe minimum and pair-scroll travel stay 120 units (about 10 mm
  at 12 units/mm, 4 mm at 30); the comment in `mt_decoder.lua` claiming a
  scaled threshold is stale.
- **GSD-3, the two-finger incremental minimum.** The Linux tracker uses
  1.5 mm for every finger count; macOS 3.0 (diagonal 5.0) for two fingers
  (`geometry.lua`). Matters only for a two-finger incremental slot. Decided
  by the maintainer on 2026-11-11: 3.0 mm (diagonal 5.0) on both, from the
  one shared value, the timings registry's `[gestures]` `*_minimum_mm`, read by
  both (`pair-incremental-minimum`; a local copy fails
  `test-gesture-defaults-single-source.cjs`). Windows has no live minimum.

## Refuted

A far thumb in a three-contact landing (neither OS fires a three-finger
gesture); a finger-count change after an incremental fire hiding a
four-finger completion on Linux (the decoder refuses the late join);
left/right restarting without a reversal on Linux (`reverse_min` is at most
half the first step); `Sensitivity.coerce` and NaN; stale contact-join size
data (evdev suppresses unchanged values).

## Remaining work

- **Linux:** a physical mouse click does not release a click hold (Windows:
  `mouse_ldown`/`mouse_rdown` subscribers; macOS: mouse taps). The daemon
  reads keyboards and the touchpad, not mouse buttons outside the navigation
  layer; a release needs a pointer button observer (XInput2 raw events on X11,
  the grabbed mouse otherwise).
- **Not reviewed in depth:** Linux `background_commands`, `pointer_spotlight`,
  `pointer_warp`, `system_actions`; macOS `app_switch`,
  `apple_shortcut_action`, `conflicts`, `frame_clock` (skimmed, no finding).
- **Native receiving:** none of the fixes ran on a real touchpad, Hammerspoon
  touch device or X11 server (an XTest-held button and a physical click).
