--- diagnostics/ui/field_check/setup_check.lua

--- ==============================================================================
--- MODULE: Session Setup Check (Linux)
--- DESCRIPTION:
--- The field run's « setup » check: the input path, the autostart unit, the
--- polkit agent and the compositor focus reporter, read from inside the daemon
--- (diagnostics/engine/field_check/setup_check.lua over
--- diagnostics/adapters/setup_check_ports.lua). It runs as a step of the field
--- run, from the collector and from the menu's in-app field report; the
--- runner, its evidence record and its report are the one every field check
--- shares (diagnostics/ui/field_check/window.lua).
--- ==============================================================================

local Window = require("diagnostics.ui.field_check.window")
local Check  = require("diagnostics.engine.field_check.setup_check")

return Window.new({
	label = "Setup check",
	log = "diagnostics.ui.field_check.setup_check",
	check_id = "setup",
	title_key = "field_check.setup.title",
	steps = function(ports, report, finish)
		Check.run(ports, report, finish)
	end,
	env = function() return require("diagnostics.adapters.setup_check_ports").new("setup") end,
	unusable_step = "setup_ports",
})
