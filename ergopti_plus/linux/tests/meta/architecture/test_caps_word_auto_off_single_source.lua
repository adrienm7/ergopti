--- tests/meta/architecture/test_caps_word_auto_off_single_source.lua

--- ==============================================================================
--- MODULE: CapsWord Auto-Off Single-Source Test (Linux driver)
--- DESCRIPTION:
--- What ends CapsWord is declared once: the delimiters are the hotstring
--- delimiter catalogue (keymap.terminators_catalogue), the pointer kinds the
--- manifest section shortcuts.caps_word.pointer. A Linux source that spells
--- either list itself would keep offering, or silently ignoring, a choice the
--- shared declaration changed. This guard fails when a production Linux file
--- that deals with CapsWord quotes a delimiter key beyond the three physical
--- keys a driver may name natively (space, tab, enter; "star" is the magic
--- key's historical key, used by unrelated hotstring code), or quotes a pointer
--- kind outside the one evdev map in modules/shortcuts/caps_word_auto_off.lua.
--- The delay presets have no Linux spelling at all; the JS gate
--- tools/test/test-caps-word-auto-off-single-source.cjs holds every driver to
--- that.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()
local SCAN_DIRS = { "adapters", "infra", "modules", "platform", "ui" }
local NATIVE_KEYS = { space = true, tab = true, enter = true, star = true }
local POINTER_MAP = "modules/shortcuts/caps_word_auto_off.lua"

--- Lists every .lua file under a directory, recursively (lfs or the shell).
--- @param abs string Absolute directory path.
--- @return table Array of absolute paths with forward slashes.
local function list_lua_files(abs)
	local results = {}
	local ok_lfs, lfs = pcall(require, "lfs")
	if ok_lfs then
		local function walk(path)
			for entry in lfs.dir(path) do
				if entry ~= "." and entry ~= ".." then
					local full = path .. "/" .. entry
					local attr = lfs.attributes(full)
					if attr and attr.mode == "directory" then walk(full)
					elseif entry:match("%.lua$") then results[#results + 1] = full end
				end
			end
		end
		walk(abs)
		return results
	end
	local cmd
	if package.config:sub(1, 1) == "\\" then
		cmd = string.format('cmd /c dir /b /s /a-d "%s"', abs:gsub("/", "\\"))
	else
		cmd = string.format("find '%s' -type f -name '*.lua'", abs)
	end
	local pipe = io.popen(cmd)
	if not pipe then return results end
	for line in pipe:lines() do
		line = line:gsub("\\", "/")
		if line:match("%.lua$") then results[#results + 1] = line end
	end
	pipe:close()
	return results
end

local function read_file(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end

helpers.describe("CapsWord auto-off single source (Linux)", function()
	helpers.it("no Linux CapsWord source spells a delimiter or pointer-kind list of its own", function()
		local forbidden_keys = {}
		for _, def in ipairs(require("keymap.terminators_catalogue")) do
			if def.key and not NATIVE_KEYS[def.key] then forbidden_keys[#forbidden_keys + 1] = def.key end
		end
		helpers.assert_true(#forbidden_keys > 10, "the catalogue must provide the delimiter keys")
		local kinds = require("modules.shortcuts.caps_word_auto_off").pointer_kinds()
		helpers.assert_true(#kinds > 0, "the manifest must declare the pointer kinds")

		local scanned, offenders = 0, {}
		for _, dir in ipairs(SCAN_DIRS) do
			for _, path in ipairs(list_lua_files(DRIVER_ROOT .. "/" .. dir)) do
				local source = read_file(path)
				if source and source:lower():find("caps_?word") then
					scanned = scanned + 1
					local rel = path:sub(#DRIVER_ROOT + 2)
					for _, key in ipairs(forbidden_keys) do
						if source:find('"' .. key .. '"', 1, true) or source:find("'" .. key .. "'", 1, true) then
							offenders[#offenders + 1] = rel .. " spells the delimiter " .. key
						end
					end
					if rel ~= POINTER_MAP then
						for _, kind in ipairs(kinds) do
							if source:find('"' .. kind .. '"', 1, true) then
								offenders[#offenders + 1] = rel .. " spells the pointer kind " .. kind
							end
						end
					end
				end
			end
		end
		helpers.assert_true(scanned >= 3, "the scan must reach the CapsWord sources (found " .. scanned .. ")")
		helpers.assert_eq(table.concat(offenders, "; "), "", "read the shared declarations instead")
	end)
end)

return true
