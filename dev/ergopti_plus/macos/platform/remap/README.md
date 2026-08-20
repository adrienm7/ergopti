# Karabiner bridge

## Purpose

This module generates ErgoptiPlus complex modifications and merges them into the user's existing `karabiner.json`. It also persists the ErgoptiPlus remapping preferences stored in `config_karabiner.toml`.

Karabiner-Elements itself is shared, multi-process infrastructure. Its UI and
menubar process, root Core Service (called `karabiner_grabber` before v15.7),
console user server, user/session agents, observers, watchers, extensions and
`Karabiner-VirtualHIDDevice-Daemon`/DriverKit helpers are never owned, killed,
unloaded, launched or restarted by ErgoptiPlus. The user may hide or disable the
ErgoptiPlus Karabiner menu while keeping stock Karabiner and personal rules active.

## Exact-lease lifecycle

Every generated ErgoptiPlus rule is gated by two generation-specific Karabiner variables:

- `ergopti_mode_<token>` is `0` off, `1` active or `2` paused.
- `ergopti_revoked_<token>` is a monotone tombstone; once it is `1`, no late
  writer can reactivate that generation.

`lease_controller.lua` starts a headless mode of the signed `ErgoptiPlus`
launcher and waits for protocol acknowledgements before publishing state
transitions. Its outer role owns only the Hammerspoon pipes and an exact direct
inner child. The inner role owns only its private socket and each exact direct
`karabiner_cli` child that it creates, signals and reaps. No role enumerates or
signals an existing Karabiner process. Closing Hammerspoon's pipe through normal
quit, reload, Force Quit or a crash makes the surviving native role fence the
captured variables. If the inner or outer role itself disappears, its exact
peer/wait relationship triggers a replacement fence. A heartbeat restores the
desired mode if the shared Core Service restarts and loses runtime variables.
Every CLI attempt is bounded; exact revocation retries until it is proven and
can survive subsequent Hammerspoon teardown.

All other Ergopti engine variables are generation-scoped too. The generator
rewrites the logical `layer_active`, `capsword`, and `ke_held_*` names to
`ergopti_<logical-name>_<token>` in both producers and consumers. Hammerspoon's
asynchronous gesture and CapsWord tasks capture that exact name before launch,
so a late child from generation A cannot mutate generation B or a user's bare
personal variable. Stock variables such as
`system.use_fkeys_as_standard_function_keys` remain intentionally unrenamed.

Deployment is fail-closed: new rules require both the fresh mode and an
unrevoked tombstone, and dependent Hammerspoon resources are started only after
`READY`. Enabling is transactional too: the preference remains disabled until
`READY` and durable persistence both succeed; every earlier failure fences the
fresh exact generation. Pause, resume and stop are acknowledged operations.
Stale callbacks and stale native workers can affect only their captured token.

## User-config isolation

The generator removes or replaces only rules carrying an exact ErgoptiPlus marker. Profiles, devices, parameters, virtual-HID settings, and personal complex modifications are preserved. Historical unleased ErgoptiPlus blocks are migrated only when their complete structure can be proven; ambiguous rules are left untouched and deployment fails instead of deleting user data.

Publication uses the filesystem adapter's proven atomic-write path. The complete
merged file is staged beside the resolved target and renamed into place, so
Karabiner never observes a partially written JSON document. Symlink routes are
revalidated around publication and ambiguous staging artefacts are retained for
diagnosis. Stock Karabiner does not participate in an ErgoptiPlus lock or
compare-and-swap protocol, so ErgoptiPlus makes no claim that it can preserve a
personal edit made concurrently between its read and rename.

`config_karabiner.toml` is the single runtime truth for ErgoptiPlus remapping preferences after first launch. Defaults are recomputed only when the user explicitly resets them.

## Ports used

| Port | Usage |
| --- | --- |
| `FileSystem` | Read/write `config_karabiner.toml`, inspect and atomically deploy `karabiner.json` |
| `Storage` | Persist ErgoptiPlus preferences between sessions |
| `ShellRunner` | Retain the signed native lease worker and its detached exact-revocation fallback |

## Canonical data

Karabiner-Elements is macOS-specific, so its action definitions live beside the driver:

- `platform/remap/data/actions.json` — canonical action dictionary
- `platform/remap/data/tap_hold_keys.json` — tap/hold key definitions
- `platform/remap/data/mod_combos.json` — two-modifier tap, hold, and chord slots

The module optionally supplies its live managed output keycodes to `modules.keylogger.kc_bridge`; that set remains empty unless an exact lease has acknowledged `READY`.

## Lifecycle API

| Function | Description |
| --- | --- |
| `M.init(file_system)` | Load preferences and data, migrate proven legacy rules, and start an enabled lease |
| `M.regenerate()` | Build and merge a fresh token-scoped rule set, then start its lease |
| `M.pause()` / `M.resume()` | Request an acknowledged pause transition for the active generation |
| `M.set_enabled(value)` | Enable or disable only ErgoptiPlus remapping |
| `M.stop()` | Stop ErgoptiPlus resources and revoke its exact lease |
| `M.shutdown(reason)` | Revoke the exact lease for quit or reload without touching shared Karabiner processes |
| `M.open_gui()` | Open the stock Karabiner-Elements UI on an explicit user request |

Menu setters update the in-memory ErgoptiPlus configuration and call `M.regenerate()`; they never take ownership of the Karabiner application or services.
