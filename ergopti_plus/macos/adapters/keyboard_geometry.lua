--- adapters/keyboard_geometry.lua

--- ==============================================================================
--- MODULE: Native Keyboard Geometry
--- DESCRIPTION:
--- Resolves a Quartz event's keyboard model through the launcher's Carbon map.
--- Input callbacks only consult immutable memory; the current input source or
--- the last connected keyboard cannot identify another keyboard's event.
--- ==============================================================================

local M = {}
local Json = require("adapters.json_codec")
local Logger = require("infra.logger")
local LOG = "adapters.keyboard_geometry"
local ENVIRONMENT_KEY = "ERGOPTI_KEYBOARD_GEOMETRY_V1"
local MAXIMUM = 32767 -- KBGetLayoutType takes a nonnegative signed Int16 model.
local FORMS = { ansi = true, iso = true, jis = true, unknown = true }
local _initialized, _ranges = false, nil
local property = hs.eventtap.event.properties.keyboardEventKeyboardType

local function integer(value)
	return type(value) == "number" and value >= 0 and value <= MAXIMUM and value % 1 == 0
end

local function fields(value, allowed)
	for key in pairs(value) do if not allowed[key] then return false end end
	return true
end

local function validated(value)
	if type(value) ~= "table" or value.version ~= 1 or value.maximum ~= MAXIMUM
		or not fields(value, { version = true, maximum = true, ranges = true })
		or type(value.ranges) ~= "table" or #value.ranges == 0 or #value.ranges > MAXIMUM + 1 then return nil end
	for index in pairs(value.ranges) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #value.ranges then return nil end
	end
	-- A native decoder can represent JSON null as a hole. ipairs alone would
	-- silently stop there and could admit a complete prefix while ignoring tail rows.
	for index = 1, #value.ranges do
		if type(value.ranges[index]) ~= "table" then return nil end
	end
	local ranges, next_id = {}, 0
	for _, row in ipairs(value.ranges) do
		if type(row) ~= "table" or not integer(row.first) or not integer(row.last)
			or not fields(row, { first = true, last = true, form = true })
			or row.first ~= next_id or row.last < row.first or FORMS[row.form] ~= true
			or (#ranges > 0 and ranges[#ranges].form == row.form) then return nil end
		ranges[#ranges + 1] = { first = row.first, last = row.last, form = row.form }
		next_id = row.last + 1
	end
	if next_id ~= MAXIMUM + 1 then return nil end
	return ranges
end

--- Reads and validates the native map once, before any input owner starts.
--- @return boolean available
function M.initialize()
	assert(not _initialized, "keyboard geometry is already initialized")
	_initialized = true
	Logger.info(LOG, "Loading native keyboard geometry.")
	local text = os.getenv(ENVIRONMENT_KEY)
	local decoded, detail = Json.decode(text)
	_ranges = detail == nil and validated(decoded) or nil
	if _ranges == nil then
		Logger.warn(LOG, "Native keyboard geometry unavailable; ambiguous physical keys remain native.")
		return false
	end
	Logger.info(LOG, "Native keyboard geometry loaded: %d ranges.", #_ranges)
	return true
end

--- Returns the actual event's model identifier, never the global keyboard type.
--- @param event table|userdata Quartz event.
--- @return integer|nil keyboard_type
function M.event_type(event)
	if property == nil or event == nil then return nil end
	local called, value = pcall(function() return event:getProperty(property) end)
	if called and integer(value) then return value end
	return nil
end

--- Resolves a model identifier against the native map loaded at boot.
--- @param keyboard_type integer|nil Quartz keyboard model.
--- @return string|nil form
function M.form(keyboard_type)
	if _ranges == nil or not integer(keyboard_type) then return nil end
	local first, last = 1, #_ranges
	while first <= last do
		local middle = math.floor((first + last) / 2)
		local row = _ranges[middle]
		if keyboard_type < row.first then last = middle - 1
		elseif keyboard_type > row.last then first = middle + 1
		else return row.form end
	end
	return nil
end

--- Selects one physical key's virtual code for this event's keyboard geometry.
--- @param primary integer ANSI virtual code from the shared registry.
--- @param iso integer ISO virtual code from the same registry.
--- @param keyboard_type integer|nil Event model identifier.
--- @return integer|nil code
function M.native_code(primary, iso, keyboard_type)
	if primary == iso then return primary end
	local form = M.form(keyboard_type)
	if form == "ansi" then return primary end
	if form == "iso" then return iso end
	-- The registry does not establish the swapped pair on JIS/unknown models.
	return nil
end

--- Projects a shared physical-key record onto the actual keyboard model.
--- @param entry table Physical-key registry record.
--- @param keyboard_type integer|nil Event model identifier.
--- @return integer|nil code
function M.physical_code(entry, keyboard_type)
	local iso = type(entry.macos_iso) == "table" and entry.macos_iso.hs or entry.hs
	return M.native_code(entry.hs, iso, keyboard_type)
end

return M
