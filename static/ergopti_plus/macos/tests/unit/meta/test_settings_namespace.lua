--- tests/unit/meta/test_settings_namespace.lua

--- ==============================================================================
--- MODULE: Hammerspoon Settings Namespace Guard
--- DESCRIPTION:
--- Prevents production modules from bypassing the Storage adapter and writing
--- unowned keys into Hammerspoon's process-global defaults domain.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()
local PRODUCTION_SOURCE_FLOOR = 200
local RAW_SETTINGS_OWNERS = {
	["adapters/log_transport.lua"] = true,
	["adapters/storage.lua"] = true,
}

--- Lists production Lua files recursively without LuaFileSystem.
--- @param directory string
--- @return table files
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
		if path:match("%.lua$") and not path:find("/tests/", 1, true)
			and not path:find("/vendor/", 1, true) then
			files[#files + 1] = path
		end
	end
	pipe:close()
	return files
end

--- Reads a file exactly.
--- @param path string
--- @return string|nil source
local function read_file(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local source = handle:read("*a")
	handle:close()
	return source
end

--- Projects Lua source to executable tokens by removing comments and literals.
--- @param source string
--- @return string code
local function project_executable(source)
	local output = {}
	local length = #source
	local index = 1
	local function append(value) output[#output + 1] = value end
	local function long_bracket(at)
		local equals = source:sub(at):match("^%[(=*)%[")
		if not equals then return nil end
		return equals, at + #equals + 2
	end
	while index <= length do
		local char = source:sub(index, index)
		local next_char = source:sub(index + 1, index + 1)
		if char == "-" and next_char == "-" then
			local equals, content_at = long_bracket(index + 2)
			if equals then
				local close_at = source:find("]" .. equals .. "]", content_at, true)
				index = close_at and (close_at + #equals + 2) or (length + 1)
				append(" ")
			else
				local newline_at = source:find("\n", index + 2, true)
				index = newline_at or (length + 1)
				if newline_at then append("\n"); index = index + 1 end
			end
		elseif char == "'" or char == '"' then
			local quote = char
			local cursor = index + 1
			while cursor <= length do
				local current = source:sub(cursor, cursor)
				if current == "\\" then
					cursor = cursor + 1
				elseif current == quote then
					break
				end
				cursor = cursor + 1
			end
			append(" ")
			index = math.min(cursor + 1, length + 1)
		elseif char == "[" then
			local equals, content_at = long_bracket(index)
			if equals then
				local close = "]" .. equals .. "]"
				local close_at = source:find(close, content_at, true)
				append(" ")
				index = close_at and (close_at + #close) or (length + 1)
			else
				append(char)
				index = index + 1
			end
		else
			append(char)
			index = index + 1
		end
	end
	return table.concat(output)
end

--- @param source string
--- @return boolean
local function uses_raw_settings(source)
	return project_executable(source):find("hs%s*%.%s*settings") ~= nil
end

helpers.describe("Hammerspoon settings namespace", function()
	helpers.it("routes every production settings access through an explicit owner", function()
		local files = list_lua_files(DRIVER_ROOT)
		helpers.assert_true(#files > PRODUCTION_SOURCE_FLOOR,
			"the production Lua inventory must not be vacuous")
		local found = {}
		for _, path in ipairs(files) do
			local source = read_file(path)
			if source and uses_raw_settings(source) then
				local relative = path:match("/macos/(.+)$")
				helpers.assert_not_nil(relative,
					"settings owner must resolve relative to the macOS driver")
				found[relative] = true
			end
		end
		for path in pairs(found) do
			helpers.assert_true(RAW_SETTINGS_OWNERS[path] == true,
				"raw hs.settings access escaped the canonical owners: " .. path)
		end
		for path in pairs(RAW_SETTINGS_OWNERS) do
			helpers.assert_true(found[path] == true,
				"expected raw settings owner was not inventoried: " .. path)
		end
	end)

	helpers.it("detects executable bypasses without matching comments or strings", function()
		helpers.assert_true(uses_raw_settings('hs.settings.set("foreign", true)'))
		helpers.assert_true(not uses_raw_settings('-- hs.settings.set("foreign", true)\nreturn true'))
		helpers.assert_true(not uses_raw_settings('local text = "hs.settings.get"\nreturn text'))
	end)

	helpers.it("migrates the finite legacy allowlist before the first consumer loads", function()
		local source = read_file(DRIVER_ROOT .. "init.lua")
		helpers.assert_not_nil(source, "root init.lua must be readable")
		local code = project_executable(source)
		local migrate_at = code:find("Storage%s*%.%s*migrate_legacy_namespace%s*%(")
		local consumer_at = code:find("local%s+SyntheticInput%s*=%s*require%s*%(")
		helpers.assert_not_nil(migrate_at, "boot must invoke the settings namespace migration")
		helpers.assert_not_nil(consumer_at, "boot must load the first settings consumer")
		helpers.assert_true(migrate_at < consumer_at,
			"legacy settings must migrate before SyntheticInput reads its reservation key")
	end)
end)
