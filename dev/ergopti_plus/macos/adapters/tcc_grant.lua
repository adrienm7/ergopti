--- adapters/tcc_grant.lua

--- ==============================================================================
--- MODULE: TCC Grant Adapter
--- DESCRIPTION:
--- Resets this app's own entry in one macOS privacy list (Accessibility, Screen
--- Recording) so a stale grant cannot mask a refusal.
---
--- FEATURES & RATIONALE:
--- 1. Stale grants: the packaged app is signed ad hoc, so every build has a new
---    code identity. macOS keeps the previous switch checked in System Settings
---    while refusing the new binary, and the user sees a permission that looks
---    granted but is not. Resetting the entry lets the next prompt add a switch
---    that matches the running binary.
--- 2. Own entry only: the reset always names this process's bundle identifier,
---    never a whole service, so other applications keep their grants.
--- 3. Asynchronous: tccutil runs through the shell runner and reports its exact
---    exit, so the caller can prompt only once the entry has settled.
--- 4. No captured `hs` upvalue: the global is read at call time, so a cached
---    adapter never keeps a stale native table.
--- ==============================================================================

local M = {}
local Logger = require("infra.logger")

local LOG = "adapters.tcc_grant"

local TCCUTIL_BIN = "/usr/bin/tccutil"

-- The TCC service names this driver resets; anything else is a caller bug.
local SERVICES = {
	Accessibility = true,
	ScreenCapture = true,
}

--- Returns the bundle identifier macOS files this process's grants under.
--- @return string|nil bundle_id Nil when the running process has none.
--- @return string|nil detail Exact reason when bundle_id is nil.
function M.bundle_id()
	local root = rawget(_G, "hs")
	local info = type(root) == "table" and root.processInfo or nil
	local bundle_id = type(info) == "table" and info.bundleID or nil
	if type(bundle_id) ~= "string" or bundle_id == "" then
		return nil, "hs.processInfo.bundleID is unavailable"
	end
	return bundle_id
end

--- Removes this app's entry from one privacy list.
--- @param service string TCC service name, e.g. "ScreenCapture".
--- @param bundle_id string Exact bundle identifier whose entry is reset.
--- @param on_done function fn(ok, detail) once tccutil has exited.
--- @return boolean started True when tccutil was started.
function M.reset(service, bundle_id, on_done)
	if SERVICES[service] ~= true then
		error("tcc_grant.reset: unsupported service " .. tostring(service), 2)
	end
	if type(bundle_id) ~= "string" or bundle_id == "" then
		error("tcc_grant.reset: bundle_id must be a non-empty string", 2)
	end
	if type(on_done) ~= "function" then error("tcc_grant.reset: on_done must be a function", 2) end
	local own_bundle_id = M.bundle_id()
	if own_bundle_id == nil or bundle_id ~= own_bundle_id then
		Logger.error(LOG, "Refusing to reset a privacy grant outside this process's bundle identity.")
		return false
	end
	local ShellRunner = require("adapters.shell_runner")
	local handle = ShellRunner.spawn(TCCUTIL_BIN, { "reset", service, bundle_id },
		function(exit_code, stdout, stderr)
			if exit_code == 0 then
				on_done(true)
			else
				on_done(false, string.format("tccutil exited with %s: %s", tostring(exit_code),
					tostring(stderr ~= "" and stderr or stdout)))
			end
		end)
	if handle.start() == true then return true end
	-- A refused start can still have launched the native process. ShellRunner
	-- retains it until its exact exit; keep the caller's permission gate closed
	-- until that settlement proves tccutil can no longer revoke the grant.
	if handle.isSettled() then return false end
	local registered = handle.onSettled(function()
		on_done(false, "tccutil start was refused after an unsettled launch")
	end)
	if registered ~= true then
		Logger.error(LOG, "Could not observe the unsettled tccutil process; retaining the permission gate.")
	end
	return true
end

return M
