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

An action that does not claim an OS says why there: `reason_<os>` (`ahk`,
`hs`, `linux`) names a `platform_reason.*` locale key, present in all 21
locales, and `equivalent_<os>` may list the actions that do the same on that
OS. The generator refuses a missing reason, a reason on an OS the row claims
and an equivalent that OS does not offer, then writes the table below.

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
`modules/gestures/apple_shortcut_action.lua` on macOS. On Windows the first two
run in `windows/infra/user_actions.ahk`, which owns the Windows path spelling
(`windows_path_vectors` of the same corpus); `run_apple_shortcut` declares `hs`.

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
  user's own window and is not bounded. Windows runs `cmd.exe /d /s /c` with
  the same bounds, or `/k` in a new console; the lines of a script run in turn,
  joined by `&`, so a block spread over several lines is written on one.
- `open_path` opens with `open` (macOS), `xdg-open`, else `gio open`
  (Linux), or `ShellExecute` (Windows), and refuses a path that no longer exists with a notice naming it.
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

## Availability on each OS

<!-- BEGIN GENERATED availability: tools/codegen/codegen-action-catalogue.cjs; do not edit -->

Generated from `actions.toml` by `npm run codegen:action-catalogue`; edit the rows there. "yes" lists
the requirements the picker checks; "no" points at the reason below and at the
actions that do the same on that OS. The modifier + key shortcuts
(`modifier_chords.json`) exist on every OS and are not listed.

### Single actions

