--- adapters/field_check_ports.lua

--- ==============================================================================
--- MODULE: Field Check Ports (Hammerspoon)
--- DESCRIPTION:
--- The real Mac side of infra/field_check.lua: file existence, bounded external
--- commands, the driver facts the checks read (remap, keystats, key event
--- health) and a short passive key counter.
---
--- FEATURES & RATIONALE:
--- 1. Bounded commands: every command settles exactly once, with its exit code,
---    or with nil when it timed out or could not start. A timed-out child is
---    terminated.
--- 2. Counting tap: the key counter is a passive hs.eventtap that returns false
---    for every event and keeps one integer. It never reads a key code, a
---    character or a flag, and it does not count autorepeat.
--- 3. Read-only facts: remap, keystats and health data are read through their
---    public getters; nothing here changes driver state.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local ShellRunner = require("adapters.shell_runner")
local Timer = require("adapters.timer_scheduler")
local FileSystem = require("adapters.file_system")

local LOG = "adapters.field_check_ports"





-- ===========================
-- ===========================
-- ======= 1/ Commands =======
-- ===========================
-- ===========================

--- Runs one executable and settles once.
--- @param executable string Absolute path.
--- @param args table Argument array.
--- @param timeout_s number Seconds before the child is terminated.
--- @param callback function fn(exit_code|nil, stdout).
--- @param environment table|nil Explicit child environment (the launcher's identity).
local function exec(executable, args, timeout_s, callback, environment)
	local settled, timer, handle = false, nil, nil
	local function settle(code, stdout)
		if settled then return end
		settled = true
		if timer then Timer.cancel(timer) end
		callback(code, stdout)
	end
	handle = ShellRunner.spawn(executable, args, function(code, stdout)
		settle(code, stdout)
	end, nil, environment)
	if handle.isSettled() or not handle.start() then
		Logger.warn(LOG, "Could not start %s.", executable:match("[^/]+$") or "a command")
		settle(nil, "")
		return
	end
	timer = Timer.after(timeout_s, function()
		timer = nil
		pcall(handle.terminate)
		settle(nil, "")
	end)
end





-- ============================
-- ============================
-- ======= 2/ Key count =======
-- ============================
-- ============================

--- Counts key-down events for a while, without reading what they are.
--- @param seconds number Watch duration.
--- @param callback function fn({ tap_running = boolean, presses = integer }).
local function count_keys(seconds, callback)
	local presses = 0
	local property = hs.eventtap.event.properties.keyboardEventAutorepeat
	local tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
		local ok, repeated = pcall(event.getProperty, event, property)
		if not (ok and repeated ~= nil and repeated ~= 0) then presses = presses + 1 end
		return false
	end)
	local started = tap:start()
	local running = started ~= nil and tap:isEnabled() == true
	Timer.after(seconds, function()
		tap:stop()
		callback({ tap_running = running, presses = presses })
	end)
end





-- ========================
-- ========================
-- ======= 3/ Facts =======
-- ========================
-- ========================

--- Remap facts, read from memory.
local function remap_facts()
	local Remap = require("platform.remap")
	local phase = "unknown"
	local ok, current = pcall(function() return (require("platform.remap.lease_controller").status()) end)
	if ok and type(current) == "string" then phase = current end
	return { enabled = Remap.get_enabled(), phase = phase, guardian = Remap.guardian_state() }
end

--- Keystats facts, read from memory.
local function keystats_facts()
	local Accounting = require("modules.keystats.physical_accounting_mode")
	local stats = require("modules.keystats.kc_bridge").get_stats()
	return {
		credit_source = Accounting.credit_source(),
		capture_loaded = package.loaded["modules.keystats.physical_capture"] ~= nil,
		ledger_drained = stats.drained_total,
	}
end

--- Downloads the PAC the way the diagnostics probe does; the address is never logged.
--- @param url string PAC address from the system proxy settings.
--- @param callback function fn(status|nil, body|nil).
local function fetch_pac(url, callback)
	local client = require("adapters.http_client").new({ timeout_ms = 6000 })
	client.get(url, {}, function(result)
		callback(result.status, result.body)
	end)
end

--- Runs the native network helper (one HEAD through the managed transport).
--- @param callback function fn(exit_code|nil, stdout); nil when it cannot start.
local function network_chain(callback)
	local python = require("adapters.python_interpreter").resolve()
	local source = debug.getinfo(1, "S").source or ""
	local root = (source:sub(1, 1) == "@" and source:sub(2) or source):match("^(.*)/adapters/field_check_ports%.lua$")
	if not python or not root then
		Logger.warn(LOG, "Network helper unavailable: %s.", python and "no driver root" or "no native Python")
		callback(nil, "")
		return
	end
	exec(python, { "-B", root .. "/modules/llm/managed_network_check.py" }, 40, callback)
end


--- Measures how late the timer service fires.
--- @param seconds number Delay asked of the timer.
--- @param callback function fn(late_ms) with the lateness in milliseconds.
local function timer_probe(seconds, callback)
	local started = hs.timer.secondsSinceEpoch()
	Timer.after(seconds, function()
		callback((hs.timer.secondsSinceEpoch() - started - seconds) * 1000)
	end)
end

--- Path of the running application bundle, or nil when the driver does not run
--- from a bundled application (a source checkout).
--- @return string|nil path
local function app_path()
	local launcher = require("platform.remap.lease_helper").resolve()
	if not launcher then return nil end
	return (launcher:gsub("/Contents/MacOS/ErgoptiPlus$", ""))
end

--- Reads the login item state of the application from its own launcher, which is
--- the only process that may query it (the same read-only role the menu uses).
--- @param callback function fn(state|nil) with enabled, disabled, approval or unavailable.
local function login_startup_status(callback)
	local launcher, _, environment = require("platform.remap.lease_helper").resolve()
	if not launcher then return callback(nil) end
	exec(launcher, { "--login-startup", "status" }, 5, function(code, output)
		local state = code == 0 and tostring(output):match("^(%a+)%s*$") or nil
		if state ~= "enabled" and state ~= "disabled" and state ~= "approval" and state ~= "unavailable" then
			state = nil
		end
		callback(state)
	end, environment)
end

--- Facts about the pieces of the owned runtime that are not installed yet:
--- whether the artifact manifest is pinned, whether the installed-source module
--- can be reached (it is loaded, never acquired), and what a close of the official
--- Karabiner would meet. Nothing is started, closed or changed.
--- @param callback function fn({ unpinned = integer|nil, source = boolean, helper_present = boolean, active = integer|nil }).
local function owned_readiness(callback)
	local source_available = require("adapters.installed_physical_source").new().available()
	require("adapters.karabiner_coexistence").new().describe(function(facts)
		callback({
			unpinned = require("adapters.runtime_owner_ports").unpinned_count(),
			source = source_available == true,
			helper_present = facts.helper_present,
			active = facts.active_processes,
		})
	end)
end

--- The bounded command runner, shared with adapters/runtime_owner_ports.lua.
M.exec = exec

--- The ports of the real Mac.
--- @return table ports
function M.new()
	return {
		path_exists = FileSystem.exists,
		exec = exec,
		home = function() return os.getenv("HOME") end,
		remap_facts = remap_facts,
		keystats_facts = keystats_facts,
		health_counts = function() return require("infra.key_event_health").counts() end,
		count_keys = count_keys,
		fetch_pac = fetch_pac,
		network_chain = network_chain,
		timer_probe = timer_probe,
		owned_readiness = owned_readiness,
		app_path = app_path,
		login_startup_status = login_startup_status,
	}
end

return M
