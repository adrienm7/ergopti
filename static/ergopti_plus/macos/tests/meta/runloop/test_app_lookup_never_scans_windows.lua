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
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

-- Production modules that still call hs.application.get/find directly, with
-- their count of calls. Only ever lower these. The AI model manager resolves
-- its own running process by name ("Hammerspoon" always matches, so the window
-- fallback cannot run); it belongs to the AI lane and moves to
-- RunningApplication.current() there.
local DIRECT_LOOKUP_BASELINE = {
	["ui.menu.menu_llm.models_manager"] = 2,
	["ui.menu.menu_llm.models_manager_mlx_hf"] = 2,
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
