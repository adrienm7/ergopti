# hotstring_editor (Hammerspoon)

## Purpose

WKWebView-based interface for creating, editing, and managing custom hotstrings in the personal TOML file. Handles JS↔Lua communication for all file I/O (read, write, validate) and config regeneration. Singleton: a second `show()` call teleports the existing window to the current macOS Space and focuses it, preserving any in-progress text.

## Key files

| File      | Description                                                                |
| --------- | -------------------------------------------------------------------------- |
| `init.lua`| `M.show()` — singleton host; bridge handler for create/update/delete/save  |

## Usage

```lua
local HotstringEditor = require("ui.hotstring_editor")
HotstringEditor.show()  -- called from the Personal Hotstrings menu item
```
