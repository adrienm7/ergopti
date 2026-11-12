# Menus and tray: composition and refresh

Audited source: `b74634f0` (`claude/ergopti-todo-parity-b`, on `dev`).
Date: November 12, 2026.

## Scope

The census area `ui/menu` on each OS (the most changed one: 42 members on
macOS, 23 on Windows, 20 on Linux) with shared `modules/menu` and `lua/menu`:
how the tray is composed from the shared manifest, which rows a pause greys,
and what rebuilds it after a change made from Ergopti or behind its back.
Windows (`windows/ui/menu/`, `windows/infra/manifest_menu.ahk`,
`windows/ui/gesture_conflicts.ahk`) is the read-only reference. Source reading
plus the Lua menu suites; no tray was rendered natively.

## Checked and kept

- Composition: the three trays render `_shared/modules/menu/menu_manifest.json`
  (generated from `menu.toml`) through one renderer per language (shared
  `lua/menu/renderer.lua`, `manifest_menu.ahk`), with the same
  `disabled_reason_key` and `disabled_reasons` rules; a row whose getter is
  missing is refused on every OS.
- Pause: the nine feature rows marked `greyed_when_paused` (tap-holds,
  shortcuts, gestures, keyboard layout, hotstrings, metrics, AI, agent, apps)
  are greyed by the three drivers from that mark (`menu_init.ahk:121`, macOS
  `builder.lua:886`, Linux `builder.lua:404`); Linux also drops the row's
  submenu and action so no tray backend can run it.
- A setting changed from the menu (error window, pause layout switch, start
  at login, a language) rebuilds the tray once the change is confirmed:
  Windows `RebuildTrayMenu`, macOS `updateMenu`, Linux `on_menu_changed`.
  Windows and macOS reload after a language change; Linux publishes the
  locale through its script scope and rebuilds.
- A change behind Ergopti's back: Windows re-reads the system gesture
  settings when the Gestures submenu opens and rebuilds once on a change;
  macOS re-reads them on the `[gestures] system_prefs_recheck_ms` timer and
  its state listener rebuilds the menu, with a Refresh row; Linux cannot read
  the desktop's gesture settings and shows those slots as unknown with a
  settings shortcut (`gesture_system_linux_children`), by design.

## Measured, not proposed

- The Linux About build runs the startup helper twice and synchronously
  (`command_available` and `enabled`, each `start_at_login.sh status`). Ten
  reads take 0.10 s in the authoring container with a stub `systemctl`, about
  10 ms each; a real `systemctl --user is-enabled` adds its own start. Below
  the threshold that would justify a cache; revisit with a profile of a real
  session (perf-profiling skill).

## Left

- The Windows rebuild triggers for the asynchronous user hotstring load, the
  agent and the updater were read but their Lua counterparts not traced end to
  end; native tray rendering and receiving are unqualified.
