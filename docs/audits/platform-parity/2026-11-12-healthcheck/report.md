# Diagnostics page: Windows, macOS and Linux

Audited source: `39d90bc3` (`claude/ergopti-todo-parity-b`, on `dev`).
Date: November 12, 2026.

## Scope

The census area `ui/healthcheck` (changed on the three OSes) with the shared
page (`_shared/ui/healthcheck/`), the shared Lua owners
(`_shared/lua/healthcheck/`: actions, report, share, day log, cleanup,
snapshot) and the schema `_shared/modules/diagnostics/schema.json`. Windows
(`windows/ui/healthcheck/`) is the read-only reference; macOS
`ui/healthcheck/core.lua`, `helpers.lua`, Linux `ui/healthcheck/bridge.lua`.
Source reading; no WebView was rendered.

## Checked and kept

- One action vocabulary: every page message goes through the shared
  validator (`healthcheck/actions.lua`, which the AHK port replays from
  `_shared/tests/corpus/healthcheck/action_vectors.json`) before a host acts;
  ids, never paths or URLs, and bounded texts. A refusal is logged with its
  reason on the three OSes, and a raising action answers `ok = false`.
- The same host actions: `export_snapshot`, `day_log` (opt-in, redacted
  through the shared day-log owner), `cancel`, `refresh` (cancels the probes,
  archives their cleanup state and rebuilds the snapshot with a new export
  revision), `close`, and copy, save, report, open_path and open_settings
  through the shared `Report.perform`. The guided diagnostic collection is
  Windows-only and stated as a capability (`diagnostic_collection = false` on
  macOS and Linux).
- The page stays usable while the driver is paused on the three OSes (it
  changes nothing the driver does; Windows says so in `_HC_OnWebMessage`), and
  each snapshot reports the pause in `input.paused`.
- A late probe or action result is dropped unless its session, snapshot and
  export revision are still current on the three OSes.

## Left

- Native receiving (a real WebView, GitHub form prefill) is unqualified.
