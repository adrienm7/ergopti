--- diagnostics/ui/field_check/session_check.lua

--- ==============================================================================
--- MODULE: Session Health Check (Linux)
--- DESCRIPTION:
--- The field run's « session » check: what the daemon found in the user's
--- session and how its typing path held up since it started, read from inside
--- it (diagnostics/engine/field_check/session_check.lua over
--- diagnostics/adapters/session_check_ports.lua). It runs as a step of the
--- field run, from the collector and from the menu's in-app field report; the
--- runner, its evidence record and its report are the one every field check
--- shares (diagnostics/ui/field_check/window.lua).
--- ==============================================================================

local Window = require("diagnostics.ui.field_check.window")
local Check  = require("diagnostics.engine.field_check.session_check")

return Window.new({
	label = "Session check",
	log = "diagnostics.ui.field_check.session_check",
	check_id = "session",
	title_key = "field_check.session.title",
	steps = function(ports, report, finish)
		Check.run(ports, report, finish)
	end,
	env = function() return require("diagnostics.adapters.session_check_ports").new("session") end,
	unusable_step = "session_ports",
})
