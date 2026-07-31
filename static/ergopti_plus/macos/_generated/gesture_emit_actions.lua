--- _generated/gesture_emit_actions.lua
--- AUTO-GENERATED from _shared/modules/actions/actions.toml.
--- DO NOT EDIT BY HAND — run `npm run codegen:gesture-emit-actions:hs` to refresh.

--- ==============================================================================
--- MODULE: Gesture Emit Actions (macOS)
--- DESCRIPTION:
--- Every action macOS performs as a plain keystroke, as { key, mods } for
--- hs.eventtap.keyStroke. modules/gestures/actions.lua registers these instead
--- of spelling each one out as its own closure.
---
--- These are macOS values, NOT shared ones. Of the 24 actions both drivers
--- implement as a bare keystroke, 15 use a different key or modifier: macOS
--- moves by word with Option where Windows uses Control, closes a window with
--- cmd+w against alt+F4, and spells several keys differently outright
--- (return/Enter, delete/BackSpace). The Windows values live in the same
--- catalogue under emit_ahk_*.
--- ==============================================================================

return {
	{ id = "arrow_down", key = "down", mods = {  } },
	{ id = "arrow_left", key = "left", mods = {  } },
	{ id = "arrow_right", key = "right", mods = {  } },
	{ id = "arrow_up", key = "up", mods = {  } },
	{ id = "backspace", key = "delete", mods = {  } },
	{ id = "close_window", key = "w", mods = { "cmd" } },
	{ id = "delete", key = "forwarddelete", mods = {  } },
	{ id = "doc_end", key = "down", mods = { "cmd" } },
	{ id = "doc_start", key = "up", mods = { "cmd" } },
	{ id = "enter", key = "return", mods = {  } },
	{ id = "escape", key = "escape", mods = {  } },
	{ id = "fullscreen", key = "f", mods = { "cmd", "ctrl" } },
	{ id = "para_next", key = "down", mods = { "alt" } },
	{ id = "para_prev", key = "up", mods = { "alt" } },
	{ id = "sel_down", key = "down", mods = { "shift" } },
	{ id = "sel_left", key = "left", mods = { "shift" } },
	{ id = "sel_right", key = "right", mods = { "shift" } },
	{ id = "sel_up", key = "up", mods = { "shift" } },
	{ id = "sel_word_next", key = "right", mods = { "shift", "alt" } },
	{ id = "sel_word_prev", key = "left", mods = { "shift", "alt" } },
	{ id = "tab", key = "tab", mods = {  } },
	{ id = "tab_close", key = "w", mods = { "cmd" } },
	{ id = "tab_new", key = "t", mods = { "cmd" } },
	{ id = "tab_next", key = "tab", mods = { "ctrl" } },
	{ id = "tab_prev", key = "tab", mods = { "ctrl", "shift" } },
	{ id = "word_next", key = "right", mods = { "alt" } },
	{ id = "word_prev", key = "left", mods = { "alt" } },
}
