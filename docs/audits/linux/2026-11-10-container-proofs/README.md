<!-- docs/audits/linux/2026-11-10-container-proofs/README.md -->

# Linux container proofs, 2026-11-10

Receipt for the "To confirm on Linux" checks closed in a cloud container under
the maintainer decision of 2026-11-10 (`docs/memory/maintainer-decisions.md`,
"a Linux check the cloud cannot run on real hardware closes on a container
proof").

## Environment

- Ubuntu 24.04 container, kernel 6.18 without `uinput` or evdev: `modprobe` is
  absent and a `mknod` of `/dev/uinput` answers `ENODEV`, so no real input node
  exists.
- The kernel model: `static/ergopti_plus/linux/tests/hardware/virtual_kernel_preload.c`,
  loaded with `LD_PRELOAD` into the unchanged daemon only. `/dev/input/eventN`
  are FIFOs on a tmpfs, `/proc/bus/input/devices` is bind-mounted from the same
  capability bitmaps the shim answers `EVIOCGBIT` with, `EVIOCGRAB` is exclusive
  and logged, and `/dev/uinput` writes are decoded frame by frame. The
  production FFI backends, the device finder, the reader's native custody
  checks, the hook, the engines, the injector and the uinput writer all run as
  shipped.
- Desktops: Xvfb with openbox and the AT-SPI bus (frames delivered through
  XTest, X keycode = evdev code + 8); sway headless (frames delivered by
  `wayland_key_bridge.c`, a persistent `zwp_virtual_keyboard_v1` with the real
  XKB keymap); mutter 46 headless (GNOME's compositor, no data-control).
- Editors: mousepad 0.6 (GTK 3, read back over AT-SPI), the repository's GTK
  password-field fixture, the Wayland and X11 clipboards.

## Command

```sh
sudo bash static/ergopti_plus/linux/tests/hardware/run_container_proofs.sh
```

CI runs it on the `input-display` row of the Linux E2E job ("The container
proofs — navigation pointer, tap-hold copy, AI inline").

## Results

| Proof                                                                                    | Assertions | Result |
| ---------------------------------------------------------------------------------------- | ---------: | ------ |
| `run_nav_pointer_container.py`: middle button = Escape, `3` + `arrow_up`, wheel = volume |         21 | pass   |
| `run_tap_copy_container.py`: sway checked, mutter unchecked, X11 without xclip           |         23 | pass   |
| `run_ai_inline_container.py`: inline prediction into mousepad, none into a password      |         11 | pass   |

Two consecutive full runs: 55 of 55 assertions, exit 0.

## Defect the proofs found and fixed

The navigation proof stopped the daemon: once the layer had given a mouse
back, `EvdevReader.ungrab` renumbered the mouse slot's generation, the next
device watchdog tick judged the mouse's custody by that generation, refused
the source cohort and stopped the keyboard hook. `adapters/keyboard_hook.lua`
now judges a pointer member by its descriptor's open lifetime (`same_open`) and
a keyboard by its input generation. A `SYN_DROPPED` on a mouse renumbers the
slot the same way and is covered by the same rule. The proof's
`(nav-pointer-custody)` assertion fails without the fix.

## Defect the proofs found and left open

On X11 a same-group XKB new-keyboard or map notify, which the server sends on
each switch of the slave keyboard that feeds the core keyboard, revokes the
daemon's layout receipt for good: `adapters/xkb_capture.lua` renews only on a
group change, so the injector routes every later replacement through the
clipboard. The X11 sessions above therefore send one XTEST key before the
daemon starts, so that the core keyboard already follows the device that carries
the daemon's output. Recorded in `TODO.md` under "Remaining code work".