| Action | Label | Windows | macOS | Linux |
| --- | --- | --- | --- | --- |
| `none` | ∅ Nothing | yes | yes | yes |
| `left_click_toggle` | 🖱 L Left click (hold) | yes | yes | yes (session:x11, tool:xdotool) |
| `right_click_toggle` | 🖱 R Right click (hold) | yes | yes | yes (session:x11, tool:xdotool) |
| `lookup` | 🔍 Word definition | no, R1 | yes | no, R1 |
| `app_switcher` | ⇥ System Alt+Tab | yes | no, R2; use `system_app_switcher` | yes |
| `system_app_switcher` | ⇥ System Alt+Tab | no, R3; use `app_switcher` | yes | no, R3; use `app_switcher` |
| `app_previous` | ⇥ Previous app — all screens | no, R3; use `app_switcher` | yes | no, R3; use `app_switcher` |
| `app_previous_screen` | ⇥ Previous app — this screen | no, R3; use `app_switcher` | yes | no, R3; use `app_switcher` |
| `app_window_previous` | ◱ → Next window, no switcher (Alt+Esc) | yes | no, R2; use `win_app_next` | yes |
| `alt_tab_windows` | ◱ Previous window — all screens | yes | yes | no, R4; use `win_next` |
| `alt_tab_monitor` | ◱ Previous window — this screen | yes | yes | yes (session:x11, tool:timeout, tool:xdotool, tool:xrandr, tool:xprop, tool:xwininfo, tool:sha256sum) |
| `cmd_shift_tab` | ⇥ Least recent app — all screens | no, R3; use `app_switcher` | yes | no, R3; use `app_switcher` |
| `copy` | ⎘ Copy | yes | no, R5 | yes |
| `paste` | ⎘ Paste | yes | no, R5 | yes |
| `paste_plain` | ⎘ Paste without formatting | yes | yes | yes |
| `cut` | ⎘ Cut | yes | no, R5 | yes |
| `undo` | ↩ Undo | yes | no, R5 | yes |
| `redo` | ↪ Redo | yes | no, R5 | yes |
| `select_all` | ⬚ Select all | yes | no, R5 | yes |
| `find` | 🔍 Find | yes | no, R5 | yes |
| `save` | ⌘S Save | no, R5 | yes | no, R5 |
| `opt_backspace` | ⌫ ⌥+Backspace | no, R6; use `ctrl_backspace` | yes | no, R6; use `ctrl_backspace` |
| `opt_delete_fwd` | ⌦ ⌥+Delete | no, R6; use `ctrl_delete` | yes | no, R6; use `ctrl_delete` |
| `cmd_backspace` | ⌫ ⌘+Backspace | no, R7 | yes | no, R7 |
| `cmd_delete_fwd` | ⌦ ⌘+Delete | no, R7 | yes | no, R7 |
| `enter` | ↵ Enter | yes | yes | yes |
| `tab` | ⇥ Tab | yes | yes | yes |
| `escape` | ⎋ Escape | yes | yes | yes |
| `backspace` | ⌫ Backspace | yes | yes | yes |
| `delete` | ⌦ Delete | yes | yes | yes |
| `send_key` | ⌨ Press a key [configurable] | yes | yes | yes |
| `send_shortcut` | ⌨ Press a shortcut [configurable] | yes | yes | yes |
| `send_text` | ⌨ Type a text [configurable] | yes | yes | yes |
| `tab_new` | ⧉ + New tab | yes | yes | yes |
| `tab_close` | ⧉ × Close tab | yes | yes | yes |
| `tab_prev` | ⧉ ← Previous tab | yes | yes | yes |
| `tab_next` | ⧉ → Next tab | yes | yes | yes |
| `nav_back` | ← Back (navigation) | yes | yes | yes |
| `nav_forward` | → Forward (navigation) | yes | yes | yes |
| `win_prev` | ◱ ← Previous window, all apps (cycle) | yes | no, R2; use `win_app_prev` | yes |
| `win_next` | ◱ → Next window, all apps (cycle) | yes | no, R2; use `win_app_next` | yes |
| `win_app_prev` | ◱ ← Previous window of the active app | yes | yes | no, R8; use `win_prev` |
| `win_app_next` | ◱ → Next window of the active app | yes | yes | no, R8; use `win_next` |
| `close_window` | ◱ × Close window | yes | yes | yes |
| `fullscreen` | 📺 Fullscreen | yes | yes | yes |
| `snap_left` | ◧ ← Snap left | yes | yes | yes |
| `snap_right` | ◨ → Snap right | yes | yes | yes |
| `maximize` | 🔲 Maximize | yes | yes | yes |
| `space_prev` | ▢ ← Previous Space | no, R9; use `desktop_prev` | yes | no, R9; use `desktop_prev` |
| `space_next` | ▢ → Next Space | no, R9; use `desktop_next` | yes | no, R9; use `desktop_next` |
| `space_prev_wrap` | ▢ ← Previous Space (circular) | no, R9; use `desktop_prev_wrap` | yes | no, R9; use `desktop_prev_wrap` |
| `space_next_wrap` | ▢ → Next Space (circular) | no, R9; use `desktop_next_wrap` | yes | no, R9; use `desktop_next_wrap` |
| `mission_control` | ▢ Mission Control | no, R10; use `task_view` | yes | no, R10 |
| `app_expose` | ◱ App Exposé | no, R10; use `task_view` | yes | no, R10 |
| `desktop_prev` | ▢ ← Previous desktop | yes | no, R9; use `space_prev` | yes |
| `desktop_next` | ▢ → Next desktop | yes | no, R9; use `space_next` | yes |
| `desktop_prev_wrap` | ▢ ← Previous desktop (circular) | yes | no, R9; use `space_prev_wrap` | yes (session:workspaces) |
| `desktop_next_wrap` | ▢ → Next desktop (circular) | yes | no, R9; use `space_next_wrap` | yes (session:workspaces) |
| `desktop_new` | ▢ + New desktop | yes | no, R11 | no, R12 |
| `desktop_close` | ▢ × Close desktop | yes | no, R11 | no, R12 |
| `task_view` | ▢ Task View | yes | no, R10; use `mission_control` | no, R10 |
| `minimize_all` | ◱ Minimize all | yes | yes | yes (session:x11, tool:wmctrl, tool:xdotool) |
| `arrow_up` | ↑ Arrow Up | yes | yes | yes |
| `arrow_down` | ↓ Arrow Down | yes | yes | yes |
| `arrow_left` | ← Arrow Left | yes | yes | yes |
| `arrow_right` | → Arrow Right | yes | yes | yes |
| `word_prev` | W ← Previous word | yes | yes | yes |
| `word_next` | W → Next word | yes | yes | yes |
| `line_up` | ↕ ↑ Previous line | yes | yes | yes |
| `line_down` | ↕ ↓ Next line | yes | yes | yes |
| `line_start` | ⇤ Line start | yes | yes | yes |
| `line_end` | ⇥ Line end | yes | yes | yes |
| `para_prev` | ¶ ↑ Previous paragraph | yes | yes | yes |
| `para_next` | ¶ ↓ Next paragraph | yes | yes | yes |
| `doc_start` | ⤒ Document start | yes | yes | yes |
| `doc_end` | ⤓ Document end | yes | yes | yes |
| `home` | ⇱ Home | yes | yes | yes |
| `end` | ⇲ End | yes | yes | yes |
| `page_up` | ⇞ Page Up | yes | yes | yes |
| `page_down` | ⇟ Page Down | yes | yes | yes |
| `sel_up` | ✎ ↑ Select Up | yes | yes | yes |
| `sel_down` | ✎ ↓ Select Down | yes | yes | yes |
| `sel_left` | ✎ ← Select Left | yes | yes | yes |
| `sel_right` | ✎ → Select Right | yes | yes | yes |
| `sel_word_prev` | ✎ W ← Sel. prev. word | yes | yes | yes |
| `sel_word_next` | ✎ W → Sel. next word | yes | yes | yes |
| `select_word` | ▭ Select word | yes | yes | yes |
| `select_line` | ☰ Select line | yes | yes | yes |
| `selection_uppercase` | AA Uppercase | yes | yes | yes |
| `selection_lowercase` | aa Lowercase | yes | yes | yes |
| `selection_titlecase` | Aa Title Case | yes | yes | yes |
| `uppercase_selection` | AA Uppercase / lowercase | yes | yes | yes |
| `titlecase_selection` | Aa Title Case / lowercase | yes | yes | yes |
| `wrap_selection` | ⟦⟧ Wrap the selection [configurable] | yes | yes | yes |
| `surround_parens` | () Wrap the line in parentheses | yes | yes | yes |
| `llm_generate_prediction` | ✨ Generate an AI prediction | yes | yes | yes |
| `llm_prompt_prediction` | ✨ AI prediction with a chosen prompt [configurable] | yes | yes | yes |
| `llm_predict_raw` | ✨ Generate an AI prediction (Raw) | yes | yes | yes |
| `llm_predict_basic` | ✨ Generate an AI prediction (Basic) | yes | yes | yes |
| `llm_predict_advanced` | ✨ Generate an AI prediction (Advanced) | yes | yes | yes |
| `llm_predict_batch_advanced` | ✨ Generate an AI prediction (Batch Advanced) | yes | yes | yes |
| `llm_predict_rewrite` | ✨ Generate an AI prediction (Rewrite) | yes | yes | yes |
| `llm_predict_tone_familiar` | ✨ Generate an AI prediction (Familiar) | yes | yes | yes |
| `llm_predict_tone_neutral` | ✨ Generate an AI prediction (Neutral) | yes | yes | yes |
| `llm_predict_tone_formal` | ✨ Generate an AI prediction (Formal) | yes | yes | yes |
| `llm_predict_tone_very_formal` | ✨ Generate an AI prediction (Very formal) | yes | yes | yes |
| `llm_predict_translate_en` | ✨ Generate an AI prediction (Translate → English) | yes | yes | yes |
| `llm_predict_translate_ja` | ✨ Generate an AI prediction (Translate → Japanese) | yes | yes | yes |
| `llm_tone_more_formal` | 🎩 More formal (selection) | yes | yes | yes |
| `llm_tone_more_familiar` | 👕 More familiar (selection) | yes | yes | yes |
| `llm_tone_more_formal_cycle` | 🎩 More formal (selection, cycling) | yes | yes | yes |
| `llm_tone_more_familiar_cycle` | 👕 More familiar (selection, cycling) | yes | yes | yes |
| `llm_live_prompt_toggle` | ⚡ Live mode with a prompt [configurable] | yes | yes | yes |
| `llm_screen_region` | 👁 Answer a screen region [configurable] | yes | yes | yes |
| `llm_screen_full` | 👁 Answer the whole screen [configurable] | yes | yes | yes |
| `llm_screen_error` | 🩺 Why this error? (screen region) [configurable] | yes | yes | yes |
| `llm_translate_context` | 🌐 Translate the current sentence [configurable] | yes | yes | yes |
| `llm_translate_selection` | 🌐 Translate the selection [configurable] | yes | yes | yes |
| `llm_agent_selection` | 🤖 What can I do with this? (selection) | yes (ai:on) | yes (ai:on) | yes (ai:on) |
| `llm_agent_command` | 🤖 Command for the AI agent… | yes (ai:on) | yes (ai:on) | yes (ai:on) |
| `llm_agent_auto_toggle` | 🤖 Automatic action detection (on/off) | yes | yes | yes |
| `vol_up` | 🔊 + Volume + | yes | yes | yes |
| `vol_down` | 🔊 - Volume - | yes | yes | yes |
| `mute` | 🔇 Mute/Unmute | yes | yes | yes |
| `brightness_up` | ☀ + Brightness + | yes | yes | yes |
| `brightness_down` | ☀ - Brightness - | yes | yes | yes |
| `track_play` | ⏯ Play/Pause | yes | yes | yes |
| `track_next` | ⏭ Next track | yes | yes | yes |
| `track_prev` | ⏮ Previous track | yes | yes | yes |
| `screenshot_window_clipboard` | 📸 ⊞ Copy window | yes | yes | yes |
| `screenshot_window_save` | 📸 ⊞ Save window | yes | yes | yes |
| `screenshot_region_clipboard` | 📸 ⬚ Copy region | yes | yes | yes |
| `screenshot_region_save` | 📸 ⬚ Save region | yes | yes | yes |
| `screenshot_fullscreen_clipboard` | 📸 🖥 Copy screen | yes | yes | yes |
| `screenshot_fullscreen_save` | 📸 🖥 Save screen | yes | yes | yes |
| `screen_record` | ⏺ Screen recording | yes | no, R13; use `screen_capture` | no, R13; use `screen_capture` |
| `lock_screen` | 🔒 Lock screen | yes | yes | yes |
| `notification_center` | 🔔 Notifications | yes | yes | yes |
| `spotlight` | 🔍 Spotlight | no, R14 | yes | no, R14 |
| `show_desktop` | 🖥 Show desktop | yes | yes | yes (session:x11, tool:wmctrl) |
| `sleep_displays` | 🌙 Put the displays to sleep | yes | yes | yes (session:x11, tool:xset) |
| `toggle_dark_mode` | 🌓 Dark mode (on/off) | yes | yes | yes (tool:gsettings) |
| `mic_mute_toggle` | 🎙 Mute/unmute the microphone | yes | yes | yes (tool:pactl) |
| `clear_clipboard` | 📋 Clear the clipboard | yes | yes | yes |
| `center_mouse` | 🖱 Center the mouse on the screen | yes | yes | yes (session:x11, tool:xdotool, tool:xrandr) |
| `open_app` | 🚀 Open an application [configurable] | yes | yes | yes (tool:gtk-launch) |
| `open_path` | 📂 Open a file or folder [configurable] | yes | yes | yes |
| `run_program` | ▶️ Run a program [configurable] | yes | yes | yes |
| `run_command` | ⌨️ Run a shell command [configurable] | yes | yes | yes |
| `run_apple_shortcut` | 🧩 Run an Apple shortcut [configurable] | no, R15; use `run_program` | yes | no, R15; use `run_command`, `run_program` |
| `quit_frontmost_app` | ✕ Quit the active app | yes | yes | yes (session:x11, tool:xdotool, tool:xprop) |
| `force_quit_frontmost` | ⚠ Force quit the active app | yes | yes | yes (session:x11, tool:xdotool, tool:xprop) |
| `empty_trash` | 🗑 Empty the trash | yes | yes | yes (tool:gio) |
| `eject_all_disks` | ⏏ Eject all disks | yes | yes | yes (tool:lsblk, tool:udisksctl) |
| `clear_notifications` | 🔕 Clear notifications | no, R16; use `notification_center` | no, R16; use `notification_center` | yes |
| `remove_quarantine_selection` | 🛡 Remove the quarantine from the selected files | no, R17; use `unblock_file_selection` | yes | no, R17 |
| `unblock_file_selection` | 🛡 Unblock the selected files | yes | no, R17; use `remove_quarantine_selection` | no, R17 |
| `make_executable_selection` | ⚙ Make the selected files executable | no, R18 | yes | yes |
| `open_terminal_here` | ⌨ Open a terminal here | yes | yes | no, R19 |
| `new_text_file_here` | 📄 New text file here | yes | yes | no, R19 |
| `screen_capture` | 📸 System screenshot tool | yes | yes | yes |
| `screen_capture_instant` | 📸 Instant capture (window) | yes | yes | yes |
| `ocr_screenshot` | 📷 OCR screenshot (Win+Shift+T) | yes | no, R20; use `screen_capture` | yes (tool:tesseract) |
| `open_chatgpt` | Open ChatGPT (URL set in menu) | yes | yes | yes (tool:xdg-open) |
| `open_url` | 🌐 Open a link [configurable] | yes | yes | yes (tool:xdg-open) |
| `open_downloads` | 📥 Downloads folder | yes | yes | yes (tool:xdg-open, tool:xdg-user-dir) |
| `open_file_manager` | 🗂 File manager | yes | yes | yes (tool:xdg-open) |
| `open_system_settings` | ⚙ System settings | yes | yes | yes |
| `pick_color` | 🎨 HEX colour under cursor | yes | yes | yes |
| `open_emoji_picker` | 😀 Emoji picker | yes | yes | yes |
| `take_note` | 📝 Take a note | yes | no, R21 | yes (tool:xdg-open, tool:xdg-mime) |
| `activity_simulation` | 🖱 Simulate activity (anti-sleep) | yes | yes | yes (tool:systemd-inhibit) |
| `display_mirror_toggle` | 🖥 Mirror displays (on/off) | yes | yes | no, R22 |
| `search_web` | 🔍 Web search [configurable] | yes | yes | yes (tool:xclip, tool:xdg-open) |
| `copy_selected_path` | 📋 Copy the path, or open / search the selection | yes | yes | yes (tool:xclip, tool:xdg-open) |
| `teleport_mouse` | 🖱 Teleport mouse | yes | yes | yes (session:x11, tool:xdotool, tool:xrandr) |
| `spotlight_mouse` | 🔦 Mouse spotlight | yes | yes | yes (session:x11, tool:xdotool, tool:xrandr) |
| `toggle_capslock` | ⇪ Toggle CapsLock | yes | yes | yes |
| `microsoft_bold` | 𝐁 Ctrl+B Microsoft (→ Ctrl+G) | yes | no, R23 | no, R23 |
| `one_shot_shift` | ⇧ OneShotShift | yes | no, R4; use `sticky_shift` | yes |
| `caps_word` | ⇪★ CapsWord | yes | no, R4; use `capsword` | yes |
| `ctrl_backspace` | ⌫ Ctrl+BackSpace | yes | no, R6; use `opt_backspace` | yes |
| `ctrl_delete` | ⌦ Ctrl+Delete | yes | no, R6; use `opt_delete_fwd` | yes |
| `space` | ␣ Space | yes | yes | yes |
| `caps_lock` | ⇪ CapsLock | yes | no, R4; use `toggle_capslock` | yes |
| `layer_on` | 🗂 Nav layer ON | no, R24 | yes | no, R24 |
| `layer_off` | 🗂 Nav layer OFF | no, R24 | yes | no, R24 |
| `capsword` | ⇪★ CapsWord | no, R4; use `caps_word` | yes | no, R4; use `caps_word` |
| `sticky_shift` | 📌 Sticky Shift | no, R4; use `one_shot_shift` | yes | no, R4; use `one_shot_shift` |
| `sticky_ctrl` | 📌 Sticky Ctrl | yes | yes | no, R25 |
| `sticky_cmd` | 📌 Sticky Cmd | yes | yes | no, R25 |
| `sticky_option` | 📌 Sticky Option | yes | yes | no, R25 |
| `sticky_cmd_shift` | 📌 Sticky Cmd + Shift | yes | yes | no, R25 |
| `sticky_cmd_option` | 📌 Sticky Cmd + Option | yes | yes | no, R25 |
| `sticky_cmd_ctrl` | 📌 Sticky Cmd + Ctrl | yes | yes | no, R25 |
| `sticky_option_shift` | 📌 Sticky Option + Shift | yes | yes | no, R25 |
| `sticky_option_ctrl` | 📌 Sticky Option + Ctrl | yes | yes | no, R25 |
| `sticky_ctrl_shift` | 📌 Sticky Ctrl + Shift | yes | yes | no, R25 |
| `sticky_cmd_option_shift` | 📌 Sticky Cmd + Option + Shift | yes | yes | no, R25 |
| `sticky_cmd_option_ctrl` | 📌 Sticky Cmd + Option + Ctrl | yes | yes | no, R25 |
| `sticky_cmd_shift_ctrl` | 📌 Sticky Cmd + Shift + Ctrl | yes | yes | no, R25 |
| `sticky_option_shift_ctrl` | 📌 Sticky Option + Shift + Ctrl | yes | yes | no, R25 |
| `sticky_hyper` | 📌 Sticky Hyper | yes | yes | no, R25 |
| `open_metrics_typing` | 📊 Typing stats | yes | yes | yes |
| `open_metrics_apps` | 📊 App stats | yes | yes | yes |
| `open_hotstrings_editor` | ⌨ Hotstrings editor | yes | yes | yes |
| `open_paths_editor` | 📂 Paths editor | yes | yes | yes |
| `open_hotstrings_settings` | ⚙ Hotstring delays and colors | yes | yes | yes |
| `open_layout_manager` | ⌨ Keyboard layouts | yes | yes | yes |
| `open_layer_editor` | 🧭 Navigation layer | yes | yes | yes |
| `open_model_browser` | 🤖 Model catalogue | yes | yes | yes |
| `open_changelog` | 📜 Releases | yes | yes | yes |
| `open_healthcheck` | 🩺 System diagnostics | yes | yes | yes |
| `open_script_source` | 🛠 Source code | yes | yes | yes |
| `open_personal_shortcuts` | 👤 Personal shortcuts file | yes | yes | yes |
| `open_personal_hotstrings` | 👤 Personal hotstrings | yes | yes | yes |
| `open_personal_info` | 👤 Personal info | yes | yes | yes |
| `open_config` | ⚙ Configuration | yes | yes | yes |
| `open_logs_folder` | 📁 Logs folder | yes | yes | yes |
| `open_today_log` | 📄 Today's log | yes | yes | yes |
| `open_error_log` | 📄 Today's errors file | yes | yes | yes |
| `script_pause_toggle` | ⏸/▶ Suspend / Resume | yes | yes | yes |
| `script_reload` | ↻ Reload | yes | yes | yes |
| `script_save_reload` | ↻ Save and reload | yes | yes | yes |
| `script_quit` | ✕ Quit | yes | yes | yes |
| `open_console` | ▤ Console | no, R26 | yes | no, R26 |
| `open_window_spy` | Window Spy | yes | no, R26 | no, R26 |
| `open_list_vars` | Variable state | yes | no, R26 | no, R26 |
| `open_key_history` | Key history | yes | no, R26 | no, R26 |

