--- ui/menu/uninstall.lua

--- ==============================================================================
--- MODULE: Application Uninstall Action
--- DESCRIPTION:
--- Confirms removal of the exact bundled application and hands it to a native
--- worker. The worker requires both explicit authorization and a clean kernel
--- observation of the driver's exit before it may move the app to the Trash.
--- ==============================================================================

local M = {}
local owner = nil

--- Starts one confirmed uninstall transaction without blocking the run loop.
--- @param deps table|nil Injectable menu and native process capabilities.
--- @return boolean accepted
function M.run(deps)
	if owner then return false end
	deps = deps or {}
	local logger = deps.logger or require("infra.logger")
	-- On a source run the About row is greyed and names why, so a click that
	-- still arrives does nothing: logged, with no failure dialog for a removal
	-- that was never possible.
	local updater = deps.updater or require("modules.updater")
	if updater.is_local_source() then
		logger.info("ui.menu.uninstall", "Uninstall ignored: this is a local version run from source, with nothing to remove.")
		return false
	end
	local lifecycle = deps.lifecycle or require("infra.termination_coordinator")
	if lifecycle.is_pending() then return false end
	local i18n = deps.i18n or require("infra.i18n")
	local dialog = deps.dialog or require("infra.dialog_util")
	local resolver = deps.resolver or require("platform.remap.lease_helper")
	local shell = deps.shell or require("adapters.shell_runner")
	local title = i18n.get("menu.global.uninstall")
	local failure = i18n.get("dialog.uninstall.failed")
	local transaction = { buffer = "", phase = "confirming" }
	owner = transaction
	local function fail(detail)
		if owner ~= transaction then return end
		owner = nil
		if transaction.task then transaction.task.terminate() end
		logger.error("ui.menu.uninstall", "Uninstall refused: %s.", tostring(detail))
		dialog.block_alert(title, failure, i18n.get("button.ok"), nil, "critical")
	end
	local executable, detail, environment = resolver.resolve()
	if not executable then fail(detail); return false end
	local remove = i18n.get("button.remove")
	if dialog.block_alert(title, i18n.get("dialog.uninstall.confirm"), remove,
		i18n.get("button.cancel"), "warning") ~= remove then
		owner = nil
		return false
	end
	if lifecycle.is_pending() then fail("another terminal transaction is pending"); return false end
	transaction.phase = "preparing"
	transaction.task = shell.spawn(executable, { "--uninstall", title, failure }, function(code)
		if owner == transaction then fail("native worker exited with status " .. tostring(code)) end
	end, function(_, stdout)
		if owner ~= transaction then return false end
		transaction.buffer = transaction.buffer .. (stdout or "")
		if #transaction.buffer > 128 then fail("invalid native protocol"); return false end
		while transaction.buffer:find("\n", 1, true) do
			local line, remaining = transaction.buffer:match("^([^\n]*)\n(.*)$")
			transaction.buffer = remaining
			if line == "READY" and transaction.phase == "preparing" then
				transaction.phase = "authorizing"
				if not transaction.task.set_input("COMMIT\n") then
					fail("native authorization write failed"); return false
				end
			elseif line == "ACK" and transaction.phase == "authorizing" then
				transaction.phase = "exiting"
				logger.info("ui.menu.uninstall", "Confirmed uninstall handed to the native exit observer.")
				-- Authorization alone never removes the app: the native worker also
				-- requires exit status zero. The quit watchdog uses a non-zero status
				-- if fencing or any teardown stage fails, so that path retains the app.
				if lifecycle.request_user_exit("menu_uninstall") ~= true then
					fail("controlled exit was refused"); return false
				end
			else
				fail("unexpected native protocol state"); return false
			end
		end
		return true
	end, environment)
	if not transaction.task.start() then fail("native worker could not start"); return false end
	return true
end

return M
