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
- [ ] <!-- field-point: local_server_rows_paused --> Local server rows while paused (EDD-1, `edd1-local-server-rows`):
      with LM Studio or oMLX running and listed in the model selector page's API group, pause Ergopti+: the server's
      models stay listed and live; choose one, then set an address (« Local server at another address ») and a key: each
      is saved at once and the page shows the choice, its rows without actions until the resume. « Search for local
      servers again » shows the paused notification once and probes nothing: no « probed » log line while paused, «
      Local server discovery paused » at the pause. Resume: the servers are searched again and the rows act.
- [ ] <!-- field-point: managed_ollama_cold_start --> Managed Ollama cold start on a quiet desktop (OLL-06,
      2026-11-20): after a new login, with nothing else running, turn the AI on and time the start of Ergopti's own
      Ollama to its readiness (the AI menu turning ready; the log lines of the service start and of the version
      probe that answered), once with the runtime already installed and once right after its first install. Linux
      probes every 3 s up to what is left of the 30 min install budget, macOS waits at most 30 s: the two figures
      decide one bound for the three.
- [ ] <!-- field-point: tray_host_missing --> No tray host (TRAY-03, fixed 2026-11-21): on GNOME (Wayland, then X11)
      without the AppIndicator extension, start the daemon with `--tray`: about 15 s after « Tray icon created » a
      window « Ergopti+ has no tray icon on this desktop » and a notification say it in the configured language and
      name `gnome-shell-extension-appindicator`, and the log holds « No tray host (watcher false, host nil, XEmbed tray
      false) ». Then enable the extension, log in again: nothing is said and the log holds « Tray host present ». On
      KDE Plasma and on an X11 panel with only an XEmbed tray (i3bar, an old XFCE panel), nothing is said either. On
      GNOME and KDE, left-click and right-click the icon (both open the menu?) and let Orca read it: « Ergopti+ », then
      « Ergopti+ (paused) » after a pause.
- [ ] <!-- field-point: update_windows --> Updates and download windows (UPD-02 to UPD-09, 2026-11-21), on a
      standalone install offered a newer release, Orca on: About > Check for updates; Orca reads « Checking for
      updates… » then the answer without a focus move, and Escape closes the window. Click Update, then Cancel in the
      download window: it reads « Update download cancelled », never « Ollama download cancelled »; note whether the
      menu still offers the update (UPD-08: it does not today). Click Update again and close the download window
      while it downloads: note whether the release installs once downloaded (UPD-05: the log says « native install
      refused » today) and whether the bar ever moves from 0 % (UPD-07).
- [ ] <!-- field-point: metrics_views --> Metrics dashboards (MET-04 to MET-07, MET-09, MET-10, MET-12, 2026-11-21), Orca on, interface in
- [ ] <!-- field-point: layout_tool_pages --> Layout manager and Ergopti Studio (LTP-02, LTP-06, LTP-07,
      2026-11-21), Orca on, interface in English: Layout > « Install or remove layouts… » and Ergopti Studio are read
      in English, not with a French voice. Tab to « Use » or « Update » on a layout already installed and press
      Space: after the answer the focus is still on that row (its button, or its name while the operation runs).
      Escape closes the layout manager. Do not install or remove a layout you need.
- [ ] <!-- field-point: metrics_views --> Metrics dashboards (MET-04 to MET-07, 2026-11-21), Orca on, interface in
      English: in the typing dashboard change the dates: Orca reads « Reading the selected period… » and the loader
      says the same; with `db.sqlite` made unreadable (`chmod 000`, then put it back) a new date range says at once
      that it could not be read instead of spinning for 2 min (MET-05, MET-06). Numbers read `12,345` and `1.2M`
      (MET-07). In the apps dashboard, a notice of an incomplete read clears on the next complete answer without
      closing the window (MET-04). With an AZERTY keymap, then with the Ergopti emulation on, the heatmap names
      the keys as they type (A on the Q key), also after a date change (MET-09). Type in another window with the
      dashboard open: the character, bigram and word tables follow within a few seconds, and typing does not
      stutter at each refresh (MET-10). Hovering a card definition reads it in English (MET-12).
      closing the window (MET-04). A past range with no typing reads « No data » on every card (MET-13); Tab reaches
      the activity calendar's « Chart values » and Orca reads each day and its count (MET-16); Reset pressed while a
      flush is still being written says in the status line that it failed (MET-19).
      closing the window (MET-04).
- [ ] <!-- field-point: small_native_units --> Daily note (SNU-08, SNU-09, 2026-11-21): make
      `~/.local/share/ergopti/notes` read-only (`chmod 500`, then put it back) and take a note: the notification says
      it failed and the log holds « Daily note refused: today's note could not be created as a regular file. ». With
      no text/plain handler on a launcher that fails (`xdg-mime default broken.desktop text/plain`, then restore it),
      the log holds « the desktop text editor could not be launched ». The configuration file's
      `shortcuts.take_note` folder and dated rows show the reason that says where the Linux note goes.
