# actions (shared data)

## Purpose

The single source of truth for every bindable action: gestures, keyboard
slots and tap-holds all offer the same catalogue. No driver reads it at
runtime. `tools/codegen/codegen-action-catalogue.cjs` turns `actions.toml`
into one catalogue per driver, already filtered to that driver's platform,
with the picker order, heading levels and locale keys resolved.

## Key files

| File                   | Description                                                                  |
| ---------------------- | ---------------------------------------------------------------------------- |
| `actions.toml`         | Every action with its platform, keystrokes, parameter kind and requirements  |
| `modifier_chords.json` | The modifier + key matrix each driver registers as chord actions             |

## Generated outputs

| Driver  | File                                      |
| ------- | ----------------------------------------- |
| macOS   | `macos/_generated/action_catalogue.lua`   |
| Linux   | `linux/_generated/action_catalogue.lua`   |
| Windows | `windows/_generated/action_catalogue.ahk` |

## Usage

To add an action: declare it in `actions.toml`, order it in `[sg_order]`,
add its `sg_actions.<id>` label to all 21 locales, implement it in every
driver its `platform` claims, then run `npm run codegen:action-catalogue`
(or `npm run gen`). Each driver's suite compares its generated catalogue with
the set of actions it can actually run, in both directions (tests tagged
`(action-catalogue-parity)`), so a declaration without a handler, or a
handler hidden by its declaration, fails the build.

A parameter kind (`url`, `search_url`, `wrap_pair`) is validated, prompted
for and explained by each driver's gesture module: macOS
`modules/gestures/actions.lua` (`validate_action_parameter`,
`parameter_prompt`, `parameter_error`), Linux `modules/gestures/manager.lua`
(`validate_action_parameter`, `get_action_parameter_prompt`,
`get_action_parameter_error`) and Windows `modules/gestures/config.ahk`
(`GestureValidateActionParameter`, `GestureActionParameterPrompt`). A new kind
is added to all three and to `PARAMETER_KINDS` in the generator in one change;
the `wrap_pair` rule is pinned by
`_shared/tests/corpus/action_parameters/wrap_pair_vectors.json`.
