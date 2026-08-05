# Hardware validation — Linux driver

Everything CI cannot check, with the command to run and the answer to expect.

CI covers one real kernel path: `tests/hardware/run_uinput_roundtrip.lua` creates
a virtual keyboard, grabs it, writes events and reads them back, which pins the
ioctl numbers, the struct layout and the capability bits. It runs headless on a
GitHub runner, so it says nothing about a display server, a compositor, a panel,
a keyboard layout or a real user's session. That is what this file is for.

Work top to bottom: a failure early on makes the later results meaningless.

**Run the checklist rather than reading it:**

```bash
bash static/ergopti_plus/linux/tests/hardware/validate.sh
```

It answers everything a machine can answer — permissions, groups, `/dev/uinput`,
display server, keymap dump and its key count, clipboard tools, how many systemd
units are installed, whether anything is hosting a StatusNotifierItem — then
prompts for the dozen checks that genuinely need eyes, and writes one report
covering both halves. `--auto-only` skips the prompts, for a log.

A checklist nobody re-runs stops being true without anyone noticing, which is why
the machine-checkable part is a script. The sections below remain the reference
for what each answer means and what to do when it is wrong.

---

## 0. Before anything

```bash
bash static/ergopti_plus/linux/install.sh
# then log out and back in — group membership is read at session start
id -nG | tr ' ' '\n' | grep -E '^(input|uinput)$'
ls -l /dev/uinput
```

**Expect** both groups listed, and `/dev/uinput` as `crw-rw---- root uinput`.

If `/dev/uinput` is missing, the module is not loaded: `sudo modprobe uinput`.
If it exists but is `root root`, the udev rule did not apply — `sudo udevadm
control --reload-rules && sudo udevadm trigger`.

---

## 1. Capture, on both display servers

The single most important check, because everything else is downstream of it.

```bash
ergopti-hotstrings --verbose 2>&1 | tee /tmp/ergopti.log
```

Type a few words in any application.

**Expect** in the log: `Keyboard device selected: /dev/input/eventN (remap_output)`
when kanata is running, or `(named_keyboard)` when it is not; then
`Grabbed … — the desktop no longer sees this device.`; then a `Key code=` line per
keystroke.

**Expect** on screen: the words you typed, appearing normally. If the keyboard
appears dead, the grab succeeded and the re-emission did not — stop and run with
`--no-grab`, which reads without grabbing.

Repeat the whole section after logging out of X11 and into Wayland (or the other
way round). **Do not reconfigure anything between the two.**

---

## 2. Which device was grabbed

```bash
grep -E 'Remap output device|Skipping synthetic|Keyboard device selected' /tmp/ergopti.log
```

**Expect** the daemon to have chosen the device named exactly `kanata` when the
remap daemon is running. If it chose the physical keyboard instead, the engine is
seeing PRE-remap keycodes and will resolve characters you did not type.

**Expect** `Skipping synthetic device` for `Ergopti Virtual Keyboard`. If that
line is absent and the daemon selected it, expansions will loop.

---

## 3. Accented expansion

The reason the injection path was rewritten.

Type `NT'` in a plain text editor.

**Expect** `N'T`, with the correct apostrophe, at once.

Then a French sentence containing `é à ç è ù «»`. **Expect** every character
correct on YOUR layout — not the US keycode equivalent. On AZERTY, `é` is an
unshifted key; on a US layout with no `é` at all, it should arrive via the
clipboard instead and your previous clipboard contents should still be there
afterwards (`xclip -o` or `wl-paste`).

```bash
grep -E 'Layout resolved|typable character' /tmp/ergopti.log
```

**Expect** `Layout resolved: N typable character(s) via xkbcli dump-keymap-…`
with N in the hundreds. A number under 60 is refused as a parse failure and
logged as such.

Then run the one check here that you do not have to judge — you start it and read
the exit code:

```bash
bash tests/hardware/run_keysym_roundtrip.sh
```

