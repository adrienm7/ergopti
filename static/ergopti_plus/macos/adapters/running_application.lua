--- adapters/running_application.lua

--- ==============================================================================
--- MODULE: Running Application Lookup Adapter (Hammerspoon)
--- DESCRIPTION:
--- Resolves a running application by exact name, bundle identifier or PID
--- without ever enumerating windows.
---
--- FEATURES & RATIONALE:
--- 1. No window scan: hs.application.get(name) is find(name, false, true). When
---    no running application matches, it falls back to hs.window.find(name),
---    which reads every window of every running application through
---    Accessibility on the main thread, waiting up to six seconds for each
---    application that does not answer. The keylogger's per-flush category
---    lookup of an application that had quit froze Hammerspoon for 13.4 s that
---    way: the event taps were disabled and the Karabiner lease lost its
---    heartbeats (issue #99). Every lookup here stays on the process list.
--- 2. Exact names: a name is compared with the localised name Hammerspoon
---    reports, never as a case-insensitive fragment, so "Mail" cannot resolve
---    "Mailspring".
--- 3. Late binding: the global `hs` is read at call time, so a test double
---    installed after this module loaded is the one consulted.
--- ==============================================================================

local M = {}





-- ============================================
-- ============================================
-- ======= 1/ Running Application Reads =======
-- ============================================
-- ============================================

--- Returns the native application namespace, or nil when it is absent.
--- @return table|nil application The hs.application namespace.
local function application_namespace()
	local native = rawget(_G, "hs")
	if type(native) ~= "table" then return nil end
	local application = native.application
	if type(application) ~= "table" then return nil end
	return application
end

--- Returns the running application whose name is exactly `name`.
--- Regular (Dock) applications win over background ones of the same name,
--- as hs.application.find orders them.
--- @param name string Localised application name as Hammerspoon reports it.
--- @return userdata|table|nil app The running application, or nil.
function M.by_name(name)
	if type(name) ~= "string" or name == "" then return nil end
	local application = application_namespace()
	if not application or type(application.runningApplications) ~= "function" then return nil end
	local best, best_kind = nil, nil
	for _, app in ipairs(application.runningApplications() or {}) do
		local ok_name, app_name = pcall(function() return app:name() end)
		if ok_name and app_name == name then
			local ok_kind, kind = pcall(function() return app:kind() end)
			kind = (ok_kind and type(kind) == "number") and kind or -1
			if best == nil or kind > best_kind then best, best_kind = app, kind end
		end
	end
	return best
end

--- Returns the first running application with the exact bundle identifier.
--- @param bundle_id string Bundle identifier such as "com.apple.Safari".
--- @return userdata|table|nil app The running application, or nil.
function M.by_bundle_id(bundle_id)
	if type(bundle_id) ~= "string" or bundle_id == "" then return nil end
	local application = application_namespace()
	if not application or type(application.applicationsForBundleID) ~= "function" then return nil end
	local apps = application.applicationsForBundleID(bundle_id)
	if type(apps) ~= "table" then return nil end
	return apps[1]
end

--- Returns the application object of the running Hammerspoon process.
--- @return userdata|table|nil app This process as an application, or nil.
function M.current()
	local native = rawget(_G, "hs")
	local application = application_namespace()
	if not application or type(application.applicationForPID) ~= "function" then return nil end
	local process_info = type(native.processInfo) == "table" and native.processInfo or nil
	local pid = process_info and process_info.processID
	if type(pid) ~= "number" then return nil end
	return application.applicationForPID(pid)
end

return M
