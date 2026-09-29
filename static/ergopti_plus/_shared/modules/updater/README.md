# updater (shared data)

## Purpose

Single source of truth for the cross-driver updater: the repository identity,
the release list every update channel reads, the channel registry, and the
automatic-check schedule (frequency presets, boot delay, jitter, failure
backoff, re-evaluation period). The macOS and Linux drivers read these files
at runtime; the Windows driver reads generated AHK copies.

## Key files

| File                         | Description                                                                            |
| ---------------------------- | -------------------------------------------------------------------------------------- |
| `defaults.json`              | Owner and repo, release list URL, automatic-check timing and presets, check-record key |
| `channels.json`              | Update-channel registry, most stable first; tag rule as structured data                |
| `channel_vectors.json`       | Vectors every channel port replays                                                     |
| `schedule.js`                | Canonical automatic-check schedule: due time, snap to a preset, jitter, check record   |
| `schedule_vectors.json`      | Vectors the JavaScript, Lua (`_shared/lua/updater/schedule.lua`) and AHK ports replay  |
| `version.js`                 | Canonical semver order, replayed through `version_vectors.json`                        |
| `version_label_vectors.json` | About version row: locale keys, placeholders and vectors the Lua and AHK ports replay  |

## Generated consumers

- `windows/_generated/update_schedule.ahk` — `npm run codegen:update-schedule`
- `windows/_generated/update_channels.ahk`, the page registry and the launcher
  feed table — `npm run codegen:update-channels`

## Drift gates

- `tools/test/test-update-schedule-contract.cjs`: the schedule vectors, the
  presets' labels in all 21 locales, the generated Windows data and the wiring
  of the Lua and AHK vector tests.
- `tools/test/test-update-channels-contract.cjs`: the channel registry.
- `tools/test/test-updater-constants-single-source.cjs`: the literals a driver
  still carries (repository identity, release list URL) and the absence of a
  hand-copied preset table.

## Adding a frequency preset

1. Add it to `timing.check_interval_presets` in `defaults.json`, in display
   order (`never` stays last).
2. Add `menu.about.frequency.<code>` to all 21 locales.
3. Run `npm run codegen:update-schedule`; the three drivers read the rest.