### Continuous swipes (axis actions)

| Action | Label | Windows | macOS | Linux |
| --- | --- | --- | --- | --- |
| `tabs` | ⧉ Tabs | no, R27; use `tab_prev`, `tab_next` | yes | no, R27; use `tab_prev`, `tab_next` |
| `char` | A Characters | no, R27; use `arrow_left`, `arrow_right` | yes | no, R27; use `arrow_left`, `arrow_right` |
| `char_sel` | ✎ A Sel. Characters | no, R27; use `sel_left`, `sel_right` | yes | no, R27; use `sel_left`, `sel_right` |
| `line_arrow` | ↕ Lines (Arrows) | no, R27; use `arrow_up`, `arrow_down` | yes | no, R27; use `arrow_up`, `arrow_down` |
| `line_sel` | ✎ ↕ Sel. Lines | no, R27; use `sel_up`, `sel_down` | yes | no, R27; use `sel_up`, `sel_down` |
| `words` | W Words | no, R27; use `word_prev`, `word_next` | yes | no, R27; use `word_prev`, `word_next` |
| `words_sel` | ✎ W Sel. Words | no, R27; use `sel_word_prev`, `sel_word_next` | yes | no, R27; use `sel_word_prev`, `sel_word_next` |
| `windows` | ◱ Windows | no, R27; use `win_prev`, `win_next` | yes | no, R27; use `win_prev`, `win_next` |
| `spaces` | ▢ Spaces | no, R27; use `desktop_prev`, `desktop_next` | yes | no, R27; use `desktop_prev`, `desktop_next` |
| `volume` | 🔊 Volume | no, R27; use `vol_down`, `vol_up` | yes | no, R27; use `vol_down`, `vol_up` |
| `brightness` | ☀ Brightness | no, R27; use `brightness_down`, `brightness_up` | yes | no, R27; use `brightness_down`, `brightness_up` |
| `tracks` | ♫ Tracks | no, R27; use `track_prev`, `track_next` | yes | no, R27; use `track_prev`, `track_next` |
| `lines` | ↕ Lines (Alt) | no, R27; use `line_up`, `line_down` | yes | no, R27; use `line_up`, `line_down` |
| `line_bounds` | ↔ Line (start/end) | no, R27; use `line_start`, `line_end` | yes | no, R27; use `line_start`, `line_end` |
| `paragraphs` | ¶ Paragraphs | no, R27; use `para_prev`, `para_next` | yes | no, R27; use `para_prev`, `para_next` |
| `document` | 📄 Document (start/end) | no, R27; use `doc_start`, `doc_end` | yes | no, R27; use `doc_start`, `doc_end` |

