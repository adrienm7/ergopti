--- ui/composer_check.lua

--- ==============================================================================
--- MODULE: Composer Check Window (Linux)
--- DESCRIPTION:
--- The Debug menu's one-click « Test the composed layout »: a click runs the
--- shared steps (_shared/lua/layouts/composer_check.lua) over this driver's
--- composer environment (modules/keymap/composer_check.lua), writes the one
--- evidence record to the log and shows the result, one line per step, with a
--- « Copy report » button.
---
--- FEATURES & RATIONALE:
--- 1. One click, no arguments: the menu row names the check; nothing else is
---    asked of the user.
--- 2. The window, the busy refusal and the clipboard copy are the runner every
---    one-click check shares (ui/field_check_window.lua), so the dialog caption
---    has one owner.
--- ==============================================================================

local Window = require("ui.field_check_window")
local Check  = require("layouts.composer_check")

return Window.new({
	label = "Composer check",
	log = "composer_check",
	check_id = Check.CHECK_ID,
	title_key = "menu.debug.composer_check",
	steps = function(env, report, finish)
		Check.run(env, report, finish)
	end,
	env = function() return require("modules.keymap.composer_check").env() end,
	unusable_step = "composer_fixture",
})
