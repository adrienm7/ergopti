# actions (shared data)

## Purpose

The single source of truth for every bindable action: gestures, keyboard
slots and tap-holds all offer the same catalogue. No driver reads it at
runtime. `tools/codegen/codegen-action-catalogue.cjs` turns `actions.toml`
into one catalogue per driver, already filtered to that driver's platform,
with the picker order, heading levels and locale keys resolved.

## Key files

| File                   | Description                                                                      |
| ---------------------- | -------------------------------------------------------------------------------- |
| `actions.toml`         | Every action with its platform, keystrokes, parameter kind and requirements      |
| `modifier_chords.json` | The modifier + key matrix each driver registers as chord actions                 |
| `send_keys.json`       | Named keys, modifiers and text limit of the send_key/shortcut/text actions       |
| `script_chords.json`   | The four script chords' slots, their key on each driver, the paused actions      |
| `slot_roles.json`      | The neutral slot grammar: modifier roles and the modifier each driver calls them |

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
`shortcut`, `app`, `command`, `path`, `apple_shortcut`) is validated, prompted
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

## User commands, paths and Apple shortcuts

`run_command`, `open_path` and `run_apple_shortcut` carry the `command`,
`path` and `apple_shortcut` kinds, decoded by
`_shared/lua/user_action_parameter.lua` and pinned by
`_shared/tests/corpus/action_parameters/user_action_vectors.json`. They run in
`modules/gestures/user_actions.lua` on macOS and Linux and in
`modules/gestures/apple_shortcut_action.lua` on macOS. Windows is pending
(`docs/tooling/windows-pc-agent-handoff.md`), so the three declare
`hs,linux` and `hs`.

- `run_command` runs `/bin/sh -l -c <command>`: a login shell's environment
  (`/etc/profile` and `~/.profile`; on macOS `/etc/profile` runs
  `path_helper`). A `PATH` set only in `~/.zprofile`, `~/.zshrc` or
  `~/.bashrc` is not read: export it in `~/.profile` or use absolute paths.
  Hidden, it is stopped after `[gestures] run_command_timeout_ms` or once
  its output passes `[limits] user_action_output_bytes`; a non-zero exit is
  logged with its code and notified with the first stderr line; its stdout
  (without the trailing line break) can be typed, up to the `send_text`
  limit of `send_keys.json`, or copied. In a terminal window (macOS
  Terminal, Linux `$TERMINAL` when it names a known terminal, else
  `x-terminal-emulator` and the other terminals of `TERMINALS`) it is the
  user's own window and is not bounded.
- `open_path` opens with `open` (macOS) or `xdg-open`, else `gio open`
  (Linux), and refuses a path that no longer exists with a notice naming it.
- `run_apple_shortcut` stores a shortcut's identifier and name. Each run
  lists the library (`shortcuts list --show-identifiers`) and refuses a
  shortcut that was deleted or renamed by name, then
  `adapters/apple_shortcuts.lua` revalidates the identifier once more and
  invokes `shortcuts run <identifier>`, bounded by
  `[gestures] apple_shortcut_run_timeout_ms`. The selection reaches it as a
  plain-text file (`--input-path`), its text output is read back from
  `--output-path`.

### Security notes

- A `run_command` binding runs anything its text says, with the user's
  rights, as soon as its gesture, key or menu fires: it is exactly as
  trusted as `config.toml`. Ergopti never writes one on its own; a config
  file from someone else must be read before it is used.
- The command text is user configuration and may hold secrets: it never
  reaches the log, the native task log (macOS `run_private`, payload-free) or
  an AppleScript source (Terminal receives it as an `osascript` argument of a
  fixed run handler). Log lines name the action and its exit code only; the
  first stderr line is shown in the user's own notification, never logged.
  The diagnostics redaction (`_shared/modules/diagnostics/redaction.json`)
  therefore never needs to see it. Like any process argument, the command is
  visible to the user's other processes (`ps`) while it runs.
- Paths and shortcut names are not logged either: the notices that name
  them are the user's own.
- The selection a shortcut receives and the text it returns cross the disk
  only as `os.tmpname` files (mode 0600) that are removed after the run.
- Cancelling a shortcut (its deadline, or pausing the action parent) stops
  the `shortcuts` tool. Shortcuts runs a shortcut in its own service, which
  may still finish the actions already handed to it: the tool's exit is the
  only receipt the command line gives.
