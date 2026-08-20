--- tests/meta/test_input_source_single_native_owner.lua

--- ==============================================================================
--- MODULE: Input Source Single Native Owner Guard
--- DESCRIPTION:
--- Walks every production Lua source and rejects direct uses of Hammerspoon's
--- setter-only input-source callback outside the one multiplexing adapter.
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
		command = string.format('cmd /c dir /b /s /a-d "%s"',
			directory:gsub("/", "\\"))
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

--- Removes line comments before searching executable source.
--- @param source string Lua source text.
--- @return string code Source with full-line and trailing comments removed.
local function strip_comments(source)
	local lines = {}
	for line in source:gmatch("[^\n]*") do
		lines[#lines + 1] = line:gsub("%-%-.*$", "")
	end
	return table.concat(lines, "\n")
end

helpers.describe("inputSourceChanged single native owner", function()
	helpers.it("only adapters.input_source_broker calls the global setter", function()
		local files = list_lua_files(DRIVER_ROOT)
		helpers.assert_true(#files > 200,
			"the production source walk must not be vacuous")
		local owners = {}
		for _, path in ipairs(files) do
			if not path:find("/tests/", 1, true) then
				local source = read_file(path)
				-- Scan the API token, not one receiver spelling: an alias such as
				-- `local keycodes = hs.keycodes` must not bypass the ownership ratchet.
				if source and strip_comments(source):find("inputSourceChanged", 1, true) then
					owners[#owners + 1] = path:gsub("\\", "/")
				end
			end
		end
		helpers.assert_eq(1, #owners,
			"the setter-only native slot must have exactly one production owner")
		helpers.assert_true(owners[1]:match("/adapters/input_source_broker%.lua$") ~= nil,
			"the native owner must be adapters.input_source_broker, got " .. tostring(owners[1]))
	end)
end)
