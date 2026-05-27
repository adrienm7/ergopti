# Karabiner Generator Snapshot Fixtures

This directory holds **recorded snapshots** of the JSON output produced by
`modules.karabiner.generator.build_karabiner_json` for known input states.
They exist so that any change to the generator's deterministic shaping logic
can be diff-tested against a known-good baseline without spinning up a real
macOS host with Karabiner-Elements installed.

## How to record a snapshot

The recording must be done on a Mac with Karabiner-Elements installed and the
full Hammerspoon driver loaded (so that the actions, tap_hold_keys, and
mod_combos JSON files actually resolve). The recipe:

1. Open the Hammerspoon console.
2. Bring the karabiner module to a known state (e.g. defaults).
3. Run something like:

       local kb = require("modules.karabiner")
       local gen = require("modules.karabiner.generator")
       local out = gen.build_karabiner_json(
           kb.get_state(),
           kb.get_actions(),
           kb.get_tap_hold_keys(),
           kb.get_mod_combos(),
           kb.get_non_canonical(),
           hs.configdir .. "/modules/karabiner/"
       )
       hs.json.write(out, hs.configdir .. "/tests/fixtures/karabiner_configs/defaults.json", true)

4. Commit the resulting JSON file alongside this README.
5. Add a corresponding `tests/unit/modules/karabiner/test_generator_snapshot.lua`
   that loads the fixture and compares it against a fresh generator run.

## Why no fixture is committed yet

The generator depends on action / key / combo JSON files whose layout-resolved
key codes vary by macOS keyboard layout (see `lib.layout`). A snapshot recorded
on Ergopti would not match one recorded on AZERTY/QWERTY. Until we settle on a
layout-stable schema (e.g. by always invoking the generator with a fixed
synthetic `hs.keycodes.map`), the snapshot file is omitted on purpose.

A surface-level smoke test that asserts the public functions exist lives at
`tests/unit/modules/karabiner/test_generator_surface.lua`.
