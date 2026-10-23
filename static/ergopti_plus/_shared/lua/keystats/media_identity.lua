--- _shared/lua/keystats/media_identity.lua

--- Closed semantic identities and in-memory aggregates for physical media keys.
--- The caller supplies the reviewed catalogue and owns native admission, privacy,
--- source lifecycle and durable publication. These mappings grant no input authority.
local M = {}
local Release = require("keystats.physical_release")
local MAX_COUNTER = 2 ^ 53 - 1 -- Exact integers on both stock Lua and double-only Lua runtimes.

local function integer(value, maximum)
	return type(value) == "number" and value >= 0 and value <= maximum and value % 1 == 0
end

local function fields(value, allowed)
	assert(type(value) == "table", "Media identity requires an object")
	for key in pairs(value) do assert(allowed[key] == true, "Undeclared media identity field") end
end

local function dense(values)
	assert(type(values) == "table" and #values > 0, "Media catalogue requires a nonempty array")
	for key in pairs(values) do
		assert(integer(key, #values) and key >= 1, "Media catalogue requires a dense array")
	end
	for index = 1, #values do assert(type(values[index]) == "table", "Media catalogue row is missing") end
end

local function device(value)
	return type(value) == "string" and value:match("^[1-9]%d*$") ~= nil
		and (#value < 20 or (#value == 20 and value <= "18446744073709551615"))
end

--- Creates an immutable lookup policy from an already source-admitted catalogue.
--- Shape validation does not replace the caller's catalogue/source authority.
---@param catalogue table Reviewed shared metrics_media_keys.json document.
---@return table policy Pure lookup and aggregation interface.
function M.new(catalogue)
	fields(catalogue, { _description = true, schema_version = true, keys = true })
	assert(catalogue.schema_version == 1, "Unsupported media identity catalogue version")
	assert(catalogue._description == nil or type(catalogue._description) == "string", "Invalid media catalogue description")
	dense(catalogue.keys)
	local identities, hid, system, evdev = {}, {}, {}, {}
	for _, row in ipairs(catalogue.keys) do
		fields(row, { id = true, label_key = true, hid = true, macos_system = true, linux_evdev = true })
		assert(type(row.id) == "string" and row.id:match("^media%.[a-z][a-z_]+$"), "Invalid semantic media identity")
		assert(type(row.label_key) == "string" and row.label_key:match("^sg_actions%.[a-z][a-z_]+$"), "Invalid media identity label")
		fields(row.hid, { page = true, usage = true })
		assert(row.hid.page == 12 and integer(row.hid.usage, 65535) and row.hid.usage >= 1, "Invalid consumer media usage")
		assert(type(row.macos_system) == "string" and row.macos_system:match("^[A-Z][A-Z_]+$"), "Invalid native media name")
		assert(integer(row.linux_evdev, 767) and row.linux_evdev >= 1, "Invalid evdev media code")
		assert(identities[row.id] == nil and hid[row.hid.usage] == nil
			and system[row.macos_system] == nil and evdev[row.linux_evdev] == nil, "Duplicate media identity or native mapping")
		identities[row.id] = row.label_key
		hid[row.hid.usage], system[row.macos_system], evdev[row.linux_evdev] = row.id, row.id, row.id
	end
	local policy = {}

	--- Whether an identifier belongs to this exact admitted catalogue.
	---@param id any Candidate semantic identity.
	---@return boolean known
	function policy.is_known(id) return type(id) == "string" and identities[id] ~= nil end

	--- Resolves a raw consumer usage without fabricating a virtual keycode.
	---@param page integer Raw HID usage page.
	---@param usage integer Raw HID usage.
	---@return string|nil id
	function policy.resolve_hid(page, usage)
		if page ~= 12 or not integer(usage, 65535) then return nil end
		return hid[usage]
	end

	--- Describes an NX key name; it observes and emits no system-defined event.
	---@param name string Existing Hammerspoon systemKey() label.
	---@return string|nil id
	function policy.resolve_system_name(name) return type(name) == "string" and system[name] or nil end

	--- Resolves an evdev identity for an already admitted native observation.
	---@param code integer Native evdev code.
	---@return string|nil id
	function policy.resolve_evdev(code)
		if not integer(code, 767) then return nil end
		return evdev[code]
	end

	--- Returns only the existing locale key, never a caller-owned record.
	---@param id string Semantic identity.
	---@return string|nil label_key
	function policy.label_key(id) return identities[id] end

	--- Checks structural event identity without claiming native authenticity.
	---@param entry table Already admitted capture event.
	---@return string date Captured application date.
	local function event_identity(entry)
		assert(type(entry) == "table" and policy.is_known(entry.media_id), "Unknown semantic media identity")
		assert(entry.keycode == nil, "Media identity cannot fabricate a virtual keycode")
		assert(type(entry.capture) == "string" and entry.capture ~= "", "Media event requires capture ownership")
		assert(device(entry.device), "Media event requires an exact device identifier")
		assert(type(entry.app) == "string" and entry.app ~= "", "Media event requires its captured application")
		assert(type(entry.timestamp) == "string" and entry.timestamp:match("^%d%d%d%d%-%d%d%-%d%d "),
			"Media event requires its captured timestamp")
		return entry.timestamp:sub(1, 10)
	end

	--- Adds one admitted press to a caller-owned media-only aggregate bucket.
	--- This is an in-memory credit, not an acknowledgement of durable storage.
	---@param bucket table Caller-owned media press rows.
	---@param entry table Accepted capture event carrying media_id, not keycode.
	---@return table row Aggregate projection for the writer/reader interface.
	function policy.aggregate_press(bucket, entry)
		assert(type(bucket) == "table", "Media press aggregate requires a bucket")
		local date = event_identity(entry)
		local key = date .. "\1" .. entry.app .. "\1" .. entry.media_id
		local row = bucket[key]
		if row ~= nil then
			assert(type(row) == "table" and row.date == date and row.app == entry.app and row.media_id == entry.media_id
				and integer(row.count, MAX_COUNTER - 1), "Invalid media press aggregate")
		else row = { date = date, app = entry.app, media_id = entry.media_id, count = 0 } end
		row.count = row.count + 1
		bucket[key] = row
		return row
	end

	--- Adds a matched release without crediting another press or any typed text.
	---@param bucket table Caller-owned media hold rows.
	---@param entry table Matched release with original press identity and hold_ms.
	---@param threshold_ms integer Shared inclusive tap boundary.
	---@return table row Aggregate projection for the writer/reader interface.
	function policy.aggregate_hold(bucket, entry, threshold_ms)
		assert(type(bucket) == "table", "Media hold aggregate requires a bucket")
		local date = event_identity(entry)
		local duration = Release.duration(entry.hold_ms)
		assert(integer(threshold_ms, Release.MAX_HOLD_MS), "Invalid media tap threshold")
		local key = date .. "\1" .. entry.app .. "\1" .. entry.media_id
		local row = bucket[key]
		if row ~= nil then
			assert(type(row) == "table" and row.date == date and row.app == entry.app and row.media_id == entry.media_id,
				"Invalid media hold identity")
			for _, name in ipairs({ "count", "tap_count", "hold_count" }) do
				assert(integer(row[name], MAX_COUNTER - 1), "Invalid media hold counter")
			end
			assert(integer(row.sum_ms, MAX_COUNTER - duration) and integer(row.max_ms, Release.MAX_HOLD_MS),
				"Invalid media hold duration aggregate")
			assert(row.tap_count + row.hold_count == row.count and row.sum_ms >= row.max_ms,
				"Inconsistent media hold aggregate")
		else row = { date = date, app = entry.app, media_id = entry.media_id,
			sum_ms = 0, count = 0, max_ms = 0, tap_count = 0, hold_count = 0 } end
		Release.accumulate(row, duration, threshold_ms)
		bucket[key] = row
		return row
	end

	return policy
end

return M
