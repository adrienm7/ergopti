--- ui/network_check.lua

--- ==============================================================================
--- MODULE: Network Check Window (Linux)
--- DESCRIPTION:
--- The Debug menu's one-click « Test network (PAC, proxy, download) »: a click
--- runs the shared steps (_shared/lua/network/field_check_network.lua) over this
--- driver's ports (adapters/network_check_ports.lua), writes the one evidence
--- record to the log and shows the result, one line per step, with a « Copy
--- report » button. macOS runs the same steps; Windows runs them in AutoHotkey.
---
--- FEATURES & RATIONALE:
--- 1. Company-proxy failures are the ones a user cannot diagnose alone: the
---    report names the step that failed (settings, PAC download, PAC verdict,
---    route lookup, TLS, transfer) with a closed token and no URL.
--- 2. The window, the busy refusal and the clipboard copy are the runner every
---    one-click check shares (ui/field_check_window.lua).
--- ==============================================================================

local Window = require("ui.field_check_window")

return Window.new({
	label = "Network check",
	log = "network_check",
	check_id = "network",
	title_key = "menu.debug.field_check_network",
	steps = function(ports, report, finish)
		require("network.field_check_network").run(ports, report, finish)
	end,
	env = function() return require("adapters.network_check_ports").new() end,
	unusable_step = "proxy_settings",
})
