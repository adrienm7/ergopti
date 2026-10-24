# actions (shared data)

## Purpose

The single source of truth for every bindable action: gestures, keyboard
slots and tap-holds all offer the same catalogue. No driver reads it at
runtime. `tools/codegen/codegen-action-catalogue.cjs` turns `actions.toml`
into one catalogue per driver, already filtered to that driver's platform,
with the picker order, heading levels and locale keys resolved.

## Key files

| File                   | Description                                                                 |
| ---------------------- | --------------------------------------------------------------------------- |
| `actions.toml`         | Every action with its platform, keystrokes, parameter kind and requirements |
| `modifier_chords.json` | The modifier + key matrix each driver registers as chord actions            |
| `send_keys.json`       | Named keys, modifiers and text limit of the send_key/shortcut/text actions  |
| `script_chords.json`   | The four script chords' slots, their key on each driver, the paused actions |

## Generated outputs

| Driver          | File                                                                |
| --------------- | ------------------------------------------------------------------- |
| macOS and Linux | `_shared/lua/actions/catalogue_data.lua` (every entry names its OS) |
| macOS           | `macos/_generated/action_catalogue.lua` (filters it, adds aliases)  |
| Linux           | `linux/_generated/action_catalogue.lua` (filters it, adds slots)    |
| Windows         | `windows/_generated/action_catalogue.ahk`                           |

The two Lua drivers share one catalogue: `_shared/lua/actions/catalogue.lua`
keeps the entries that name the driver when its `_generated` file loads, and
`tools/test/test-action-catalogue-shared-projection.cjs` checks that each
driver loads exactly the catalogue the generator's model of it holds.

## Usage

To add an action: declare it in `actions.toml`, order it in `[sg_order]`,
add its `sg_actions.<id>` label to all 21 locales, implement it in every
driver its `platform` claims, then run `npm run codegen:action-catalogue`
(or `npm run gen`). Each driver's suite compares its generated catalogue with
the set of actions it can actually run, in both directions (tests tagged
`(action-catalogue-parity)`), so a declaration without a handler, or a
handler hidden by its declaration, fails the build.

A parameter kind (`url`, `search_url`, `wrap_pair`, `text`, `key`,
`shortcut`, `app`) is validated, prompted
for and explained by each driver's gesture module: macOS
`modules/gestures/actions.lua` (`validate_action_parameter`,
`parameter_prompt`, `parameter_error`), Linux `modules/gestures/manager.lua`
(`validate_action_parameter`, `get_action_parameter_prompt`,
`get_action_parameter_error`) and Windows `modules/gestures/config.ahk`
(`GestureValidateActionParameter`, `GestureActionParameterPrompt`). A new kind
is added to all three and to `PARAMETER_KINDS` in the generator in one change;
the `wrap_pair` rule is pinned by
`_shared/tests/corpus/action_parameters/wrap_pair_vectors.json`, and the
`text`, `key` and `shortcut` rules (over `send_keys.json`, parsed by
`_shared/lua/send_input` and `windows/infra/send_input_parameter.ahk`) by
`_shared/tests/corpus/action_parameters/send_input_vectors.json`.

The shared action picker (`_shared/ui/action_picker/`) edits the `text`, `key`
and `shortcut` kinds itself: a text field, a key capture and a shortcut
capture that validate with the same corpus rules, then post the value with the
pick, which the driver still validates before it stores it. Each host sends
the page `send_keys.json` and the prompts and refusals above; the other kinds
keep the driver's own prompt. `tools/test/test-action-picker-parameter-editor.cjs`
replays the corpus against the page.
