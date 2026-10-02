--- tests/meta/test_json_decode_through_codec.lua

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
--- list: dev.148 refused every deploy. The direct calls left below only read
--- what they decode. This ratchet admits no new one and must be lowered when a
--- call moves to the codec.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

-- Production modules that still call hs.json.decode directly, with their
-- count of calls. Only ever lower these.
local DIRECT_DECODE_BASELINE = {
	["adapters.json_codec"]                          = 1,
	["infra.vscode_bridge"]                          = 1,
	["modules.gestures.actions"]                     = 1,
	["modules.llm.api_common"]                       = 1,
	["modules.llm.api_mlx"]                          = 1,
	["modules.llm"]                                  = 2,
	["ui.changelog"]                                 = 1,
	["ui.console_window"]                            = 1,
	["ui.menu.menu_llm.models_manager"]              = 1,
	["ui.menu.menu_llm.models_manager_mlx_download"] = 2,
	["ui.menu.menu_llm.models_manager_mlx_server"]   = 1,
	["ui.menu.menu_llm.startup_controller"]          = 1,
	["ui.ui_builder"]                                = 1,
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