It presses exactly what the driver's layout table says produces each character
and asks the X server, through `xev`, what actually arrived. That closes the only
loop CI cannot: our XKB parse and the server's could agree with each other and
both differ from what we intended — a level index off by one, a shift where AltGr
belonged — and every accented expansion would type the wrong glyph with every
other test still green.

It needs a real Xorg. CI cannot run it: Xvfb is a virtual server with a dummy
keyboard, it has no evdev backend, and a uinput keystroke has no path to reach
it. That was measured, not assumed.

---

## 4. Typing during an expansion (C4)

The corruption this whole milestone exists to fix.

Set up a hotstring with a long replacement, then type its trigger and **keep
typing immediately**, without pausing.

**Expect** the replacement, followed by exactly what you typed afterwards, in
order. Repeat ten times; the output must be identical every time.

A scrambled result means the grab is not held, or events are reaching the
application by a second path.

---

## 5. Autorepeat

Hold a letter down until it repeats a dozen times, then type a trigger.

**Expect** the expansion to erase the right number of characters. If it eats one
character too few per repeat, the buffer is ignoring evdev value 2 again.

---

## 6. Shortcuts do not become text

Press `Ctrl+S`, `Ctrl+A`, `Alt+Tab`, then type a hotstring trigger.

**Expect** no expansion caused by the shortcuts, and the trigger to fire normally
afterwards.

---

## 7. Undo

Fire an expansion, then press Backspace **immediately**.

**Expect** the trigger back, exactly as typed. Pressing Backspace after typing
anything else must NOT restore it.

---

## 8. The click

Type half a trigger, click somewhere else in the document, then finish typing it.

**Expect** no expansion: the caret moved, so the buffer no longer describes the
line.

---

## 9. Tray

```bash
ergopti-hotstrings --tray --verbose
```

**Expect** an icon. Open its menu.

- **KDE, XFCE ≥ 4.16, LXQt, COSMIC, most wlroots panels**: works natively.
- **GNOME**: needs the AppIndicator/KStatusNotifierItem extension. Without it
  there is no icon, and that is a property of GNOME rather than a bug here.
- **dwm, i3, older XFCE**: run `snixembed` alongside.

In the menu, check that: each hotstring category is a SUBMENU with its localised
name and its entry count; its sections are listed with their own counts; toggling
a category greys its sections; and the toggle survives a daemon restart.

---

## 10. Preview tooltip

Type the first characters of a trigger.

**Expect** a dark rounded panel — background `#242424`, corner radius 7, padding
14/7 — listing the candidates with their triggers right-aligned. It must not take
focus (keep typing: the characters must land in your document) and must not
absorb a click (click through it).

**Expect** it to be tinted with the category's colour when "coloured previews" is
on, and untinted when off.

Under GNOME Wayland the panel will appear at the bottom of the screen rather than
at the caret. That is the anchoring cascade reaching its last rung, and it is
expected: no Wayland compositor exposes window geometry to another process.

---

## 11. Session switch (C2)

1. Log in under X11. Confirm sections 1, 3 and 9.
2. Log out.
3. Log in under Wayland. **Change nothing.**
4. Confirm sections 1, 3 and 9 again.

```bash
systemctl --user status ergopti-hotstrings
```

**Expect** the unit to have been stopped and restarted with the session, and the
log to show a fresh `Display server: wayland` line.

---

## 12. Install, per distribution family

On each of Ubuntu/Debian, Fedora, Arch, Alpine, and one immutable
(Silverblue/Kinoite/SteamOS):

```bash
bash install.sh
ergopti-hotstrings --verbose
```

**Expect** no hard abort, and section 1 to pass. On Alpine there is no systemd —
the XDG autostart entry is what starts it, so check `~/.config/autostart/`.

On an immutable distribution, `/usr` is read-only: everything lands in
`~/.local`, and only the udev rule and `modules-load.d` need the one `sudo`.

For NixOS, use the flake in `tools/build/nix/` instead — `install.sh` does not
apply and running it produces a machine that half-works until the next rebuild.
