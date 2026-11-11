# Linux layout checks closed by container proofs (2026-11-10)

Container proofs for the TODO.md "To confirm on Linux" lines on layout
emulation, layout switching, the user-tree layouts (W1 to W4), the accented
shortcuts and the Bépo Compose rule, run under the maintainer decision of
2026-11-10 (`docs/memory/maintainer-decisions.md`: a container proof closes a
Linux check). Every `.txt` beside this file is the receipt one run printed
(scratch paths replaced by `<scratch>`).

## Environment

- Ubuntu 24.04 container: Xvfb (X.Org 21), openbox, GNOME Shell 46.0 on
  mutter 46.2 (`--headless --wayland`, logind from python-dbusmock on a private
  system bus, a RemoteDesktop virtual keyboard so XWayland receives mutter's
  keymap), sway 1.9 (headless backend), mousepad 0.6.1 (GTK 3.24.41), kwrite
  (KDE Frameworks 5, Qt 5), AT-SPI 2.52.
- Ubuntu 26.04 chroot (debootstrap from the Ubuntu archive) for Plasma 6:
  KWin 6.6.4 on Wayland (`--virtual`) and on X11 (`kwin_x11` on Xvfb with
  kded6's keyboard module).
- The daemon's own chain: `layout_emulation` (production collaborators),
  `adapters/keyboard_layout` and `adapters/xkb_capture` on the server's real
  keymap (libxkbcommon), the injector, the modifier broker and the uinput
  writer. Only the last hop is replaced: `tests/hardware/lib/xtest_uinput_backend.lua`
  writes each evdev event to the X server through XTest (keycode + 8).

## How to run again

From `static/ergopti_plus/linux`:

- `bash tests/hardware/run_layout_typing_live.sh [receipt]` (needs Xvfb,
  openbox, xdotool, xclip, mousepad, kwrite, the AT-SPI bus and the Python
  GObject bindings);
- `bash tests/hardware/run_input_sources_live.sh x11|gnome|kde|kde-x11|sway`;
- `runuser -u <user> -- bash tests/hardware/run_input_sources_live.sh gnome|kde tests/hardware/run_user_layout_wayland_live.lua`
  (the installer refuses desktop writes as root; on GNOME the script exits 3
  after its first phase and runs again on a restarted shell, a new login);
- `python3 tests/hardware/run_xkb_group_name_identity.py` (also in CI).
- `runuser -u <user> -- bash tests/hardware/run_x11_reapply_live.sh gnome|kde`
  (W4; needs xinput).

## Results

| TODO line                         | Receipt                                          | Outcome                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| --------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Layout emulation over AZERTY (fr) | `layout_typing_live.txt`                         | Closed. The 30 hand-read vectors of `keylayout_vectors.json` for Ergopti, Ergopti➕ and Ergo-L (letters, Shift, CapsLock, AltGr, dead keys, chained dead keys, multi-character output, the AZERTY-dead `^` key) typed into GTK and Qt and handed to the character path; Ctrl + Ergopti c copies, Ctrl + Ergopti z undoes; a row switched off types AZERTY.                                                                                                                                                                                                                                                                      |
| Accented shortcuts                | `layout_typing_live.txt`                         | Closed. Ctrl+é copies in GTK and Qt with « é → C »; AltGr+é types the layout's level 3; Ctrl+2 with digits first stays Ctrl+KEY_2 on the wire.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Layout switching                  | `input_sources_*.txt`                            | KDE Plasma 6.6.4 Wayland and X11, openbox X11 and sway closed (listing, ticks, menu switch, pause start/resume rules; `getLayoutsList` answers `a(sss)` on both Plasma sessions). GNOME Shell 46 open: see the findings.                                                                                                                                                                                                                                                                                                                                                                                                        |
| W1 to W4                          | `user_layout_wayland_*.txt`, `x11_reapply_*.txt` | GNOME W1 to W3 closed after one login (Bépo: the user-tree slot loads with `ERGOPTI_SEVEN_LEVEL`, the digits-first build under the other slot replaces it with no restart; a layout registered during the session answers `needs_relogin`). W4 answered: GNOME Shell 46 and Plasma 6 under X11 put their own layouts back when a keyboard appears (GNOME also on an input-sources setting change), never on a layout switch; the daemon now loads the layout again (one re-apply after a new keyboard, on both). KDE W1 to W3: inconclusive (Ergopti run), the headless XWayland does not follow KWin without a focused client. |
| Bépo monnaie then cédille         | `layout_typing_live.txt`                         | Qt types ₢ at once. GTK 3 open: see the findings.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |

## Bugs the proofs found, fixed

- `a1a8cf98` the emulated shortcut wrote beside the output broker, which then
  refused all output.
- `f7541d24` the row switches were ignored on Linux and macOS (the registry's
  JSON nulls).
- `0601d1a8` an ownerless (empty) clipboard was refused, so every clipboard
  route expansion failed on a fresh session.
- `03a47899` an X11 layout named with non-ASCII characters (Bépo, the shipped
  « Français — Ergopti » files) made the daemon refuse to type with keys.
- GNOME Shell 46 reads `~/.config/xkb/rules/evdev.xml` only when it starts:
  apply-wayland selected an id registered after login, the shell fell back to
  `us` and the read-back ended `not_loaded`. It now answers `needs_relogin`
  for such an id, registers both slots and leaves the setting alone. The
  headless proof also needs a key event for XWayland to receive a new keymap
  (a Shift tap every 300 ms in `run_input_sources_live.sh gnome`).

## Findings left open

- **Fixed 2026-11-11 in the switch adapter (`input_sources_gnome.txt`, read back from the shell itself; the installer's `apply_gnome` is still open): GNOME Shell 46 ignores runtime writes of `mru-sources` and `current`.**
  On a `sources` change the shell keeps its in-memory MRU list (keyboard.js
  `_updateMruSources`), and a non-interactive activation writes no
  `mru-sources`, so the switch the adapter plans changes nothing on a running
  shell (checked with the shell's own `currentSource` in unsafe mode). Writing
  `sources` as `[target]`, then `[target, other]`, then the user's list makes
  the shell activate the target and keeps the list, but only when the shell
  has processed each write; a gsettings client gets no acknowledgement, so the
  fix needs the session keymap (XWayland) as the acknowledgement.
- **Corrected 2026-11-11: GNOME Shell does list a user-tree layout** once its `rules/evdev.xml` is in `~/.config/xkb` (`bepo` became current with the new switch sequence; the earlier reading was taken too soon). The original note read: With `sources = [('xkb', 'bepo')]`
  and Bépo only in `~/.config/xkb`, mutter's XWayland keymap is Bépo with
  `ERGOPTI_SEVEN_LEVEL`, while the shell's InputSourceManager falls back to
  `us` (GnomeXkbInfo does not know the id).
- **Fixed 2026-11-11 (`bepo_compose_gtk3.txt`): GTK 3 composed nothing from the managed `~/.XCompose`.** GTK 3.24 ignores includes and overflows on many multi-character outputs; the block now repeats the single-character rules inline. mousepad's built-in
  input method compiles no Compose cache from it (an include of a file that
  itself includes `%L`) and types the borrowed trigger « ⅕ ». Qt composes ₢.
  A desktop running IBus (GNOME) composes through IBus instead.
- **Fixed 2026-11-11: the KDE layout id depended on the session type.** The middle field of
  `getLayoutsList` is Plasma's display label (`''` on Wayland, the short name
  on X11), not a variant: the same layout is `us` on Wayland and `us(us)` on
  X11, so a pause layout stored on one does not match on the other.
