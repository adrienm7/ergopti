--- tests/meta/runloop/test_app_lookup_never_scans_windows.lua

--- ==============================================================================
--- MODULE: Application Lookups Never Scan Windows
--- DESCRIPTION:
--- hs.application.get(name) is hs.application.find(name, false, true). When no
--- running application matches by bundle identifier or name fragment, find()
--- falls back to hs.window.find(name), which calls hs.window.allWindows(): every
--- window of every running application read through Accessibility on the main
--- thread, macOS allowing each application six seconds to answer.
---
--- ROOT CAUSE ENCODED (app-lookup-no-window-scan):
--- The keylogger's ingest flush resolved each batched application's category
--- with hs.application.get(name). One of them had quit; Hammerspoon printed its
--- Spotlight hint (emitted inside find() just before the window fallback) and
--- froze for 13.4 s. The event taps were disabled, the logger stalled and the
--- Karabiner lease worker fenced after 17.5 s without a heartbeat (issue #99).
--- Every production lookup goes through adapters/running_application.lua, which
--- stays on the process list. This ratchet admits no new direct call.
---
--- ROOT CAUSE ENCODED (webview-window-no-global-scan):
--- webview:hswindow() and hs.console.hswindow() call hs.window.windowForID, an
--- alias of hs.window.get, which runs find() over hs.window.allWindows(). Every
--- webview open and every focus retry paid that scan: 2.8 s to 3.2 s per window
--- on macOS 26 (issue #100). Webview and console windows are resolved by
--- adapters/own_window.lua among this process's windows; the global window
--- enumerations below are ratcheted, and none may appear on a window open path.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

-- Production modules that still call hs.application.get/find directly, with
-- their count of calls. Only ever lower these; the AI model managers now find
-- their own process with RunningApplication.current(), so none remains.
local DIRECT_LOOKUP_BASELINE = {}

-- The one owner allowed to call hswindow(): it records the window number
-- instead of letting windowForID scan.
local WINDOW_LOOKUP_OWNER = "adapters.own_window"

-- Production modules that still enumerate every window of every application,
-- with their count of calls. Only ever lower these. All of them answer a user
-- gesture or a port read that is global by nature (window switching, the
-- WindowManager and WindowInfo ports, the unused focus filter of the process
-- lifecycle); none runs when a window opens.
local WINDOW_SCAN_BASELINE = {
	["adapters.process_lifecycle"] = 2,
	["adapters.window_info"] = 1,
	["adapters.window_manager"] = 5,
	["platform.remap.watchers"] = 1,
}

-- Call shapes that reach hs.window.allWindows(), directly or through
-- windowForID, get, find, the hs.window(hint) constructor or a window filter.
-- A single application's app:allWindows() is not among them.
local WINDOW_SCAN_PATTERNS = {
	"hswindow%s*%(",
	"%f[%w_]window%.allWindows%s*%(",
	"%f[%w_]window%.orderedWindows%s*%(",
	"%f[%w_]window%.visibleWindows%s*%(",
	"%f[%w_]window%.invisibleWindows%s*%(",
	"%f[%w_]window%.minimizedWindows%s*%(",
	"%f[%w_]window%.get%s*%(",
	"%f[%w_]window%.find%s*%(",
	"windowForID%s*%(",
	"%f[%w_]window%.filter%.",
	"%f[%w_]window%.filter%s*%(",
	"windowfilter",
	"%f[%w_]hs%.window%s*%(",
}

--- Lists production Lua files recursively without relying on LuaFileSystem.
--- @param directory string Absolute directory path.
--- @return table files Absolute source paths.
local function list_lua_files(directory)
	local files = {}
	local command
	if package.config:sub(1, 1) == "\\" then
		command = string.format('cmd /c dir /b /s /a-d "%s"', directory:gsub("/", "\\"))
	else
		command = string.format("find '%s' -type f", directory)
	end
	local pipe = io.popen(command)
	if not pipe then return files end
	for raw_line in pipe:lines() do
		local path = raw_line:gsub("\\", "/")
		if path:match("%.lua$") then files[#files + 1] = path end
	end
	pipe:close()
	return files
end

--- Reads one source file exactly.
--- @param path string Absolute path.
--- @return string|nil source File contents.
local function read_file(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local source = handle:read("*a")
	handle:close()
	return source
end

--- Counts application name lookups outside comments, aliased or not.
--- @param source string Lua source text.
--- @return number count
local function count_direct_lookups(source)
	local count = 0
	for line in source:gmatch("[^\n]*") do
		local code = line:gsub("%-%-.*$", "")
		for _ in code:gmatch("application%.get%s*%(") do count = count + 1 end
		for _ in code:gmatch("application%.find%s*%(") do count = count + 1 end
	end
	return count
end

--- Counts global window enumerations outside comments.
--- @param source string Lua source text.
--- @return number count
local function count_window_scans(source)
	local count = 0
	for line in source:gmatch("[^\n]*") do
		local code = line:gsub("%-%-.*$", "")
		for _, pattern in ipairs(WINDOW_SCAN_PATTERNS) do
			for _ in code:gmatch(pattern) do count = count + 1 end
		end
	end
	return count
end

--- Maps every production module to its count from `counter`, skipping zeros.
--- @param counter function Source counter.
--- @return table found Module name to count.
local function production_counts(counter)
	local root = DRIVER_ROOT:gsub("\\", "/")
	local files = list_lua_files(DRIVER_ROOT)
	helpers.assert_true(#files > 200, "the production source walk must not be vacuous")
	local found = {}
	for _, path in ipairs(files) do
		local relative = path:sub(#root + 1)
		if not relative:find("^tests/") and not relative:find("^vendor/") then
			local count = counter(read_file(path) or "")
			if count > 0 then
				local module = relative:gsub("%.lua$", ""):gsub("/", "."):gsub("%.init$", "")
				found[module] = count
			end
		end
	end
	return found
end

helpers.describe("application lookups never scan windows (app-lookup-no-window-scan)", function()
	helpers.it("the counter sees an aliased and a direct call but not a comment (app-lookup-no-window-scan)", function()
		helpers.assert_eq(count_direct_lookups(
			"local a = hs.application.get(name)\n"
			.. "local b = application.find (name)\n"
			.. "-- hs.application.get(name) in a comment\n"), 2,
			"the scan must count the call shapes it guards, or a red tree reads green")
	end)

	helpers.it("no production module calls hs.application.get or find directly (app-lookup-no-window-scan)", function()
		local root = DRIVER_ROOT:gsub("\\", "/")
		local files = list_lua_files(DRIVER_ROOT)
		helpers.assert_true(#files > 200, "the production source walk must not be vacuous")
		local drift = {}
		local found = {}
		for _, path in ipairs(files) do
			local relative = path:sub(#root + 1)
			if not relative:find("^tests/") and not relative:find("^vendor/") then
				local count = count_direct_lookups(read_file(path) or "")
				if count > 0 then
					local module = relative:gsub("%.lua$", ""):gsub("/", "."):gsub("%.init$", "")
					found[module] = count
					if count ~= DIRECT_LOOKUP_BASELINE[module] then
						drift[#drift + 1] = string.format("%s: %d call(s), baseline %s",
							module, count, tostring(DIRECT_LOOKUP_BASELINE[module]))
					end
				end
			end
		end
		for module, count in pairs(DIRECT_LOOKUP_BASELINE) do
			if not found[module] then
				drift[#drift + 1] = string.format("%s: 0 call(s), baseline %d — lower the baseline", module, count)
			end
		end
		table.sort(drift)
		helpers.assert_eq(#drift, 0,
			"resolve running applications through adapters.running_application instead:\n"
			.. table.concat(drift, "\n"))
	end)
end)

helpers.describe("webview windows never scan every window (webview-window-no-global-scan)", function()
	helpers.it("the counter sees every scan shape but not a comment or one app's windows (webview-window-no-global-scan)", function()
		helpers.assert_eq(count_window_scans(
			"local a = wv:hswindow()\n"
			.. "local b = hs.console.hswindow()\n"
			.. "local c = hs.window.allWindows()\n"
			.. "local d = hs.window.orderedWindows()\n"
			.. "local e = hs.window.visibleWindows()\n"
			.. "local f = hs.window.get(id)\n"
			.. "local g = hs.window.find(title)\n"
			.. "local h = hs.window.windowForID(id)\n"
			.. "local i = hs.window.filter.new()\n"
			.. "local j = hs.window(id)\n"
			.. "local k = app:allWindows()\n"
			.. "local l = own_window.get(view)\n"
			.. "if id == \"window.filter\" then end\n"
			.. "-- wv:hswindow() in a comment\n"), 10,
			"the scan must count the call shapes it guards, or a red tree reads green")
	end)

	helpers.it("only the own-window adapter calls hswindow() (webview-window-no-global-scan)", function()
		local found = production_counts(function(source)
			local count = 0
			for line in source:gmatch("[^\n]*") do
				for _ in line:gsub("%-%-.*$", ""):gmatch("hswindow%s*%(") do count = count + 1 end
			end
			return count
		end)
		helpers.assert_true(found[WINDOW_LOOKUP_OWNER] ~= nil,
			"the own-window adapter must still own the hswindow() call, or this guard is vacuous")
		local callers = {}
		for module in pairs(found) do
			if module ~= WINDOW_LOOKUP_OWNER then callers[#callers + 1] = module end
		end
		table.sort(callers)
		helpers.assert_eq(#callers, 0,
			"resolve webview and console windows through adapters.own_window instead:\n"
			.. table.concat(callers, "\n"))
	end)

	helpers.it("no production module adds a global window enumeration (webview-window-no-global-scan)", function()
		local found = production_counts(count_window_scans)
		local drift = {}
		for module, count in pairs(found) do
			if module ~= WINDOW_LOOKUP_OWNER and count ~= WINDOW_SCAN_BASELINE[module] then
				drift[#drift + 1] = string.format("%s: %d call(s), baseline %s",
					module, count, tostring(WINDOW_SCAN_BASELINE[module]))
			end
		end
		for module, count in pairs(WINDOW_SCAN_BASELINE) do
			if not found[module] then
				drift[#drift + 1] = string.format("%s: 0 call(s), baseline %d — lower the baseline", module, count)
			end
		end
		table.sort(drift)
		helpers.assert_eq(#drift, 0,
			"find a window among one application's windows (adapters.own_window for this process):\n"
			.. table.concat(drift, "\n"))
	end)

	helpers.it("no window open path enumerates every window (webview-window-no-global-scan)", function()
		for module in pairs(WINDOW_SCAN_BASELINE) do
			helpers.assert_true(not module:find("^ui%."),
				module .. " is a window open path: it may not keep a global window scan")
		end
	end)
end)
