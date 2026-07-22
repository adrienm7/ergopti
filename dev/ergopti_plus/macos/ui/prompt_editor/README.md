# prompt_editor (Hammerspoon)

## Purpose

WKWebView-based LLM prompt-profile editor. The shared frontend renders the `{context}` token as a draggable visual chip in a content-editable block and provides autocomplete for template variables. Singleton: a second `show()` call teleports the existing window to the current macOS Space (space teleportation) and focuses it, preserving in-progress text.

## Key files

| File      | Description                                                              |
| --------- | ------------------------------------------------------------------------ |
| `init.lua`| `M.show(profile)` — singleton host; bridge handler for save/cancel        |

## Shared frontend

`_shared/ui/prompt_editor/` — HTML/CSS/JS shared with the Windows driver.
