--- infra/quit_request.lua

--- ==============================================================================
--- MODULE: Tray Quit Request (Linux)
--- DESCRIPTION:
--- The daemon's answer to the tray's Quit. It asks the shared quit admission
--- (`_shared/lua/quit_admission.lua`, also read by the macOS menu) whether Quit
--- may start, and only an admitted Quit applies the pause layout and starts the
--- shutdown. A refusal changes nothing and answers false; the tray row then tells
--- the user with the one `notify.quit_refused` notice.
---
--- FEATURES & RATIONALE:
--- 1. Same Refusals As macOS: a shutdown or a reload restart that owns the
---    process, a global configuration writer that still holds a rollback, and a
---    hotstring publication that is still pending each refuse Quit.
--- 2. Refusal Before Effect: the pause layout is applied only once Quit is
---    admitted, so a refused click cannot leave the keyboard on the pause layout
---    of a daemon that keeps running.
--- 3. Facts From Ports: every fact is read from an owner injected here, and a
---    missing owner fails at construction instead of reading as "not busy".
--- ==============================================================================

local QuitAdmission = require("quit_admission")
local Logger = require("logger.shim")

local M = {}

local LOG = "infra.quit_request"

--- Builds the tray Quit handler.
--- @param ports table
---   shutdown            table    { is_requested = fn, request = fn(reason) -> boolean }
---   reload_in_flight    function Whether a reload restart already owns the process.
---   writer_active       function Whether a global configuration writer holds a rollback.
---   publication_pending function Whether a hotstring publication is pending.
---   apply_pause_layout  function Applies the pause layout; its failure never blocks the quit.
--- @return function on_quit Returns the shutdown request's answer, false when refused.
function M.new(ports)
	assert(type(ports) == "table", "the quit request needs its ports")
	assert(type(ports.shutdown) == "table" and type(ports.shutdown.is_requested) == "function"
		and type(ports.shutdown.request) == "function", "the quit request needs the shutdown owner")
	for _, name in ipairs({ "reload_in_flight", "writer_active", "publication_pending",
		"apply_pause_layout" }) do
		assert(type(ports[name]) == "function", "the quit request needs the " .. name .. " port")
	end
	return function()
		local decision = QuitAdmission.decide({
			owner_available = true,
			terminal_pending = ports.shutdown.is_requested() == true or ports.reload_in_flight() == true,
			writer_active = ports.writer_active() == true,
			publication_pending = ports.publication_pending() == true,
		})
		if not decision.admitted then
			Logger.warn(LOG, "%s", decision.message)
			return false
		end
		ports.apply_pause_layout()
		return ports.shutdown.request("tray quit")
	end
end

return M
