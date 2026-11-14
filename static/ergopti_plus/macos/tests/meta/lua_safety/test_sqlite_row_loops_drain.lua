--- tests/meta/lua_safety/test_sqlite_row_loops_drain.lua

--- ==============================================================================
--- MODULE: SQLite Row Loops Drain Their Statement
--- DESCRIPTION:
--- A statement behind db:nrows, db:urows or db:rows runs until its iterator ends.
--- Leaving such a loop early keeps it running until the collector finalizes it,
--- and meanwhile SQLite refuses VACUUM on that connection. That is how
--- "cannot VACUUM - SQL statements in progress" lost the pre-encoding backup on
--- the Mac of field report 2026-11-01. A loop keeps the value and returns after
--- its end.
--- ==============================================================================

local helpers = require("tests.helpers")
local SourceFile = require("tests.support.source_file")
local CommandLines = require("tests.support.command_lines")

local DRIVER_ROOT = helpers.driver_root()
local SOURCE_ROOTS = {
	DRIVER_ROOT .. "ui",
	DRIVER_ROOT .. "modules",
	DRIVER_ROOT .. "infra",
	DRIVER_ROOT .. "adapters",
	DRIVER_ROOT .. "core",
	helpers.shared(""),
}
local ROW_ITERATOR = "^%s*for%s.-%sin%s+[%w_%.]*db:[nu]?rows%("

--- Lists the driver's Lua sources under one root.
--- @param root string Directory.
--- @return string[] paths
local function lua_files(root)
	local windows = package.config:sub(1, 1) == "\\"
	local command = windows and string.format('cmd /c dir /b /s /a-d "%s"', (root:gsub("/", "\\")))
		or string.format("find '%s' -type f", root)
	local files = {}
	local inventory = CommandLines.read(command)
	assert(#inventory > 0, "source inventory must not be empty")
	for _, raw in ipairs(inventory) do
		local path = raw:gsub("\\", "/")
		if path:find("%.lua$") and not path:find("/tests/", 1, true) then files[#files + 1] = path end
	end
	return files
end

--- Returns the indentation of a source line.
--- @param line string Source line.
--- @return integer tabs
local function indentation(line)
	return #line:match("^\t*")
end

--- Finds the early exits of every multi-line row loop of a source.
--- @param source string Lua source.
--- @return string[] sites One "line: text" per early exit.
local function early_exits(source)
	local lines, sites = {}, {}
	for line in (source .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
	for index, line in ipairs(lines) do
		if line:find(ROW_ITERATOR) and not line:find("%send%s*$") then
			local depth = indentation(line)
			for inner = index + 1, #lines do
				local text = lines[inner]
				if text:find("%S") and indentation(text) <= depth then break end
				if text:find("%f[%w]return%f[%W]") or text:find("%f[%w]break%f[%W]") then
					sites[#sites + 1] = string.format("%d: %s", inner, text:match("^%s*(.-)$"))
				end
			end
		end
	end
	return sites
end

helpers.describe("meta: SQLite row loops drain their statement", function()
	helpers.it("the scan names an early exit and accepts a drained loop", function()
		local leaking = "for row in db:nrows(sql) do\n\treturn row.value\nend\n"
		local drained = "local value\nfor row in db:nrows(sql) do\n\tvalue = row.value\nend\nreturn value\n"
		helpers.assert_eq(#early_exits(leaking), 1)
		helpers.assert_eq(#early_exits(drained), 0)
	end)

	helpers.it("no driver source leaves a row loop early", function()
		local scanned, offenders = 0, {}
		for _, root in ipairs(SOURCE_ROOTS) do
			for _, path in ipairs(lua_files(root)) do
				scanned = scanned + 1
				for _, site in ipairs(early_exits(SourceFile.read(path))) do
					offenders[#offenders + 1] = path .. ":" .. site
				end
			end
		end
		helpers.assert_true(scanned > 100, "the scan must reach the driver sources")
		helpers.assert_eq(#offenders, 0, table.concat(offenders, "\n"))
	end)
end)
