--- _shared/lua/healthcheck/configuration.lua

--- ==============================================================================
--- MODULE: Diagnostics Configuration Reducer (Shared Lua)
--- DESCRIPTION:
--- Turns a user's decoded config.toml into the closed rows of the diagnostics
--- `configuration` section. Only manifest-declared settings are read, so a key
--- the user invented (a model name, a custom delimiter) never becomes a row.
---
--- FEATURES & RATIONALE:
--- 1. Booleans, numbers and manifest enum values are reported exactly.
--- 2. Every other string is reduced to its length in characters, and every
---    array to its item count: a path or a sentence typed into a text setting
---    cannot leave the machine through this section.
--- 3. The AHK port (windows/ui/healthcheck/configuration.ahk) replays the same
---    vectors (_shared/tests/corpus/healthcheck/configuration_vectors.json).
--- 4. read_files and collect report the state of each configuration file in
---    the order they apply: ok, missing, unreadable or invalid. A file that
---    cannot be read is named, never skipped, and nothing is cached or written.
--- ==============================================================================

local M = {}

-- The platform token of each driver in the generated feature manifest
local PLATFORM_OF_DRIVER = { windows = "ahk", macos = "hs", linux = "linux" }

--- Counts the characters of a UTF-8 string without the utf8 library, which
--- LuaJIT (the Linux driver) does not ship.
--- @param text string
--- @return integer
local function character_count(text)
	local _, continuation = text:gsub("[\128-\191]", "")
	return #text - continuation
end

--- Renders a number the same way on every driver: an integer without a
--- fraction, anything else with 14 significant digits.
--- @param value number
--- @return string|nil nil for NaN and infinities.
local function number_text(value)
	if value ~= value or value == math.huge or value == -math.huge then return nil end
	if value == math.floor(value) and math.abs(value) < 1e15 then return string.format("%d", value) end
	return string.format("%.14g", value)
end

--- True when a decoded TOML table is a list (consecutive integer keys).
--- @param value table
--- @return boolean
local function is_list(value)
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" then return false end
		count = count + 1
	end
	return count == #value
end

--- Walks a dotted path through nested tables.
--- @param document table
--- @param path string
--- @return any|nil
local function lookup(document, path)
	local node = document
	for segment in path:gmatch("[^.]+") do
		if type(node) ~= "table" then return nil end
		node = node[segment]
	end
	return node
end

--- Reduces one decoded value to a row, or nil when it is not a reportable leaf.
--- @param path string
--- @param value any
--- @param enum_values table|nil The manifest enum, when the setting is one.
--- @return table|nil
local function reduce(path, value, enum_values)
	if type(value) == "boolean" then return { setting = path, type = "boolean", value = tostring(value) } end
	if type(value) == "number" then
		local text = number_text(value)
		return text and { setting = path, type = "number", value = text } or nil
	end
	if type(value) == "string" then
		for _, accepted in ipairs(enum_values or {}) do
			if value == accepted then return { setting = path, type = "enum", value = value } end
		end
		return { setting = path, type = "text", value = tostring(character_count(value)) }
	end
	if type(value) == "table" and is_list(value) then
		return { setting = path, type = "list", value = tostring(#value) }
	end
	return nil
end

--- The reportable rows of a configuration document.
--- @param features table Manifest entries: path, default, platforms, enum_values.
--- @param document table Decoded config.toml.
--- @param driver string windows, macos or linux.
--- @param limit integer Most rows to return.
--- @return table rows Sorted by setting.
function M.rows(features, document, driver, limit)
	local platform = assert(PLATFORM_OF_DRIVER[driver], "unknown diagnostics driver")
	local rows = {}
	local function add(path, value, enum_values)
		local row = reduce(path, value, enum_values)
		if row then rows[#rows + 1] = row end
	end
	for _, feature in ipairs(features) do
		local applies = false
		for _, token in ipairs(feature.platforms or {}) do
			if token == platform then applies = true end
		end
		if applies and type(document) == "table" then
			if type(feature.default) == "table" and not is_list(feature.default) then
				for key in pairs(feature.default) do
					local path = feature.path .. "." .. key
					add(path, lookup(document, path), nil)
				end
			else
				add(feature.path, lookup(document, feature.path), feature.enum_values)
			end
		end
	end
	table.sort(rows, function(left, right) return left.setting < right.setting end)
	while #rows > limit do rows[#rows] = nil end
	return rows
end

-- errno of a file that does not exist: the one open failure that means
-- "missing" rather than "present but unreadable"
local ENOENT = 2

--- Reads the configuration files in the order they apply and reports each
--- state: ok, missing, unreadable (a folder, a permission, a lock) or invalid
--- (the config.toml that does not decode). Nothing is cached or written.
--- @param ids table File ids, defaults first.
--- @param path_of function Maps an id to its path.
--- @param decode function TOML text to table; raises on malformed input.
--- @param open_fn function|nil io.open replacement for tests.
--- @return table items Rows { id, state }.
--- @return table|nil document The decoded config.toml.
function M.read_files(ids, path_of, decode, open_fn)
	open_fn = open_fn or io.open
	local items, document = {}, nil
	for _, id in ipairs(ids) do
		local state = "ok"
		if id ~= "defaults" then
			local handle, _, code = open_fn(path_of(id), "rb")
			if not handle then
				state = code == ENOENT and "missing" or "unreadable"
			else
				local read_ok, content = pcall(handle.read, handle, "*a")
				handle:close()
				if not read_ok or type(content) ~= "string" then
					state = "unreadable"
				elseif id == "config" then
					local decoded_ok, decoded = pcall(decode, content)
					if decoded_ok and type(decoded) == "table" then document = decoded else state = "invalid" end
				end
			end
		end
		items[#items + 1] = { id = id, state = state }
	end
	return items, document
end

--- Collects both configuration sections of the snapshot.
--- @param schema table The diagnostics schema.
--- @param driver string windows, macos or linux.
--- @param features table The generated manifest's feature entries.
--- @param path_of function Maps a file id to its path.
--- @param decode function TOML text to table.
--- @param open_fn function|nil io.open replacement for tests.
--- @return table { files = { items }, settings = { items } }
function M.collect(schema, driver, features, path_of, decode, open_fn)
	local spec = schema.configuration
	local items, document = M.read_files(spec.files[driver], path_of, decode, open_fn)
	local rows = document and M.rows(features, document, driver, spec.max_rows) or {}
	return { files = { items = items }, settings = { items = rows } }
end

return M
