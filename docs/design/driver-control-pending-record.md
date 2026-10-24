<!-- docs/design/driver-control-pending-record.md -->

# Driver control: the pending record (item 142, Linux successor)

The local reload command (`_shared/modules/control/driver_control.json`) lets a
tool ask the running driver to reload and read the answer in `reload.result`.
Until now a `requested` result had to name the successor process, because the
reloaded driver completes the request only when the pending record names its
own pid. Windows launches its successor and knows the pid; macOS `hs.reload`
keeps the pid. A Linux restart under systemd or through the detached relay
cannot know the pid beforehand, so Linux reloaded the hotstrings in process and
the three drivers did not share a reload.

## Decision

The protocol gains a TTL-bound pending record. The schema stays 1: every field
below is additive, and a result that names its successor is byte for byte what
it was.

| State       | Written by                | Fields beyond `schema`, `request_id`, `state`, `driver_pid`      |
| ----------- | ------------------------- | ---------------------------------------------------------------- |
| `requested` | the driver being replaced | `successor_pid` (an integer, or `null` when unknown), `deadline` |
| `claimed`   | the successor, once up    | `successor_pid` (its own pid), `deadline` kept                   |
| `completed` | the successor             | `successor_pid` (its own pid)                                    |
| `refused`   | either                    | `reason` (closed list)                                           |
| `timeout`   | the successor, or a tool  | `reason` is always `deadline`                                    |

`deadline` is Unix time in seconds. It is required exactly when
`successor_pid` is `null`, and the declaration fixes the lifetime of a pending
record in `pending_ttl_seconds`. A `requested` result that names its successor
carries no deadline and behaves as before.

### Transitions

1. The replaced driver admits the request, writes `requested` with
   `successor_pid: null` and `deadline = now + pending_ttl_seconds`, then asks
   its restart owner. A refused restart overwrites the record with `refused`.
2. The successor reads the record once it is ready:
   - `requested`, `successor_pid` null, deadline not passed: it writes
     `claimed` with its own pid, then `completed`, or `refused` with the
     reason of its boot (for example the personal source was still pending).
   - deadline passed: it writes `timeout` and never `completed`. The stale
     record is not claimed.
   - `claimed` by another pid, `completed`, `refused`, `timeout`, or a record
     it cannot read: left alone. A second claim is refused by construction.
3. A tool that sees a `requested` record with a null successor and a passed
   deadline reports `timeout` itself, without waiting for a driver.

The named-successor path is unchanged: `requested` naming pid P is completed
only by P. The same corpus (`_shared/tests/corpus/control/driver_control.json`)
pins the result texts and the resolution table for the AutoHotkey port and for
the shared Lua policy that macOS and Linux run.

## Linux

Reload, from the tray, SIGHUP, the local command, the paths editor and the
reload shortcut, becomes a daemon restart (`infra/daemon_restart.lua`): systemd
restarts the unit, otherwise the detached relay starts the launcher after the
process exited. Window and program cleanup debt still refuses the request as
`busy` before anything is written. A second request while a restart is in
flight joins it. The hotstring file watcher and the magic-key change keep the
in-process catalogue reload: they are not a Reload.

## Not decided here

The relay and systemd restarts cannot be exercised without a Linux host. The
flow is tested with fakes under WSL; a real restart stays a field check.
