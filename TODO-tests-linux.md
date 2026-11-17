<!-- TODO-tests-linux.md -->

# ErgoptiPlus checks on a real Linux desktop

The Linux checks only a real desktop can answer; code work stays in [TODO.md](TODO.md).

## To confirm on Linux

Every open line carries a `field-point` id; one `bash tools/dev/collect-linux-field-report.sh` run answers each
of them in `docs/field-reports/linux-<stamp>/todo_summary.md` (probe steps read the session, guided steps prompt the
gestures in the terminal): coverage table, verdicts and what no run can test in
[docs/tooling/linux-field-report-coverage.md](docs/tooling/linux-field-report-coverage.md). No machine is available
yet; the first run also proves the field run without a click (53c1766514), the report marks, and `driver_reload`
(one daemon restart under a real user manager). Container and CI proofs are not physical evidence.

- [ ] <!-- field-point: raw_telemetry --> Raw telemetry: under X11, move, resize and maximise a window and change
      monitor: `events_window_topo` holds the rows from the libxcb and RandR reads; unplug the network and bring a
      WireGuard tunnel up then down: `events_network` holds the four Internet and VPN kinds.
- [ ] <!-- field-point: wayland_focus --> Wayland focus on GNOME, KDE and COSMIC: after `install.sh` (and a new login
      on GNOME), the excluded-applications rules and the metrics' per-app attribution follow the focused window under
      GNOME Shell 45+ and Plasma 6 (and 5): the log says « Listening for GNOME Shell/KWin focus reports », a title
      change in a browser updates the title, and turning the GNOME extension off makes the identity unknown. On
      COSMIC the log says « Listening for cosmic-comp focus reports on zcosmic_toplevel_info_v1 version 2 » on a
      current cosmic-comp (1 on an older one) and the focused application follows the window. GNOME layout switch:
      Layout > « Input sources » switches the layout through the Ergopti extension and the `sources` setting keeps
      its order; with the extension turned off the menu names it.
- [ ] <!-- field-point: physical_acceptance --> Physical acceptance: evdev/uinput grabs, polkit, autostart, Wayland
      and X11; the wizard (7) on Wayland; the magic key grab, injection and hotplug (30); sway or Xorg reading the
      daemon's real virtual keyboard on real evdev nodes (93); touchpad hotplug: with gestures on, unplug a USB or
      Bluetooth touchpad (the log says « lost … looking for a touchpad every 2000 ms » once and the gesture switch
      still commits), plug it back (« A touchpad is back » once) and a bound swipe fires.
- [ ] <!-- field-point: item50_cascade --> Item 50 cascade on a physical keyboard (`fb` + Space, Enter and ★ at 1, 2
      and 3 arrows, consumed and not, as `cascade_vectors.json` `fb_*`), and the composed layout typed on it.
- [ ] <!-- field-point: layout_emulation_w1_w4 --> Layout emulation W1 to W4 of
      `docs/design/layout-option-emulation.md` on real GNOME and KDE sessions, including mutter and KWin reloading a
      `~/.config/xkb` layout (107); KDE is not proved even in a container
      ([receipts](docs/audits/linux-container-proofs/2026-11-10-layouts/README.md)).
- [ ] <!-- field-point: owned_gtk_host --> Owned GTK host: tap delay row and every tray dialog (ca680655d7), group
      restore and clear, open target, Backspace word start.
- [ ] <!-- field-point: physical_shortcut_delivery --> Physical shortcut delivery (LIN-004): on a real keyboard under
      the evdev grab, a bound key is suppressed exactly once, no other owner (tap-hold, layer, hotstring, magic key)
      acts on it, and the action's output reaches the focused window; the editor's capture and save (the picker
      window) work.
- [ ] <!-- field-point: predictions_stop --> Predictions stop on activity: with a slow model, during the spinner move
      the mouse, turn the wheel, touch the touchpad (absolute pad and relative pad), switch window (the 250 ms poll),
      press F5: each cancels and hides. The validation digits and the navigation chords keep a shown prediction.
- [ ] <!-- field-point: input_policies --> Input policies: with the Bépo registry layout installed, monnaie then
      cédille types ₢ at once in a GTK and a Qt application (desktop Compose, DKS-001); Tap-holds > sticky delay row
      changes the one-shot wait; a CapsWord menu change applies to the running session; native one-shot Shift
      real-device output; CapsWord absolute reader and desktop keyboard grouping. GTK 3 Compose through IBus: on a
      KDE or Xfce session with IBus installed and no input method, after installing a Compose layout from the layout
      manager and logging in again, a GTK 3 application (mousepad, gedit) types a multi-character Compose output,
      Layout shows « every sequence, through IBus », and the layout stays the system's; with fcitx5 running the row
      names the input method and `~/.config/environment.d/90-ergopti-ibus.conf` is absent.
