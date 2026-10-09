--- tests/meta/test_windows_become_key.lua

--- ==============================================================================
--- MODULE: Every Window Comes Forward When Clicked
--- DESCRIPTION:
--- Hammerspoon's webview window becomes key only while it allows text entry
--- (extensions/webview/libwebview.m: canBecomeKeyWindow returns
--- allowKeyboardEntry, which starts off). A window that cannot become key does
--- not activate the app when clicked, so a window of the inactive Hammerspoon
--- app stays behind the user's windows however often it is clicked.
---
--- ROOT CAUSE ENCODED (windows-become-key):
--- The error window, the release list, the config cleanup, the download window
--- and the changelog turned text entry off, and a user saw the error window
--- « never come to the front, as if its z-index were the lowest ». No
--- production module may turn it off, and every module that builds a webview
--- window itself turns it on.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

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

--- Reads one source file with its comments removed.
--- @param path string Absolute path.
--- @return string code
local function read_code(path)
	local handle = io.open(path, "rb")
	if not handle then return "" end
	local source = handle:read("*a")
	handle:close()
	local lines = {}
	for line in source:gmatch("[^\n]*") do lines[#lines + 1] = line:gsub("%-%-.*$", "") end
	return table.concat(lines, "\n")
end

helpers.describe("every window comes forward when clicked (windows-become-key)", function()
	helpers.it("no production module turns a window's text entry off (windows-become-key)", function()
		local root = DRIVER_ROOT:gsub("\\", "/")
		local files = list_lua_files(DRIVER_ROOT)
		helpers.assert_true(#files > 200, "the production source walk must not be vacuous")
		local offenders = {}
		local builders = 0
		for _, path in ipairs(files) do
			local relative = path:sub(#root + 1)
			if not relative:find("^tests/") and not relative:find("^vendor/") then
				local code = read_code(path)
				if code:find("allowTextEntry%(%s*false%s*%)") then
					offenders[#offenders + 1] = relative .. ": allowTextEntry(false)"
				end
				if code:find("allow_text_entry%s*=") then
					offenders[#offenders + 1] = relative .. ": passes allow_text_entry"
				end
				-- The factory's 1x1 prewarm view is never shown; every other
				-- builder of a window must turn text entry on.
				if code:find("hs%.webview%.new%f[^%w_]") then
					builders = builders + 1
					if not code:find("allowTextEntry%(%s*true%s*%)") then
						offenders[#offenders + 1] = relative .. ": builds a webview without allowTextEntry(true)"
					end
				end
			end
		end
		helpers.assert_true(builders >= 3, "the scan found the webview builders")
		helpers.assert_eq(#offenders, 0, table.concat(offenders, "\n"))
	end)
end)
