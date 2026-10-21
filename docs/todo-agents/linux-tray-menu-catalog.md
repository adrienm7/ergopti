# Linux tray menu in the AppImage catalogue (PR #10422)

Handoff for the agent that owns the "catalogue screenshot shows only the tray
icon" item of `docs/ERGOPTIPLUS_TODO.md`.

## Findings

- The catalogue (`code/worker.sh` of AppImage/appimage.github.io) first looks
  for any visible named window (`xdotool search --onlyvisible --name .`). Only
  without one does it rerun the AppImage beside `stalonetray`, start `icewm`,
  left-click the icon centre, wait 3 s, and screenshot the active window if
  one exists. Otherwise it right-clicks the same spot, waits 2 s and
  screenshots the trimmed root window.
- libayatana 0.5.90 (`src/app-indicator.c`, `fallback()`) already pops the
  GtkMenu on both `activate` (left) and `popup-menu` (right) of its
  GtkStatusIcon fallback. The left click opened our two-row menu, then the
  catalogue's right click landed outside the grabbed menu and closed it before
  the screenshot. A popup menu is override-redirect, so it never becomes the
  active window.

## Fix

- Degraded keyboard-access state (`infra/input_access.lua`): a real menu
  (status row, show details, open logs folder, report a bug, quit), plus a
  centred status window titled "Ergopti+" that explains the failure. The
  catalogue's first pass then finds a window and screenshots it.
- `platform/tray/appindicator.lua`: status window binding.
- Smoke `tools/build/appimage-oldest-lts.sh`: asserts the status window and
  that a left and a right click on the docked icon map a menu popup.

## Remaining

- Only CI (`appimage-oldest-lts.sh smoke`) and the catalogue `/retest` after
  the next release can confirm the X11 behaviour; no Linux host here.
