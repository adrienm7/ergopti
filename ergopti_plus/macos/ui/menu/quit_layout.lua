--- ui/menu/quit_layout.lua

--- ==============================================================================
--- MODULE: Quit Layout Step
--- DESCRIPTION:
--- Quitting ErgoptiPlus leaves the keyboard on the same input source a pause
--- does: the layout chosen in « Disposition quand script en pause ». This is
--- the teardown step that applies it before the process exits.
---
--- FEATURES & RATIONALE:
--- 1. Awaited, not fired: the switch may fall back to an asynchronous TIS
---    subprocess, and process exit would collect it before it selects the
---    source. The step therefore follows the root teardown's pending contract:
---    it retains the readiness callback, answers `true, "pending"`, and hands
---    control back only through that callback.
--- 2. Never blocks the quit: a switch that fails is reported as an ERROR and the
---    teardown continues. The bounded user-quit watchdog covers a switch that
---    never answers.
--- 3. Exit only: a reload keeps the session's layout, as it always has.
--- ==============================================================================

local M = {}

local LOG = "menu.quit_layout"





-- =================================
-- =================================
-- ======= 1/ The step owner =======
-- =================================
-- =================================

--- Creates the once-only quit layout step.
--- @param deps table
---   resolve_menu function Returns the loaded ui.menu module, or nil when the
---                         menubar never started.
---   logger       table    Driver logger (info/error).
--- @return table step Exposes run(termination_kind, on_teardown_ready).
function M.create(deps)
	if type(deps) ~= "table" or type(deps.resolve_menu) ~= "function"
		or type(deps.logger) ~= "table" then
		error("quit_layout.create(): resolve_menu and logger are required")
	end
	local Logger = deps.logger
	local settled = false
	local pending = false

	local step = {}

	--- Applies the pause layout once, on exit only.
	--- @param termination_kind string|nil "exit" or "reload".
	--- @param on_teardown_ready function|nil The coordinator's readiness callback.
	--- @return boolean|nil accepted True with "pending" while the switch runs.
	--- @return string|nil state "pending" while awaited, nil when the teardown may go on.
	function step.run(termination_kind, on_teardown_ready)
		if termination_kind ~= "exit" or settled then return nil end
		if pending then return true, "pending" end

		local menu = deps.resolve_menu()
		if type(menu) ~= "table" or type(menu.apply_quit_layout) ~= "function" then
			settled = true
			return nil
		end

		if type(on_teardown_ready) ~= "function" then
			-- A reload upgraded to an exit after its teardown ran: there is no
			-- callback to await, so the switch is started and not waited for.
			settled = true
			local ok, err = xpcall(function() return menu.apply_quit_layout(nil) end, debug.traceback)
			if not ok then Logger.error(LOG, "Quit layout switch raised: %s.", tostring(err)) end
			return nil
		end

		local claimed = false
		local installing = true
		pending = true
		local function on_layout_settled(switched, _output, reason)
			if claimed then return end
			claimed = true
			pending = false
			settled = true
			if switched ~= true then
				Logger.error(LOG, "The pause layout was not applied before quitting (%s); quitting anyway.",
					tostring(reason))
			end
			if installing then return end
			local ok, err = xpcall(function()
				return on_teardown_ready(true, "quit-layout")
			end, debug.traceback)
			if not ok then
				Logger.error(LOG, "Quit layout readiness callback raised: %s.", tostring(err))
			end
		end

		local call_ok, state_or_err = xpcall(function()
			return menu.apply_quit_layout(on_layout_settled)
		end, debug.traceback)
		installing = false

		if claimed then
			-- Settled synchronously (an in-process switch): nothing was retained,
			-- so the teardown simply goes on.
			return nil
		end
		if not call_ok or state_or_err ~= "pending" then
			pending = false
			settled = true
			if not call_ok then
				Logger.error(LOG, "Quit layout switch raised: %s.", tostring(state_or_err))
			end
			return nil
		end
		return true, "pending"
	end

	return step
end

return M
