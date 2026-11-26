--- diagnostics/ui/field_check/tray_check.lua

--- ==============================================================================
--- MODULE: Tray Check (Linux)
--- DESCRIPTION:
--- The field run's « tray » check: the live tray menu read back over the
--- session bus as a panel reads it, a panel's hover replayed on the checkable
--- groups, one « Layout to emulate » change made and put back, and
--- « Suspendre » ticked and unticked (diagnostics/engine/field_check/tray_check.lua
--- over diagnostics/adapters/tray_check_ports.lua). It runs as a step of the
--- field run, from the collector and from the menu's in-app field report; the
--- runner, its evidence record and its report are the one every field check
--- shares (diagnostics/ui/field_check/window.lua).
--- ==============================================================================

local Window = require("diagnostics.ui.field_check.window")
local Check  = require("diagnostics.engine.field_check.tray_check")

return Window.new({
	label = "Tray check",
	log = "diagnostics.ui.field_check.tray_check",
	check_id = "tray",
	title_key = "field_check.tray.title",
	steps = function(ports, report, finish)
		Check.run(ports, report, finish)
	end,
	env = function() return require("diagnostics.adapters.tray_check_ports").new("tray") end,
	unusable_step = "tray_ports",
})
