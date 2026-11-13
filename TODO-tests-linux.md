<!-- TODO-tests-linux.md -->

# ErgoptiPlus checks on a real Linux desktop

The Linux checks only a real desktop can answer; code work stays in [TODO.md](TODO.md).

## To confirm on Linux

Every open line carries a `field-point` id; one `bash tools/dev/collect-linux-field-report.sh` run answers each
of them in `docs/field-reports/linux-<stamp>/todo_summary.md` (probe steps read the session, guided steps prompt the
gestures in the terminal): coverage table, verdicts and what no run can test in
[docs/tooling/linux-field-report-coverage.md](docs/tooling/linux-field-report-coverage.md).

- [ ] <!-- field-point: raw_telemetry --> Raw telemetry (2026-11-11): under X11, move, resize and maximise a window and change monitor:
      `events_window_topo` holds the rows from the libxcb and RandR reads; unplug the network and bring a WireGuard
      tunnel up then down: `events_network` holds the four Internet and VPN kinds.
- [ ] <!-- field-point: wayland_focus --> Wayland focus on GNOME and KDE: after `install.sh` (and a new login on GNOME), the excluded-applications rules and the metrics' per-app attribution follow the focused window under GNOME Shell 45+ and Plasma 6 (and 5): the log says « Listening for GNOME Shell/KWin focus reports », a title change in a browser updates the title, and turning the GNOME extension off makes the identity unknown.

No machine is available. First `bash tools/dev/collect-linux-field-report.sh` on a real desktop: the field run
without a click (53c1766514), the report marks, and `driver_reload` (one daemon restart under a real user manager).

- [ ] <!-- field-point: physical_acceptance --> Physical acceptance: evdev/uinput grabs, polkit, autostart, Wayland and X11; wizard (7) on Wayland; magic key
      grab, injection and hotplug (30); real kernel capture (93: ordered pairs need Xorg or a compositor on real
      evdev nodes). Container pass (2026-11-10): not closable in the cloud container, whose kernel has no uinput or
      evdev (`mknod /dev/uinput` opens with `ENODEV`) and no systemd PID 1, so a real-node grab, the polkit agent,
      the user-manager autostart and real kernel capture cannot run there; the grab and injection on a real kernel
      already run on CI (`run_grab_race.lua`, `run_daemon_live.sh`). The X11 and Wayland halves of the grabbed input
      path now run on the kernel model (`tests/hardware/run_container_proofs.sh`). Left for a runner with uinput:
      sway or Xorg reading the daemon's real virtual keyboard (93); wizard (7) and the magic key (30) not attempted.
- [ ] <!-- field-point: item50_cascade --> Item 50 cascade and the composed layout typed on a physical keyboard.
      Not attempted in the 2026-11-10 container pass; the emulation proof above can type the composer's
      `composed.keylayout` once it is the emulated layout. 2026-11-11, the cascade through the daemon's real main()
      (`tests/e2e/run_e2e.lua`, scripted keyboard, uinput into a model field; the container kernel has no evdev or
      uinput): `fb` + Space, Enter and ★ at 1, 2 and 3 arrows, Space and Enter consumed and not, give the
      `cascade_vectors.json` `fb_*` texts (11 scenarios, neutral and recommended presets). The same Space and Enter
      cases are typed on a uinput keyboard in `run_daemon_live.lua`: CI run 42952845748 (native lane, real
      uinput and grab) received « Facebook » and Space, and « Facebook » then Enter. Left: the
      physical keyboard and the composed layout.
