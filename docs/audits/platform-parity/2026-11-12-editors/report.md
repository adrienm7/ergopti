# Editors: page and bridge behaviour (first pass)

Audited source: `2f7264b6` (`claude/ergopti-todo-parity-b`, on `dev`).
Date: November 12, 2026.

## Scope

The page messages and bridge behaviour of the personal information, prompt,
paths and personal hotstrings editors on the three OSes. The webview hosts'
lifecycle and the layer editor host belong to the other parity track and were
not reviewed here. Windows (`windows/ui/*_editor/`,
`windows/ui/personal_toml_editor_webview.ahk`, `windows/ui/editors.ahk`) is
the read-only reference. Candidates were replayed through the real macOS
editor modules with their native stubs.

## Fixed (macOS)

| Id      | Sequence                                                       | Windows / Linux                                                                                      | macOS before                                  | Regression                     |
| ------- | -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | --------------------------------------------- | ------------------------------ |
| EDM-001 | Save personal information while the write is refused or raises | Windows `_PersonalInfoReportSaveFailure` shows `dialog.personal_info.save_failed`; Linux notifies it | Logged only: the editor stayed open, silently | `personal-editor-save-failure` |

## Decision asked of the coordinator

- **EDD-1, an open editor while the driver is paused.** Windows refuses every
  page message but `ready` while suspended (« WebMessageReceived bypasses
  native Suspend … a paused driver still lets a page click write config »):
  the prompt, paths, personal information, hotstrings, layer, layout manager,
  hotstrings configuration, action picker, model browser and physical
  shortcuts editors. The macOS and Linux editor bridges have no pause gate
  (Linux physical shortcuts, changelog, download and update check aside), so
  a Save after a pause writes there; Linux checks the pause when a prompt
  profile is created but not when one is saved after an edit. Options: A
  (recommended) refuse page writes while paused on macOS and Linux and say so
  through each editor's save-failure path, and have Windows say so too
  instead of dropping silently; B drop silently as Windows does; C allow them
  everywhere.

## Checked and kept

- The three hosts accept the same page vocabulary: `ready`, `save`, `cancel`
  (and `save_pref`, `window_focus`, `close` for the hotstrings editor).
- A refused save keeps the editor open with its values on the three OSes,
  and only a committed save closes it; a stale session's message is ignored.
- macOS edits its folders through native panels (`ui/menu/menu_paths.lua`);
  Windows and Linux use the shared paths editor page. A presentation
  difference, not a behaviour one.

## Left

- The macOS prompt editor's refused save: no user notice was found on the
  prompt editor or profile edit path (`profiles_manager.lua`
  `replace_profile`); Windows notifies through `_LLM_Menu_ProfileNotifyFailure`
  and Linux through `notify_save_refused`. To trace through `deps.save_prefs`
  before changing it.
- EDD-1, then the layer editor page behaviour, `ui/tooltip` and `ui/wpm`.
