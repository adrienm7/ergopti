<!-- docs/design/linux-number-row-runtime.md -->

# Linux number-row values at runtime

Status (2026-10-27): not applied yet; emulation is planned. Linux and macOS
keep `layout.direct_access_digits` and `layout.number_row_reorder_edges` in
`config.toml` and restore them, but do not apply them yet. The maintainer wants
number-row emulation on macOS and Linux with live reload, tracked by its own
TODO item. This note is the design input for that item. It replaces the TODO
item "Linux layout and number-row values read at runtime".

## How each driver treats the two settings

| Driver  | Number-row ordering (`direct_access_digits`)                                                                                                                                                                   | Edge keys (`number_row_reorder_edges`)                      |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| Windows | Applied. The driver emulates the layout, and `#HotIf NumberRowEffectiveMode()` hotkeys retype the ten digit keys (`modules/keymap/layout.ahk`, `layout/digit_row_bindings.ahk`, `layout/number_row_send.ahk`). | Applied with the ordering.                                  |
| macOS   | Not applied. The layout is installed as a system input source and the system types the row. The menu row is read-only: `number_row_policy.native_rows` with `platform_reason.number_row_override_unsupported`. | Not applied, same reason.                                   |
| Linux   | Not applied. The layout is installed as a system XKB layout. The menu row is read-only, through the same shared provider.                                                                                      | Not applied. The hook has no code for the edge keys at all. |

The shared policy says the same thing. `number_row_policy.capable()` grants
`digits` and `symbols` to `ahk` only. The manifest comments on both features say
that only Windows reorders the row.

## Why Linux does not apply them yet

These are the constraints the emulation item has to answer. They are not
reasons to refuse it.

1. **The model is the system layout, as on macOS.** On macOS and Linux, Ergopti
   installs the layout into the system, and the system decides what each key
   types. That is why the layout emulation switches are Windows-only
   (`platform_reason.layout_emulation_is_windows_only`). Reordering the number
   row would make the Linux hook retype ten keys of the system layout on every
   press. That is a partial emulation, the one thing the Linux design avoids,
   and it would differ from macOS unless macOS gains the same emulation.
2. **The only Linux backend for it is not qualified.** d70c2d9aa3 added an
   opt-in number-row owner to `adapters/keyboard_hook.lua` (`_number_row`, fed by
   `start({ numberRowMode = ... })`). It depends on
   `xkb_capture.capture_receiving_rows`, which refuses unless the native backend
   carries `desktop_proof` and the XKB source probe has a receiving capability.
   Its own commit lists what is still missing: native lifecycle, Writer/Xorg
   association, installation and physical delivery. It has never been shown to
   type a key on a real desktop. A live menu row on top of it would offer a
   change to typed input that refuses on most desktops and cannot be checked
   on this host.
3. **The stored values are still worth keeping.** `config.toml` can be shared
   with a Windows machine. The Linux scope participant restores and clears
   these rows (bdec8cfc06) so that a restore on Linux does not lose the Windows
   choice. It does not reorder anything on Linux.

## What the live version needs

The dormant owner from d70c2d9aa3 stays in place as a possible base. Once it
has been checked on a real Linux desktop, the work is smaller than a hook
restart.

- **No hook restart.** The hook already replaces the number-row owner at an
  event boundary: `_number_row.retire()` then `_number_row.construct()`, which
  `_number_row.drive()` already calls when the native epoch changes. A mode
  change would set `_capture_options.numberRowMode` and `_number_row.mode`, then
  retire and construct. The grab stays held, so no key is lost. A key held down
  under the old owner is suppressed until it is released, as `retire()` already
  does. No other key is refused, so nothing needs counting.
- **The hotstring buffer stays as it is.** The grab is never released and no
  `stop()` runs, so the buffer, the tap-hold engine and the CapsWord state are
  untouched. A real `stop()`/`start()` would end the word (`_locks.end_word`) and
  drop the held keys, which is why it must not be used for a setting change.
- **Reading the values.** `main()` would read both rows through
  `infra.config_paths` and the manifest default, and pass `numberRowMode` at
  `keyboard_hook.start`. The edge keys would need their own owner first, since
  the Linux hook has none.
- **Acknowledgement.** The participant's `apply` and `restore` would call the
  hook's mode setter and treat its report as the native receipt: `true` with an
  active owner, or the effective mode `native` with the policy reason. The
  transaction stays owed until that report arrives, as it does for every other
  native scope.

## Current state and follow-ups

- The menu rows stay read-only on Linux and macOS until the emulation lands.
  Their reason text, `platform_reason.number_row_override_unsupported`, says
  that this system does not reorder the row yet: the installed system layout
  types it, and only Windows emulates the layout today.
- `infra/keyboard_layout_scope.lua` stays config-only for now. Its header and
  log line say that the rows are not applied yet, and point to this note for
  the acknowledgement it must add.
- The dormant Linux number-row owner from d70c2d9aa3 stays in place. It is
  unreachable today, because nothing passes `numberRowMode`.
