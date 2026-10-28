--- tests/meta/lua_safety/test_json_decode_through_codec.lua

--- ==============================================================================
--- MODULE: JSON Decoding Goes Through The Codec
--- DESCRIPTION:
--- hs.json.decode returns one Lua table for every JSON value equal to one met
--- earlier in the same document (LuaSkin looks up the objects it already
--- pushed by isEqual:). adapters/json_codec.lua turns its result into a tree;
--- a module calling hs.json.decode itself gets the shared graph, where editing
--- one value edits every equal one.
---
--- ROOT CAUSE ENCODED (json-shared-tables):
--- The Karabiner generator decoded its rule files with hs.json.decode and then
--- appended each manipulator's generation gate to CapsWord's shared conditions
--- list: dev.148 refused every deploy. Every production reader now goes through
--- the codec; the only direct call belongs to the adapter itself. This ratchet
--- admits no new direct reader.
--- ==============================================================================

local helpers = require("tests.helpers")
local SourceFile = require("tests.support.source_file")
local CommandLines = require("tests.support.command_lines")
local DRIVER_ROOT = helpers.driver_root()

-- Production modules that still call hs.json.decode directly, with their
-- count of calls. Only ever lower these.
local DIRECT_DECODE_BASELINE = {
	["adapters.json_codec"] = 1,
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
	local source_count = #files
	local inventory = CommandLines.read(command)
	assert(#inventory > 0, "source inventory must not be empty")
	for _, raw_line in ipairs(inventory) do
		local path = raw_line:gsub("\\", "/")
		if path:match("%.lua$") then files[#files + 1] = path end
	end
	assert(#files > source_count, "source inventory contains no matching files")
	return files
end

--- Reads one source file exactly.
--- @param path string Absolute path.
--- @return string source File contents.
local function read_file(path)
	local source = SourceFile.read(path)
	return source
end

--- Counts the calls outside comments.
--- @param source string Lua source text.
--- @return number count
local function count_direct_decodes(source)
	local count = 0
	for line in source:gmatch("[^\n]*") do
		local code = line:gsub("%-%-.*$", "")
		for _ in code:gmatch("hs%.json%.decode") do count = count + 1 end
	end
	return count
end

helpers.describe("JSON decoding goes through the codec (json-shared-tables)", function()
	helpers.it("no production module adds a direct hs.json.decode call (json-shared-tables)", function()
		local root = DRIVER_ROOT:gsub("\\", "/")
		local files = list_lua_files(DRIVER_ROOT)
		helpers.assert_true(#files > 200, "the production source walk must not be vacuous")
		local drift = {}
		local found = {}
		for _, path in ipairs(files) do
			local relative = path:sub(#root + 1)
			if not relative:find("^tests/") and not relative:find("^vendor/") then
				local count = count_direct_decodes(read_file(path) or "")
				if count > 0 then
					local module = relative:gsub("%.lua$", ""):gsub("/", "."):gsub("%.init$", "")
					found[module] = count
					if count ~= DIRECT_DECODE_BASELINE[module] then
						drift[#drift + 1] = string.format("%s: %d call(s), baseline %s",
							module, count, tostring(DIRECT_DECODE_BASELINE[module]))
					end
				end
			end
		end
		for module, count in pairs(DIRECT_DECODE_BASELINE) do
			if not found[module] then
				drift[#drift + 1] = string.format("%s: 0 call(s), baseline %d — lower the baseline", module, count)
			end
		end
		table.sort(drift)
		helpers.assert_eq(#drift, 0, "decode through adapters.json_codec instead:\n" .. table.concat(drift, "\n"))
	end)
end)