- [ ] <!-- field-point: layout_editor_window --> Ergopti Studio window: « Create or edit a layout… », the layout
      manager's « Layout editor » and the top-level « 🎨 Ergopti Studio… » row (right after « Keyboard layout ») open
      one WebKitGTK window titled exactly « Ergopti Studio »; a second request brings it to the front with its unsaved
      work; « Close » closes it. Tabs: « Comparer » shows the layout ranking for a built-in corpus within a second, an
      imported layout is still listed after closing and reopening the window, and « Analyse my typing » then selects
      « My typing ». Autosave: in « Éditer », « + » opens a second layout in its own tab; edit both, kill the driver
      (or close the window), reopen the Studio: both tabs and their unsaved edits are back, from
      `layout_sources/studio_workspace.json`; « Export all » writes `ergopti-studio-layouts.zip` to the Downloads
      folder and « Import » of that file reopens every layout. Formats: « Open » in WebKitGTK's file chooser lists
      .json, .klc and .kbe files, opens a KLAnext JSON (static/layouts/kla_iso) and a UTF-16 .klc, and refuses a
      KbdEdit .kbe with the « KbdEdit encrypts » message. Downloads: the XKB (`<id>_xkb.zip`, built by the host's Lua),
      KLC, DLL, macOS bundle, « KLA / KLAnext JSON » and « Kalamine TOML » downloads land in the Downloads folder, a
      second download of the same file is named « name (2).ext », and the XKB archive installs with the user layout
      installer. Navigation layer: the Tap-Holds menu's « Edit the navigation layer… » row and a gesture bound to
      « Navigation layer » open the Studio on its « nav » layer, holding the current layer key, with the user's
      layers.toml bindings; « Apply the navigation layer » then changes the layer live, and layers.toml starts with
      « # source: » and « # body-fnv1a32: ».
- [ ] <!-- field-point: direct_xkb_levels --> Direct XKB compiler: the XKB export of
      `_shared/tests/corpus/layouts/source/direct_levels.toml` installed with the user layout installer types a, α
      (Right Ctrl, XKB's fifth level), æ (AltGr) and β (Right Ctrl) on a real GNOME or KDE session.
- [ ] <!-- field-point: one_shot_modifiers --> One-shot modifiers: Tap-holds > sticky delay row accepts 0 and shows
      « no time limit », and a one-shot Shift then waits indefinitely; a gesture or key bound to `sticky_ctrl_shift`,
      `sticky_cmd_ctrl` (Super+Ctrl) and `sticky_altgr` wraps the next key in those modifiers once, in a GTK and a Qt
      application; a tap-hold key set to tap `sticky_altgr` and hold AltGr types one AltGr character after a tap.
- [ ] <!-- field-point: shortcut_key_carriage --> Native carriage of `shortcut_key`: the XKB export states what XKB
      cannot carry of `shortcut_key`, and on a real desktop the shortcut sends the shortcut key, through the installed
      layout's Control/Alt/Super level and through Ergopti+ emulation.
- [ ] <!-- field-point: incremental_swipes --> Incremental touchpad swipes (`test_gesture_incremental.lua`): on a real
      touchpad, an incremental slot's action fires while the fingers move (`modules/gestures/incremental_tracker.lua`),
      with the step rule and reversal shared with macOS; the travel is in millimetres from the touchpad's own
      resolution (EVIOCGABS), so the steps set in `[gestures.sensitivities]` and in each swipe slot's submenu match
      the distance swiped; a pad that reports no resolution fires once, as x1, said in the log.
- [ ] <!-- field-point: typing_burst_widget --> Typing-speed widget bursts (TWD-2, 2026-11-16): with the widget on,
      type a sentence: it shows; an arrow, F5, Ctrl+C, Ctrl alone, Alt alone, Super alone, a click, a one-pixel
      pointer move or a touchpad scroll hides it at once; Shift and AltGr (alone, held, together), Backspace, Enter
      and Tab keep it. Then add the XKB option `lv5:rctrl_switch`: Right Ctrl tapped alone keeps the widget (a level
      key there, `twd2-keymap-role`); with `ctrl:nocaps`, CapsLock tapped alone hides it.
- [ ] <!-- field-point: one_folder_name --> One folder name
      ([handoff](docs/tooling/one-folder-name-handoff.md#what-the-maintainer-checks-on-each-machine)): check the Linux
      machine against the handoff's Linux list (`~/.config/ergopti_plus`, `~/.local/state/ergopti_plus` and
      `~/.local/share/ergopti_plus` gone, the daemon log listing each move, the old
      `~/.cache/ergopti_updater_etag_*.txt` files deleted); the migration is removed only once the maintainer's
      machines pass.
