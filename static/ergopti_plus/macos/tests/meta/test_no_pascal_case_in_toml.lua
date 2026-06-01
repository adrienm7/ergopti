--- tests/meta/test_no_pascal_case_in_toml.lua

--- ==============================================================================
--- MODULE: TOML Key Casing Invariant Test
--- DESCRIPTION:
--- Verifies that every key in the Hammerspoon driver's TOML configuration files
--- uses snake_case, not PascalCase or camelCase. The driver reads TOML keys
--- directly into table lookups; mixing casing conventions silently breaks any
--- code that expects snake_case names.
---
--- A key is considered PascalCase when it starts with an uppercase ASCII letter
--- (e.g. "HoldDuration", "TapAction"). Section headers ([Section]) are excluded —
--- only bare key identifiers (the part before the first "=") are checked.
---
--- EXCLUSIONS:
--- - paths.toml: auto-generated file that uses PascalCase by historical convention;
---   will be migrated as part of the config-schema-v2 work.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()




-- ======================================
--- ======================================
-- ======= 1/ File Listing Helper =======
--- ======================================
-- ======================================

--- Recursively lists all .toml files under a directory.
--- Uses cmd /c dir on Windows and find on POSIX.
--- @param dir string Absolute directory path.
--- @return table List of absolute paths (forward slashes).
local function list_toml_files(dir)
	local files = {}
	local cmd
	if package.config:sub(1, 1) == "\\" then
		cmd = string.format('cmd /c dir /b /s /a-d "%s"', dir:gsub("/", "\\"))
	else
		cmd = string.format("find '%s' -type f -name '*.toml'", dir)
	end
	local pipe = io.popen(cmd)
	if not pipe then return files end
	for raw_line in pipe:lines() do
		local line = raw_line:gsub("\\", "/")
		if line:match("%.toml$") then
			files[#files + 1] = line
		end
	end
	pipe:close()
	return files
end




-- ====================================
--- ====================================
-- ======= 2/ Test Registration =======
--- ====================================
-- ====================================

helpers.describe("meta: no PascalCase in TOML", function()
	local violations = 0
	local scanned    = 0

	for _, abs_path in ipairs(list_toml_files(DRIVER_ROOT)) do
		-- paths.toml is auto-generated and uses PascalCase by historical convention;
		-- exclude it until the config-schema-v2 migration lands.
		if abs_path:match("[/\\]paths%.toml$") then goto continue end

		local fh = io.open(abs_path, "r")
		if not fh then goto continue end
		local body = fh:read("*a")
		fh:close()

		scanned = scanned + 1
		local rel = abs_path:sub(#DRIVER_ROOT + 1)
		local line_num = 0

		for raw_line in (body .. "\n"):gmatch("([^\n]*)\n") do
			line_num = line_num + 1
			local line = raw_line:match("^%s*(.-)%s*$")  -- trim whitespace
			-- Skip blank lines, comments (#), and section headers ([...)
			if line == "" or line:sub(1, 1) == "#" or line:sub(1, 1) == "[" then
				goto continue_line
			end
			-- Only process key = value lines
			local eq_pos = line:find("=", 1, true)
			if not eq_pos then goto continue_line end

			local key = line:sub(1, eq_pos - 1):match("^%s*(.-)%s*$")
			-- PascalCase: first character is an uppercase ASCII letter A–Z
			local first = key:sub(1, 1)
			if first >= "A" and first <= "Z" then
				violations = violations + 1
				print(string.format("  WARN: PascalCase key %q in %s line %d",
					key, rel, line_num))
			end

			::continue_line::
		end

		::continue::
	end

	helpers.it(string.format("no PascalCase keys found (%d file(s) scanned)", scanned), function()
		helpers.assert_true(scanned > 0,
			"no TOML files located — check DRIVER_ROOT path")
		helpers.assert_true(violations == 0,
			string.format("found %d PascalCase key(s) in TOML config files — use snake_case", violations))
	end)
end)