### Reasons

| Ref | Locale key | Reason (English) |
| --- | --- | --- |
| R1 | `platform_reason.action_lookup_is_macos_dictionary` | macOS only: Look Up opens the system dictionary panel on the word under the pointer. Windows and Linux have no system dictionary panel. |
| R2 | `platform_reason.action_window_switching_is_not_macos` | Not on macOS: this steps through windows the Alt+Tab way of Windows and Linux. macOS switches applications with Cmd+Tab and cycles the windows of one application: use the equivalent action. |
| R3 | `platform_reason.action_application_switching_is_macos` | macOS only: macOS switches between applications, each holding its windows. Windows and Linux switch between windows with Alt+Tab: use the equivalent action. |
| R4 | `platform_reason.action_same_action_under_another_name` | This system offers the same action under another name: use the equivalent action. |
| R5 | `platform_reason.action_shortcut_is_a_modifier_chord_here` | Not a separate action on this system: it is one of its modifier + key combinations (Cmd on macOS, Ctrl on Windows and Linux), listed under “Shortcuts”. |
| R6 | `platform_reason.action_word_deletion_modifier_differs` | Each system deletes a word with its own modifier (Option on macOS, Ctrl on Windows and Linux), so each lists its own action: use the equivalent action. |
| R7 | `platform_reason.action_line_deletion_is_macos` | macOS only: Cmd+Delete deletes to the start or the end of the line in macOS text fields. Windows and Linux text fields have no such key: select to the line edge with Shift+Home or Shift+End, then delete. |
| R8 | `platform_reason.action_app_windows_unreachable_on_wayland` | Not on Linux: Wayland lets no application list or focus the windows of another one, so the windows of the active application cannot be told apart from the others; the equivalent action steps through every window. |
| R9 | `platform_reason.action_spaces_and_desktops_are_one_thing` | Spaces on macOS and desktops on Windows and Linux are the same virtual desktops under two names: use the equivalent action. |
| R10 | `platform_reason.action_window_overview_is_each_systems` | Each system has its own window overview: Mission Control and App Exposé on macOS, Task View on Windows. Linux desktops each bind their own, so bind your desktop's key as a keystroke there. |
| R11 | `platform_reason.action_spaces_are_edited_in_mission_control` | Not on macOS: Spaces are added and removed in Mission Control, which macOS lets no other application drive. |
| R12 | `platform_reason.action_desktop_count_belongs_to_the_desktop` | Not on Linux: the number of desktops belongs to each desktop's own settings (GNOME adds and removes them by itself, KDE and Xfce keep a set count), and Wayland gives no application a request to change it. |
| R13 | `platform_reason.action_recording_starts_from_the_capture_tool` | This system records the screen from its own capture tool (the macOS Screenshot toolbar, the GNOME or KDE screenshot tool), which the equivalent action opens. |
| R14 | `platform_reason.layer_spotlight_is_macos` | macOS only: this action opens Spotlight, the search of macOS. On Windows or Linux, bind your desktop's own search shortcut as a keystroke instead. |
| R15 | `platform_reason.action_apple_shortcuts_are_macos` | macOS only: Apple Shortcuts exist only on macOS. Elsewhere, run a command or a program instead. |
| R16 | `platform_reason.action_notifications_are_cleared_from_their_centre` | This system lets no application dismiss notifications: clear them in the notification centre, which the equivalent action opens. |
| R17 | `platform_reason.action_download_mark_is_each_systems` | Each system marks downloaded files its own way (the quarantine attribute on macOS, the Mark of the Web on Windows) and offers the action that removes its own mark. Linux marks no downloaded file. |
| R18 | `platform_reason.action_executable_permission_is_unix` | Not on Windows: a file runs there because of its extension, not because of an executable permission. |
| R19 | `platform_reason.action_file_manager_folder_is_unreadable_on_linux` | Not yet implemented on Linux: this action requires integration with the file manager to identify its active folder. |
| R20 | `platform_reason.action_text_recognition_is_live_text_on_macos` | On macOS, Live Text reads the text of any capture or image: take one with the equivalent action, then select its text. |
| R21 | `platform_reason.action_take_note_uses_notepad` | macOS provides Quick Note (Fn+Q) instead of opening a plain-text notes file. |
| R22 | `platform_reason.action_mirroring_is_the_systems_projection_menu` | No toggle on Linux: GNOME and KDE choose Duplicate in their own Super+P display switcher; bind that key as a keystroke. |
| R23 | `platform_reason.action_office_bold_key_is_windows` | Windows only: French Microsoft Office makes text bold with Ctrl+G where other applications use Ctrl+B, so this action picks the key by application. On macOS (Cmd+B) and Linux (Ctrl+B) one combination works everywhere: bind it from “Shortcuts”. |
| R24 | `platform_reason.action_navigation_layer_switch_is_karabiner` | macOS only: these switch the navigation layer kept inside Karabiner-Elements. On Windows and Linux the layer follows the key held down and has no switch to set. |
| R25 | `platform_reason.action_sticky_keys_are_the_systems` | This system has Sticky Keys in its accessibility settings, which make every modifier one-shot; turn them on there. |
| R26 | `platform_reason.debug_surface_is_each_drivers_own` | Each driver debugs through its own runtime: AutoHotkey provides Window Spy, a variable listing and a key history, and Hammerspoon provides a Lua console. The other runtimes have nothing equivalent to open. |
| R27 | `platform_reason.action_continuous_swipe_is_macos` | macOS only: a continuous swipe follows the fingers while they move, which only the macOS driver reads. Windows gets finished gestures from its touchpad settings and Linux acts once a swipe ends: use the equivalent single-step actions. |

<!-- END GENERATED availability -->