- [ ] <!-- field-point: tray_icon_missing --> Missing tray logo (TRAY-05, 2026-11-21): on a desktop with a tray host,
      in a copy of the install, move `_shared/tray/data/ergopti_tray_paused.png` away and start the daemon with
      `--tray`: running, the usual logo; pause: the panel draws the themed warning sign, not the running logo, Orca
      reads « Ergopti+ (paused, icon file missing, reinstall Ergopti+) » in the configured language, and the log
      holds one error naming the file, not one per pause; resume: the logo comes back. Put the file back.
      updates… » then the answer without a focus move, and Escape closes the window. Click Update: the bar moves with
      the download (UPD-07); Cancel reads « Update download cancelled », never « Ollama download cancelled », and the
      menu still offers « Update now » (UPD-08). Click Update again and close the download window while it
      downloads: the release installs once downloaded and the daemon restarts on it, the notice saying so only once
      the restart is armed (UPD-05, UPD-09). With the network down, the failed check names its cause when curl proves
      one (UPD-06).
- [ ] <!-- field-point: pickers_prompts --> Pickers and prompts (PCK-03, PCK-04, PCK-06, PCK-09, 2026-11-21), Orca
      on: AI > Generation > Context length > Other value…, type « 250,5 » then Save: the window stays open and Orca
      reads « Enter a whole number of characters from 80 to 4000. »; type « 1800 »: it saves and closes. Temperature
      accepts « 0,7 ». Then open a shortcut's action picker and close it with the title bar's close button: reopening
      it shows the new binding's title (PCK-06). Finally bind open_app and choose a `.desktop` file on the Desktop:
      an error dialog says no binding was saved, instead of closing silently (PCK-09). The model selector closes on
      Escape (PCK-19); in Arabic, the action picker lays out right to left and Orca reads it in Arabic (PCK-22).
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
      Optimiser: the « Optimiser » tab opens the optimizer; after « Analyse my typing », « My typing » is its chosen
      corpus; « Optimize » with 10 s runs to « Done » with a score, the window staying usable while it runs on the page;
      « Open in the editor » opens the result in a new tab of « Éditer » and « Compare with other layouts » adds it in «
      Comparer »; its choices are back after closing and reopening the window. « Ma frappe » at once (2026-11-21):
      open the Studio once and wait for « Ma frappe » (`studio_ngrams.json` appears beside `metrics.sqlite`, mode
      0600), restart the driver, type a few words, reopen the Studio: « Ma frappe » is the chosen corpus within a
      second (the saved read), then its counts change a little when the fresh read lands, without changing a corpus
      picked meanwhile. After the dashboard's « Purge » or cache reset, the next Studio open shows no saved read.
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
      touchpad, an incremental slot's action fires while the fingers move (`gestures/engine/incremental_tracker.lua`),
      with the step rule and reversal shared with macOS; the travel is in millimetres from the touchpad's own
      resolution (EVIOCGABS), so the steps set in `[gestures.sensitivities]` and in each swipe slot's submenu match
      the distance swiped; a pad that reports no resolution fires once, as x1, said in the log.
- [ ] <!-- field-point: typing_burst_widget --> Typing-speed widget bursts (TWD-2, 2026-11-16): with the widget on,
      type a sentence: it shows; an arrow, F5, Ctrl+C, Ctrl alone, Alt alone, Super alone, a click, a one-pixel
      pointer move or a touchpad scroll hides it at once; Shift and AltGr (alone, held, together), Backspace, Enter
      and Tab keep it. Then add the XKB option `lv5:rctrl_switch`: Right Ctrl tapped alone keeps the widget (a level
      key there, `twd2-keymap-role`); with `ctrl:nocaps`, CapsLock tapped alone hides it.
- [ ] <!-- field-point: eject_removable_disk --> Eject a real removable disk: with a USB stick the session mounted
      (from the file manager), a gesture bound to `eject_all_disks` unmounts each of its mounted partitions and powers
      the drive off through udisks and polkit, with no root prompt: the stick leaves `lsblk` and the file manager,
      and the system's own disks stay mounted. The hosted CI runner has no removable or hot-plugged disk, and a loop
      device is neither, so the action rightly skips it there.
- [ ] <!-- field-point: x11_layout_install --> Layouts on an X11 session (LCP-01, 2026-11-19): in « Installer ou
      retirer des dispositions… » install Ergo-L, then « Utiliser »: the next typed letters follow Ergo-L with no
      sudo, `xkbcomp -xkb $DISPLAY -` names `ergol`, plugging a keyboard keeps it (GNOME and Plasma under X11), and
      « Désinstaller » takes it out of `~/.config/xkb`. In Studio, « Installer » a source does the same. After a new
      login the daemon loads the layout last selected again (LCP-08, `x11_selection.txt` in the layouts folder):
      `xkbcomp` names `ergol` once the daemon has started, and after « Désinstaller » a new login keeps the
      desktop's own layouts. With Ergopti emulated, Ctrl+è sends the letter chosen under « Raccourcis sur les lettres
      accentuées » (LCP-07).