- [ ] <!-- field-point: layout_emulation_w1_w4 --> Layout emulation W1 to W4 of `docs/design/layout-option-emulation.md` on real GNOME and KDE sessions
      Container proof 2026-11-10 (`tests/hardware/run_user_layout_wayland_live.lua`, [receipts](docs/audits/linux-container-proofs/2026-11-10-layouts/README.md)): on GNOME Shell
      46 `apply-wayland` ends `not_loaded` and rolls back (the shell lists no user-tree id, mutter still compiles it);
      on KWin 6.6.4 inconclusive (headless XWayland read-back); W4 not attempted. 2026-11-11: GNOME W1 to W3 hold
      after one login (`user_layout_wayland_gnome.txt`, Bépo: the slot loads with `ERGOPTI_SEVEN_LEVEL`, the
      digits-first build under the other slot replaces it with no restart); a layout first registered during the
      session answers `needs_relogin` and leaves the setting alone. KDE (not re-run with Bépo) still open. W4
      answered (`run_x11_reapply_live.sh`, `x11_reapply_*.txt`): GNOME Shell 46 and Plasma 6.6.4 under X11 put their
      own layouts back when a keyboard appears (GNOME also on an input-sources setting change), never on a switch.
      (dbe176e52b, 9b0a205029, dfb197a1ea), including mutter and KWin reloading a `~/.config/xkb` layout (107).
- [ ] <!-- field-point: owned_gtk_host --> Owned GTK host (split from the window-toggle line): tap delay row and every tray dialog (ca680655d7), group restore and clear, open target, Backspace word start.
- [ ] <!-- field-point: physical_shortcut_delivery --> Physical shortcut delivery (LIN-004): with a physical slot bound, prove on a real keyboard that the source key is
      suppressed exactly once, no other owner (tap-hold, layer, hotstring, magic key) also acts on it, and the action's
      output reaches the focused window under the grab; only that evidence may turn
      `keyboard_shortcuts.physical_delivery_available` true. Delivery proven on the kernel model (2026-11-11):
      `tests/hardware/run_physical_shortcut_container.py` (11 assertions; only its daemon process answers the getter
      true) shows a bound key suppressed exactly once, also held with autorepeat, its action reaching mousepad, and a
      single owner against a hotstring (the slot runs, `xz` never expands), a tap-hold key (Tab keeps its tap), the
      layer (Alt+K keeps ArrowLeft) and the magic key (the slot runs, no ★). Decided by the maintainer on 2026-11-11:
      the getter answers true, every safety refusal kept (done: `test_physical_delivery_available.lua`, the scope
      fixtures and the tray row test pin true and keep each refusal under an explicit false answer). Left on a real
      keyboard: the editor's capture and save (the picker window) and the delivery above under the evdev grab.
- [ ] <!-- field-point: predictions_stop --> Predictions stop on activity (feat/predictions-stop-on-activity): with a slow model, during the spinner move
      the mouse, turn the wheel, touch the touchpad (absolute pad and relative pad), switch window (the 250 ms poll),
      press F5: each cancels and hides. The validation digits and the navigation chords keep a shown prediction.
      Not emulable in the cloud (2026-11-10): the container kernel has no uinput module and no /dev/input
      (`mknod c 10 223` opens with ENODEV), so no pointer, wheel or touchpad device can reach the hook's evdev
      reader, and no compositor runs the spinner or the focused-window poll; the event routing is covered by
      `test_prediction_control_retirement.lua` (« Main cancels AI on pointer activity »).
- [ ] <!-- field-point: input_policies --> Branch `wave3/input-policies` (2026-11-06): with the Bépo registry layout installed, monnaie then cédille
      Container proof 2026-11-10 ([receipts](docs/audits/linux-container-proofs/2026-11-10-layouts/README.md)): Qt (kwrite) types ₢ at once; GTK 3 (mousepad, no IBus) types the
      borrowed trigger « ⅕ » (Linux remaining work); the installed X11 Bépo needed 03a47899. The other parts of this
      line were not attempted. 2026-11-11: GTK 3 and Qt both type ₢ at once (`bepo_compose_gtk3.txt`); left: the
      sticky delay row, the CapsWord menu change, the one-shot Shift and CapsWord device checks.
      types ₢ at once in a GTK and a Qt application (desktop Compose, DKS-001); Tap-holds > sticky delay row changes
      the one-shot wait; a CapsWord menu change applies to the running session. Native one-shot Shift real-device
      output receiving; CapsWord absolute reader and desktop keyboard grouping (moved from the one-shot and
      CapsWord parity follow-ups).
- [ ] Layout editor window (2026-11-13): « Create or edit a layout… » and the layout manager's « Layout editor » open
      the editor in its own WebKitGTK window; a second request brings it to the front with its unsaved work; « Close »
      closes it.
