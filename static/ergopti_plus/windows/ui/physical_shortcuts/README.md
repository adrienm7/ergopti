# physical_shortcuts (Windows)

STATUS: host and editor built; delivery refused. `PhysicalShortcutDeliveryAvailable`
(`host.ahk`) answers false until the maintainer qualifies physical delivery on
real Windows hardware (maintainer decision of 2026-11-11). The menu row is
therefore greyed with `physical_shortcuts.delivery_unqualified`, the editor
stays closed and no scope is captured.

The page, its strings and its policy are shared: `_shared/ui/physical_shortcuts/`
is the page; this folder ports the Lua owners the page talks to, as the Windows
driver has no Lua runtime.

- `slots.ahk` — `physical_slots.lua`: canonical `physical_<mods>_<W3C code>`
  slots and the registry's `ahk` scan code (`SCnnn`).
- `editor.ahk` — `physical_entries.lua`, `physical_editor.lua` and
  `physical_editor_window.lua`: the planner, the page session (drafts, exact
  source receipts, one key per capture request) and the closed message
  protocol. The init packet carries `names` from the shared key name table
  (`KeyNamePhysicalLabel`), never an id or a W3C code.
- `host.ahk` — the WebView2 host (`PhysicalShortcutsWindow extends
WebViewHost`, WebView only: no native fallback), the configuration scope
  (`PhysicalShortcutsScope`) and the menu port (`PhysicalEditorMenu`,
  `physical_editor_menu.lua`).

Key position capture is `KHCapturePosition` / `KHCancelPosition` /
`KHPositionCaptureAvailable` in `adapters/keyboard_hook.ahk`: one key-down of
the shared InputHook, physically down, hands `native_code` (`SCnnn`) and the
physically held `mods`; AltGr is refused, nothing is suppressed.

Before the getter may answer true, Windows also needs a collision owner (the
Linux `physical_collisions` counterpart): `PhysicalShortcutsScope.Edit` refuses
every mapping without one, and a delivery owner that dispatches a bound
physical slot. The hardware qualification steps are in TODO.md.
