# prompt_editor (AHK)

## Purpose

WebView2 host for the LLM prompt-profile editor. Loads the shared `_shared/ui/prompt_editor/` frontend, which renders the `{context}` token as a visual chip and provides autocomplete. Falls back to a native `InputBox` multi-step wizard when WebView2 is absent. Saving writes the updated profile to `config.toml` without a full driver reload.

## Key files

| File      | Description                                                           |
| --------- | --------------------------------------------------------------------- |
| `init.ahk`| Singleton host: `PromptEditor_Show(profile)` — opens / focuses window  |

## Shared frontend

`_shared/ui/prompt_editor/` — HTML/CSS/JS shared with the macOS driver.
