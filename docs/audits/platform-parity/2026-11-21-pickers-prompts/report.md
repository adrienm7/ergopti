# Pickers and prompts

Audited source: `0d444a5815` (`dev`). Date: November 21, 2026. Sixth campaign
in the order of the [2026-11-19 census](../2026-11-19-census/report.md), after
the [update and download windows](../2026-11-21-update-windows/report.md). The
[editors campaign](../2026-11-12-editors/report.md) read the editors' save
paths and lifetimes; this one reads the small windows that ask the user for
one thing, and what each driver does with the answer.

## Scope

The action picker, the program pickers, the prompt editor, the numeric prompts
(« Other value… »), the token prompts and the native question and message
dialogs, on the three drivers:

- shared pages: `_shared/ui/action_picker/`, `numeric_prompt/`,
  `token_prompt/`, `prompt_editor/`, `model_browser/`, `error_dialog/`,
  `config_cleanup/` and `physical_shortcuts/`, with
  `_shared/apps/engine/program_provider_picker.lua` and the value check
  (`_shared/settings/engine/value_check.lua`, `value_check_vectors.json`);
- Windows: `ui/action_picker/init.ahk` and `action_picker_webview.ahk`,
  `apps/engine/picker.ahk` (the application picker), `gestures/engine/config.ahk`
  (`_GesturePickApplication`), `ai/ui/menu/settings.ahk` and
  `settings/engine/value_check.ahk`, `ai/ui/menu/api_entries.ahk`,
  `ai/ui/prompt_editor/init.ahk`, `ai/ui/model_browser/init.ahk`,
  `diagnostics/ui/error_dialog.ahk`, `settings/ui/cleanup.ahk` and
  `ui/physical_shortcuts/`;
- macOS: `ui/action_picker/init.lua`, `apps/engine/picker.lua`,
  `core/ui/engine/dialog_util.lua`, `ai/ui/menu/settings_manager.lua`,
  `ai/ui/menu/panels/api_panel.lua` and `local_server_panel.lua`,
  `ai/ui/menu/models/manager_mlx_hf.lua` (the Hugging Face token window),
  `ai/ui/prompt_editor/init.lua`, `ai/ui/model_browser/init.lua`,
  `diagnostics/ui/error_dialog.lua`, `settings/ui/cleanup.lua` and
  `ui/physical_shortcuts/init.lua`;
- Linux: `ui/action_picker/bridge.lua`, `apps/ui/chooser.lua` and
  `apps/ui/menu/exclusion_rows.lua`, `core/ui/ui/numeric_prompt.lua` and
  `token_prompt.lua`, `ai/ui/menu/llm.lua`, `ai/ui/menu/backend_rows.lua`,
  `core/ui/ui/text_prompt.lua`, `ai/ui/prompt_editor/bridge.lua`,
  `ai/ui/model_browser/bridge.lua`, `diagnostics/ui/error_dialog.lua`,
  `settings/ui/cleanup.lua` and `ui/physical_shortcuts/bridge.lua`.

Read for each: validation and fail-fast refusals, cancel and Escape, keyboard
and screen-reader access, reading preferences, localization in the 21 locales,
focus return after close, a second open, secret fields and private data, and
teardown. Source reading, the shared pages under a minimal DOM, the AutoHotkey
suite and the macOS and Linux suites under WSL; no window was rendered.

Checked and kept:

- **Ranges.** Every numeric setting is bounded by its declaration in
  `value_schema.json` on the three (Windows `ValueCheckEntryFor`, Lua
  `ValueCheck.declaration`); non-finite and huge values are refused everywhere.
- **Cancel is not an empty answer.** Windows reads `ib.Result != "OK"`, macOS
  compares the button with its OK label, Linux `text_prompt.ask` returns nil on
  cancel and `""` on an empty OK; the numeric page posts a separate `cancel`.
  The action picker's Escape posts `cancel` on the three, and the native
  pickers (the Windows ListBox fallback, the application picker,
  `hs.chooser`) close on Escape.
- **Screen readers.** The action picker is a combobox with
  `aria-activedescendant` over one listbox per heading, `aria-disabled` rows, a
  status empty state and an alert error; the model browser, error dialog,
  cleanup and physical shortcuts pages each have a polite status region; the
  numeric refusal is an alert.
- **Reading preferences.** Every page loads `a11y_prefs.js` before its
  stylesheets and each host seeds `script.reading_font` and
  `script.reading_spacing` (`ReadingPrefs_SeedScript`, macOS
  `build_injected_html`, Linux `build_app_html`).
