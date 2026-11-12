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

## Decided

- **EDD-1, an open editor while the driver is paused** (decided by the
  maintainer on 2026-11-12: C, a pause stops typing, not configuration).
  Windows refuses every page message but `ready` while suspended; the macOS
  and Linux editor bridges had no gate except where noted. Done on macOS and
  Linux: the prompt editor's create and clone saves no longer read the pause
  (Linux `menu_llm.lua`, macOS `profiles_manager.lua`), the layout manager's
  LMH-003 gate is reverted (shared `manager_bridge.lua` and both hosts), and
  the Linux physical shortcuts capture and editor rows work after a pause
  (`physical_shortcuts/bridge.lua`, `shortcuts_scope.lua`). Every editor has an
  `edd1-paused-writes` regression: prompt, personal information, paths, layer,
  hotstrings, physical shortcuts and layout manager. The tray's feature rows
  still grey while paused, and the menu's whole-scope restore and clear still
  refuse. Windows counterpart in `TODO.md` « Windows (the PC agent's) ».

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
- The layer editor page behaviour, `ui/tooltip` and `ui/wpm`.