- [ ] <!-- field-point: kde_input_sources_live --> Live layout switch on KDE Plasma: with two layouts in System
      Settings > Keyboard, Layout > « Input sources » switches the active layout at once through the Plasma keyboard
      daemon (`org.kde.keyboard /Layouts setLayout`), on Wayland and on X11; the daemon's `getLayout` answers the
      chosen index, the next typed letter follows it, and kxkbrc's LayoutList keeps its order. GNOME is proved in CI
      by `run_input_sources_live.sh gnome`; no hosted runner starts a Plasma session with kded.
- [ ] <!-- field-point: agent_desktop_connectors --> AI agent desktop connectors: an accepted calendar event and an
      accepted reminder open the default calendar application (GNOME Calendar, KOrganizer or Thunderbird) on the
      `.ics` import with the agent's title, date and time, and the private temporary file is gone after the daemon
      stops; an accepted mail opens a draft in the default mail client through xdg-email (or the mailto: link when
      xdg-email is missing) with its subject, body and recipients, and nothing is sent. The runner has no
      calendar or mail client, so the unit lane checks only the argument vectors.
- [ ] <!-- field-point: one_folder_name --> One folder name
      ([handoff](docs/tooling/one-folder-name-handoff.md#what-the-maintainer-checks-on-each-machine)): check the Linux
      machine against the handoff's Linux list (`~/.config/ergopti_plus`, `~/.local/state/ergopti_plus` and
      `~/.local/share/ergopti_plus` gone, the daemon log listing each move, the old
      `~/.cache/ergopti_updater_etag_*.txt` files deleted); the migration is removed only once the maintainer's
      machines pass.
- [ ] <!-- field-point: accessibility_orca --> **Accessibility with Orca** ([audit](docs/audits/accessibility/README.md)): 1. The AppIndicator icon and
      menu from the keyboard (GNOME with its extension, KDE): Orca reads « Ergopti+ », and « Ergopti+ (en pause) »
      once paused (the icon's description, set since the third pass); every item runs. 2. The GTK dialogs (text
      entry, entry with choices, list): Orca reads each field with its caption, and a dialog opened without a
      title is « Ergopti+ » in Alt+Tab. 3. Studio and the other WebKit windows: title read, focus inside the page
      on open, Tab walks every control. 4. With the screen reader on (Super+Alt+S, so
      `org.gnome.desktop.a11y.applications screen-reader-enabled` is true): a hotstring preview and an AI
      prediction are spoken when they appear (the window is an AT-SPI notification named by its rows; check
      Accerciser if Orca stays silent), within five seconds of turning it on; off, nothing is spoken. With the
      screen reader on, the spotlight shortcut makes Orca say « Pointeur de la souris mis en évidence » once per
      press (the ring window is a notification; the crosses on other monitors say nothing), and Accerciser shows
      the WPM widget's window named by its speed (« 72 MPM »), renamed when the speed changes, with nothing
      spoken; off, both stay unnamed. 5. GNOME high contrast
      (`org.gnome.desktop.a11y.interface high-contrast`): the previews turn opaque within five seconds; note what
      should follow « Reduce animation ». 6. « Large text » (`gsettings set org.gnome.desktop.interface
      text-scaling-factor 1.5`, X11 and Wayland): within five seconds the hotstring and AI previews draw their
      text 1.5 times larger and the panel grows with it; the GTK dialogs (text entry, list) follow at once
      through GTK itself; check whether the Studio and the other WebKit windows follow too (not handled by the
      driver); the WPM pill keeps its size, as on Windows.
- [ ] <!-- field-point: backspace_restore --> **Backspace restore** (`hotstrings.backspace_restore_enabled`,
      `hotstrings.backspace_restore_window_ms`, menu Hotstrings > Parameters), in a GTK editor and a terminal:
      1. `td★` expands, then Backspace at once leaves `td` (no ★). 2. `po★` gives `poo`, Backspace leaves `po`.
      3. `adn` then Space expands, Backspace at once leaves `adn ` (lowercase, the Space kept), and a word-start
      hotstring typed next fires; same with a comma and with Enter. 4. Window 500 ms: a Backspace within half a
      second undoes, one after a full second only deletes the last character (`ADN`); with the window at 2000 ms
      a Backspace after one second still undoes. 5. Any key (Escape, a letter) between the expansion and the
      Backspace: plain Backspace. 6. Option off: Backspace deletes the last character every time; on again, the
      undo returns without a restart. A custom window (e.g. 750) typed in the free entry is kept after a restart.
- [ ] Screen-reader switch of the previews (2026-11-21): with Orca on, Hotstrings > Preview bubbles >
      « Read previews to the screen reader » ticked by default: a preview and a finished AI prediction are said;
      untick it: both still draw and nothing is said; tick it again: said again, without a restart.