- **Localization.** The 94 keys these pages and the physical editor use exist
  and are filled in the 21 locales; the `lang` attribute is set from the
  locale by `i18n.js` (by the page itself on physical shortcuts).
- **A second open.** The action picker is one window everywhere (the newer
  replaces the older, a generation drops the older's late messages); the
  model browser and the cleanup window are reused; physical shortcuts closes
  and reopens; the prompt editor points the open window at the new profile
  (Linux opens a new one), dropping the draft without asking, on the three.
- **Private data.** The error dialog redacts the module, message and log path
  before the page sees them, and its page cannot name a path, text or URL
  (`ED_PAGE_ACTIONS`, `PAGE_ACTIONS`); no picker or prompt logs what is typed;
  Windows and Linux never put a key on a command line
  (`test_remote_token_not_on_argv.ahk`).
- **Teardown.** Every host ties page messages to a session and an epoch; a
  late message of a closed page does nothing (but see PCK-06 for the Linux
  picker's title-bar close).
- **Focus return.** No driver restores the window that was active before a
  picker or prompt opened: the OS gives the focus back on the three.

## Fixed

| Id     | OS            | Sequence                                                                                      | Reference                                                                                               | Before                                                                                                                                                                                                                                                             | Regression                                                                                                                                                           |
| ------ | ------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| PCK-01 | macOS, shared | AI > API > ➕ a provider, then the Token step; or the Hugging Face token window               | Windows passes `Password` to its InputBox (`api_entries.ahk`), Linux `--hide-text` (`backend_rows.lua`) | `api_panel.lua` `prompt_field` called `text_prompt` without its secure flag, so the key was typed in clear; the token page's field was `type="text"`, and the host seeds it from the clipboard or the saved token                                                  | `pck-01: the key is typed in a secure field` (`test_account_address.lua`); the `pck-01` checks of `test-token-prompt-focus.cjs`                                      |
| PCK-02 | macOS         | The same Token step, a key pasted with a trailing space or tab                                | Windows `; do NOT Trim`, Linux « never trim secret bytes »                                              | `prompt_field` trimmed every answer, the key included                                                                                                                                                                                                              | `pck-02: the key is kept byte for byte, as Windows and Linux keep it` (`test_account_address.lua`)                                                                   |
| PCK-03 | Linux         | AI > Generation > Context length > Other value…, type « 250.9 », Save                         | macOS and Windows refuse a fraction of a whole number and say why                                       | The page let `Number()` read the text and checked only the range; `Settings.bounds` dropped the whole-number flag, so the host refused in silence (`{ saved = false }`, never shown) and the window seemed dead; a trigger delay was saved as `math.floor(number)` | `pck-03: a fraction of a whole number is refused with its range, never floored` (`test_numeric_prompt.lua`)                                                          |
| PCK-04 | Linux         | Any numeric prompt, a value out of range                                                      | macOS and Windows render the value schema's text (`ValueCheck.refusal_text`, `ValueCheckRenderMessage`) | « The value is outside the accepted range. », naming no range                                                                                                                                                                                                      | `pck-04: the refusal names the accepted range in the macOS and Windows words` (`test_numeric_prompt.lua`)                                                            |
| PCK-05 | shared        | The Hugging Face token window, Escape                                                         | The numeric prompt and the editors cancel on Escape                                                     | The token page read Enter on `keypress` and had no Escape                                                                                                                                                                                                          | the `pck-05` checks of `test-token-prompt-focus.cjs`                                                                                                                 |
| PCK-06 | Linux         | Open a shortcut's action picker, close it with the title bar or the window manager's key      | Windows `Close` resets the session, macOS `on_close` closes it                                          | The bridge had no `on_window_closed`: the session, its pending options and its program discovery outlived the window, and `is_open()` stayed true until the next open                                                                                              | `pck-06: a window closed by the window manager retires its session as a cancel` and two siblings (`test_close_successor.lua`)                                        |
| PCK-07 | all           | A page message `{action: "confirm"}` without an action id                                     | —                                                                                                       | Windows took `""`, the native passthrough; macOS and Linux took `"none"`, which disables the binding: two different silent writes for one page defect                                                                                                              | the `pck-07` cases of `test_action_picker_count_default.ahk`, `test_context_replacement.lua` (macOS) and `test_close_successor.lua` (Linux)                          |
| PCK-08 | Windows       | Metrics or AI > exclude applications, in any locale                                           | Every other string of the dialog goes through `dialog.app_picker.*`                                     | `AddListView(..., ["Application", "Processus"])`: a French header for every user                                                                                                                                                                                   | `list views: column headers come from t() (pck-08)` (`test_list_view_headers_localized.ahk`)                                                                         |
| PCK-09 | Linux         | Bind open_app and choose a `.desktop` file outside the application folders, or any other file | Windows shows a message box (`_GesturePickApplication`), macOS an alert                                 | `chooser.lua` returned « the chosen file is not a desktop entry » and its caller logged it at INFO: the dialog closed and nothing happened                                                                                                                         | `pck-09: a file that is no installed desktop entry is refused in words` (`test_app_chooser.lua`)                                                                     |
| PCK-10 | macOS         | A prompt editor save with a blank name or prompt, or a `batch` that is not a Boolean          | Windows `_PromptEdWeb_ReadSavePayload` and the Linux bridge refuse them                                 | macOS filled a default name, `""` and `false`, and saved the profile                                                                                                                                                                                               | `pck-10: refuses the scalar fields Windows and Linux refuse, and saves none of them` (`test_prompt_editor_native_boundaries.lua`)                                    |
| PCK-11 | Windows       | Tray > clean unused settings                                                                  | macOS presents and focuses it, Linux shows it as any page                                               | `Host.Opts := Map("NoActivate", true, …)`, with no reason since the window was introduced (`7ef1d9d038`): it opened behind the active application                                                                                                                  | `config cleanup webview: the window opened from the menu is activated (pck-11)` (`test_unused_keys.ahk`)                                                             |
| PCK-12 | all           | The cleanup window, Escape                                                                    | The prompt editor and the Updates page close on Escape                                                  | Only a Windows native `Escape` existed, and the WebView holds the keyboard, so Escape did nothing on the three                                                                                                                                                     | the `pck-12` checks of `test-editors-ime-keyboard.cjs`                                                                                                               |
| PCK-14 | macOS, Linux  | Temperature « 0,8 », a word count « +12 », a context length « 0x100 » or « 1e3 »              | The shared entry grammar of `value_check_vectors.json` (`parse_entry`), which the Windows port replays  | macOS read `tonumber(raw)` (« 0,8 » refused, « 0x100 » and « 1e3 » admitted) and `^%s*(%d+)%s*$` for the word counts (« +12 » refused); Linux let the number field parse                                                                                           | the shared replay `_shared/tests/lua/numeric_entry_contract.lua`, registered by `test_numeric_validation_feedback.lua` (macOS) and `test_numeric_prompt.lua` (Linux) |

Notes:

- **PCK-01 and PCK-02.** The macOS key prompt now passes the secure flag of
  `hs.dialog.textPrompt` and keeps the answer as typed; the address and the
  model are still trimmed. The token page's field is `type="password"` with
  `autocomplete="off"`; only macOS opens that page.
- **PCK-03, PCK-04 and PCK-14 are one rule.** A numeric prompt request now
  names its setting (`key = "llm.generation.context_length"`), not a range of
  the menu's own: the Linux host reads the declaration, sends the page the
  range in the words of a refusal, and reads the typed text with
  `ValueCheck.parse_entry`; a refusal goes back to the page
  (`show_refusal`), which marks the field `aria-invalid`. The page parses no
  number (`type="text" inputmode="decimal"`). macOS `settings_manager.lua`
  reads every typed number through the same `parse_entry`
  (`parse_declared`), and `generic_numeric_prompt` lost its unused factor,
  bounds and integer flag: the declaration owns them. Both drivers replay the
  shared entry vectors through their real prompt, so « 0,7 », « +350 »,
  « 1e3 » and « 1.5 » are judged as the Windows port judges them. The corpus
  `linux_numeric_custom_tail.json` names each context's declaration instead of
  its bounds, and its debounce candidate is a whole number: a fraction no
  longer reaches the setter. `test-menu-unavailable-rows.cjs` was re-pinned on
  the new owners after review.
- **PCK-06.** The Linux session records its native page epoch; that page's
  close notice retires it as a cancel. A close the bridge causes itself (its
  own hide, a replacement) is marked so it is not a second cancel.
- **PCK-07.** A confirmation without a non-empty string id is logged and
  refused on the three, the picker left open; the page's own specials
  (`none`, `__native__`) pass unchanged. The page never sends one
  (`isConfirmable`).
- **PCK-12.** Escape on the cleanup page posts the Close button's action and
  leaves an IME composition alone; the token page gained the same legacy
  composition check.

## Open

- **PCK-13 (medium, macOS):** a blank numeric answer means three things.
  macOS resets the setting to its default (`settings_manager.lua`, « Leave
  blank to reset »), Windows refuses it (`empty`), Linux refuses it with the
  range sentence. The shared replay skips blank vectors for that reason. A
  maintainer choice: keep the macOS reset (Windows and Linux reset through a
  preset row) or refuse a blank on macOS too.
- **PCK-15 (medium, Windows):** a refused confirmation closes the picker.
  macOS and Linux keep it open when the caller returns false; Windows closes
  before the callback for every pick but a slot pick (`_ActPickWeb_Confirm`:
  « Refusal still closes this session; it cannot lend its callback to a new
  one »). With a read-only `config.toml`, the Windows picker vanishes where
  macOS lets the user retry.
- **PCK-16 (medium, Windows, field):** the driver never hands WebView2 the
  focus (`MoveFocus` is bound in `vendor/WebView2.ahk` only). The pages call
  `focus()`, but without the controller's focus the keyboard may stay on the
  host window: typing at once into the action picker, the prompt editor or a
  numeric field may do nothing until a click. macOS and Linux focus their web
  views. Needs a real desktop.
- **PCK-17 (low, Windows, field):** `LLM_Menu_PromptNumeric` releases
  `Critical` before its InputBox, so a second « Other value… » click probably
  opens a second box on its own thread. Linux replaces the open prompt on
  purpose; macOS blocks in `textPrompt`.
- **PCK-18 (low, Linux):** `core/ui/ui/token_prompt.lua` speaks `ready`,
  `refresh`, `close` and `payload.action`; the page posts `cancel`,
  `open_link` and `{type: "validate"}`. Nothing on Linux or Windows opens that
  page. Retire the bridge, or wire it to the page's protocol when Linux gains
  a Hugging Face login.
- **PCK-19 (low, the three):** Escape does nothing on the model browser and
  physical shortcuts pages. The model browser's protocol has no close action
  for the page to post; on physical shortcuts, Escape may be the key a
  position capture waits for. Windows registers native Escape handlers there
  that the focused WebView never lets fire.
- **PCK-20 (low, Windows and macOS):** prompt editor details. Windows trims
  the prompt it saves (`Trim(CandidatePrompt)`), Linux and now macOS keep a
  raw prompt verbatim; Windows and macOS drop an unknown page action without a
  log line, Linux logs it.
- **PCK-21 (low, Windows):** the application picker names a running process
  by a fragment of its window title (`AppPicker_FriendlyName`), so a document
  name or a mail subject can show in the list; macOS shows bundle names and
  Linux application ids. Nothing is logged.
- **PCK-22 (low, shared):** no page sets `dir="rtl"` for Arabic or Hebrew:
  the text is translated, the layout stays left to right on the three.

Native receiving, in `TODO-tests-windows.md`, `TODO-tests-macos.md` and
`TODO-tests-linux.md` (field point `pickers_prompts` on macOS and Linux): the
masked key prompts, the token page's Escape, the numeric grammar and the
prompt editor on macOS; the numeric refusal read by Orca, the title-bar close
and the open_app refusal on Linux; the application picker's headers, the
cleanup window's focus and Escape, the action picker's first keystroke
(PCK-16) and two « Other value… » boxes (PCK-17) on Windows.

## Proof

Commits `9e682c139e` (PCK-01, PCK-02 on macOS), `6107cccd53` (PCK-01 on the
token page, PCK-05), `26ee28d221` (PCK-08), `384925ed2f` (PCK-11),
`8b00630939` (PCK-12), `8e277665f1` (PCK-06), `bce233e6b0` (PCK-07),
`639449c34a` (PCK-09), `1e3f02a95d` (PCK-10), `295356717a` (PCK-03, PCK-04,
PCK-14).

- **Red on the old code.** Each regression ran against the `0d444a5815` copy
  of the production file it guards, in a private `git archive` copy under WSL
  (`unset DISPLAY WAYLAND_DISPLAY`) for Lua:
  - PCK-01, PCK-02: with `api_panel.lua` from `0d444a5815`,
    `test_account_address.lua` fails both new cases (« the key prompt hides
    what is typed », « a secret is never trimmed »).
  - PCK-01, PCK-05: with the old `token_prompt/index.html`,
    `test-token-prompt-focus.cjs` fails « pck-01: the token field masks what
    is typed »; with the old `script.js`, « pck-05: Escape posts cancel ».
  - PCK-03, PCK-04, PCK-14 (Linux): with the old `numeric_prompt.lua`,
    `llm.lua` and page, `test_numeric_prompt.lua` fails 33 cases, among them
    both `pck-03`, `pck-04` and 21 `numeric-entry` vectors.
  - PCK-14 (macOS): with the old `settings_manager.lua`,
    `test_numeric_validation_feedback.lua` fails 19 cases, both `pck-14` and
    the `numeric-entry` vectors for « 0,7 », « 1e3 », « 0x10 », « 1,5 »,
    « nan » and « 2 000 ».
  - PCK-06, PCK-07 (Linux): with the old `action_picker/bridge.lua`,
    `test_close_successor.lua` fails the three `pck-06` cases (no
    `on_window_closed`) and `pck-07` (« it never means none »).
  - PCK-07: with the old macOS `action_picker/init.lua`, the `pck-07` case of
    `test_context_replacement.lua` fails; the AHK case calls
    `_ActPickWeb_ConfirmedId`, which the old file lacks.
  - PCK-08: with the old `picker.ahk`,
    `ahk-parallel --only="pck-08"` gives 0 of 1 (« a list view header is a
    literal string, not a t() key: ["Application", "Processus"] »).
  - PCK-09: with the old `chooser.lua`, `test_app_chooser.lua` fails `pck-09`
    and the line-break receipt (one modal, not two).
  - PCK-10: with the old macOS `prompt_editor/init.lua`, the `pck-10` case of
    `test_prompt_editor_native_boundaries.lua` fails.
  - PCK-11: with the old `cleanup.ahk`, `ahk-parallel --only="pck-11"` gives
    0 of 1 (« takes the keyboard … actual: <1> »).
  - PCK-12: with the old `config_cleanup/script.js`,
    `test-editors-ime-keyboard.cjs` fails « pck-12: Escape is consumed by the
    cleanup page ».
- **Green on the new code.** `ahk-parallel --fresh --only=<pck-07|pck-08|pck-11>
--wait=300`: 1 of 1 each. Linux modules (`luajit`, the manifest filtered to
  each module): `test_numeric_prompt` 38, `test_request_lifetime` 18,
  `test_prediction_count` 48, `test_numeric_configuration_owner` 50,
  `test_close_successor` 11, `test_app_chooser` 37,
  `test_bridge_handlers_webview_manager` 52, `test_program_provider_picker`
  93, `test_value_check_vectors` 100, `test_picker_refusal` 12,
  `test_webkit_host` 47 passed, none failed. macOS modules (`lua tests/run.lua
--only`): `test_numeric_validation_feedback` 46,
  `test_prompt_editor_native_boundaries` 22, `test_prompt_bridge_retirement`
  17, `test_context_replacement` 11, `test_editor_save_retry` 14,
  `test_mlx_port` 8, `test_account_address` 8, `test_prompt_cancel` 7,
  `test_validation_refusal` 4, `test_value_check_vectors` 100 passed, none
  failed. `test-token-prompt-focus.cjs`, `test-editors-ime-keyboard.cjs`,
  `test-prompt-editor-bridge.cjs` (28) and `test-action-picker-bridge.cjs`
  (117) pass.
- **Gates.** `test-app-windows-semantic-markup.cjs`,
  `test-app-windows-accessibility-ratchet.cjs`, the locale gates
  (`test-locale-*`, `test-action-labels-have-locale-keys.cjs`),
  `test-shared-literal-inventory.cjs`, `test-linux-feature-parity.cjs`,
  `test-no-pinned-source-reads.cjs` (170 of 170), `-lua.cjs` and
  `-linux.cjs`, `test-config-key-literals.cjs`,
  `test-no-hardcoded-ui-strings.cjs`, `test-menu-manifest.cjs`,
  `test-menu-unavailable-rows.cjs` (re-pinned on the new numeric owners
  after review), `test-webview-geometry-single-source.cjs`,
  `test-error-messages-say-how-to-recover.cjs`, `test-ahk-encoding.cjs`,
  `tools/dev/field-todo-summary.py --check-doc` for Linux and macOS, and
  `lint-conventions.js --fail-on-violations` with the formatter at each
  commit.
- **Not run here.** The full macOS and Linux suites: two full Linux runs
  under WSL were cut short by the WSL service restarting under other work,
  so only the modules above ran. A first full Linux run on the numeric
  change alone showed, besides failures of the environment (root-owned
  permission tests, a tree without `static/ergopti`), one case
  of `test_bridge_handlers_webview_manager` that passes when its module runs
  alone; it was not traced. Also not run: the full AutoHotkey suite, a real
  window on any OS, `npm run test:js` and `verify-change` (they refuse this
  checkout's Node pin).
