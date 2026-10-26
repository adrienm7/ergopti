--- _shared/lua/tap_hold/migrate.lua

--- ==============================================================================
--- MODULE: Tap-Hold File Migration (shared)
--- DESCRIPTION:
--- Versions a user's tap_hold.toml. It reads ``[_meta] schema_version``, runs the
--- steps of _shared/tap_hold/migrations.toml from the file's version to the
--- current one on the decoded document, and stamps the result. It performs no
--- I/O on the user file: the driver reads it, backs it up and publishes it.
---
--- FEATURES & RATIONALE:
--- 1. Replaces the permanent ``[tap_hold] explicit_delays = true`` marker. The
---    cleanup of the per-key delays earlier builds shipped used to be decided
---    again on every read and write by looking for that marker; it is now one
---    step, run once, and the version says it ran.
--- 2. Data-only steps over a closed op set (drop_retired_values, delete). The
---    shared config.toml registry cannot express the first one, and Windows
---    validates that registry at every boot, so this file has its own registry.
--- 3. Fail fast. A registry defect raises. A stamp that is not a non-negative
---    integer, or a file newer than this build, is reported as such and left
---    for the caller to refuse, never rewritten.
--- 4. Pure and idempotent: replaying a step on its own output changes nothing,
---    so a crash between two writers never leaves a half-migrated file.
--- ==============================================================================

local M = {}

local TableUtil = require("table_util")

--- The section and key that hold the version, the spelling config.toml uses.
M.META_SECTION = "_meta"
M.VERSION_KEY = "schema_version"

local OPS = { drop_retired_values = true, delete = true }




-- ===============================
-- ===============================
-- ======= 1/ Registry ===========
-- ===============================
-- ===============================

--- Whether a value is a non-negative integer.
--- @param value any
--- @return boolean
local function is_version(value)
	return type(value) == "number" and value >= 0 and value == math.floor(value)
end

--- Whether a value is a non-empty dotted path of bare segments.
--- @param value any
--- @return boolean
local function is_path(value)
	return type(value) == "string" and value:match("^[%w_%-]+[%w_%-%.]*$") ~= nil and not value:find("..", 1, true)
		and value:sub(-1) ~= "."
end

--- Raises unless an op is well formed.
--- @param op any
--- @param where string For the message.
local function validate_op(op, where)
	if type(op) ~= "table" or not OPS[op.op] then error(where .. " names no known op", 0) end
	if not is_path(op.section) or not is_path(op.key) then
		error(where .. " needs a section path and a key", 0)
	end
	if op.op == "delete" then return end
	if not is_path(op.retired) then error(where .. " needs the name of its retired table", 0) end
	local unless = op.unless
	if unless ~= nil and (type(unless) ~= "table" or not is_path(unless.section) or not is_path(unless.key)
		or unless.value == nil) then
		error(where .. " has an invalid unless condition", 0)
	end
end

--- Validates a decoded registry and returns its detached, ordered form.
--- @param decoded table Decoded migrations.toml.
--- @return table registry `{ current, unstamped, steps = { { from, to, ops } } }`.
function M.parse_registry(decoded)
	local meta = type(decoded) == "table" and decoded.registry
	if type(meta) ~= "table" or not is_version(meta.current_version) or not is_version(meta.unstamped_version)
		or meta.current_version <= meta.unstamped_version then
		error("tap-hold migration registry: [registry] needs current_version above unstamped_version", 0)
	end
	local steps = {}
	for name, step in pairs(type(decoded.steps) == "table" and decoded.steps or {}) do
		local where = "tap-hold migration registry: [steps." .. tostring(name) .. "]"
		if type(step) ~= "table" or not is_version(step.from) or step.to ~= step.from + 1
			or name ~= "v" .. step.from .. "_to_v" .. step.to then
			error(where .. " must be named v<from>_to_v<to> with to = from + 1", 0)
		end
		if type(step.ops) ~= "table" then error(where .. " needs an ops array", 0) end
		for index, op in ipairs(step.ops) do validate_op(op, where .. " op " .. index) end
		steps[#steps + 1] = { from = step.from, to = step.to, ops = TableUtil.deep_copy(step.ops) }
	end
	table.sort(steps, function(left, right) return left.from < right.from end)
	local expected = meta.unstamped_version
	for _, step in ipairs(steps) do
		if step.from ~= expected then
			error("tap-hold migration registry: no step leaves version " .. expected, 0)
		end
		expected = step.to
	end
	if expected ~= meta.current_version then
		error("tap-hold migration registry: the steps stop at version " .. expected, 0)
	end
	return { current = meta.current_version, unstamped = meta.unstamped_version, steps = steps }
end

--- Reads and validates the registry file.
--- @param path string Absolute path of _shared/tap_hold/migrations.toml.
--- @return table registry See M.parse_registry.
function M.load_registry(path)
	local fh, open_err = io.open(path, "r")
	if not fh then error("cannot read the tap-hold migration registry: " .. tostring(open_err), 0) end
	local text = fh:read("*a")
	fh:close()
	local ok, decoded = pcall(require("toml_codec").decode, text)
	if not ok or type(decoded) ~= "table" then
		error("the tap-hold migration registry does not parse: " .. tostring(path), 0)
	end
	return M.parse_registry(decoded)
end




-- ===============================
-- ===============================
-- ======= 2/ Document ===========
-- ===============================
-- ===============================

--- The table at a dotted path, nil when any segment is absent or not a table.
--- @param document table
--- @param path string
--- @param is_table function(value) -> boolean
--- @return table|nil
local function table_at(document, path, is_table)
	local node = document
	for segment in path:gmatch("[^%.]+") do
		node = node[segment]
		if not is_table(node) then return nil end
	end
	return node
end

--- Removes a table from its parent when it is empty, walking up.
--- @param document table
--- @param path string Dotted path of the table that lost a key.
--- @param is_table function(value) -> boolean
local function prune(document, path, is_table)
	local segments = {}
	for segment in path:gmatch("[^%.]+") do segments[#segments + 1] = segment end
	for depth = #segments, 1, -1 do
		local parent = document
		for index = 1, depth - 1 do parent = parent[segments[index]] end
		local node = parent[segments[depth]]
		if is_table(node) and next(node) == nil then parent[segments[depth]] = nil else return end
	end
end

--- The version a document carries.
--- @param document table Decoded user document.
--- @param registry table
--- @param is_table function(value) -> boolean Whether a value is a TOML table.
--- @return number|nil version The stamp, or the registry's unstamped version;
---   nil when the stamp is unusable.
--- @return string|nil detail Why the stamp is unusable.
function M.version(document, registry, is_table)
	local meta = document[M.META_SECTION]
	if meta == nil then return registry.unstamped end
	if not is_table(meta) then return nil, "[" .. M.META_SECTION .. "] is not a table" end
	local version = meta[M.VERSION_KEY]
	if version == nil then return registry.unstamped end
	if not is_version(version) then
		return nil, "[" .. M.META_SECTION .. "] " .. M.VERSION_KEY .. " is not a non-negative integer"
	end
	return version
end

--- Applies one op to a document.
--- @param document table
--- @param op table
--- @param retired table Driver key id -> the delay an earlier build shipped.
--- @param is_table function(value) -> boolean
local function apply_op(document, op, retired, is_table)
	if op.op == "delete" then
		local section = table_at(document, op.section, is_table)
		if section then
			section[op.key] = nil
			prune(document, op.section, is_table)
		end
		return
	end
	local unless = op.unless
	if unless then
		local guard = table_at(document, unless.section, is_table)
		if guard and guard[unless.key] == unless.value then return end
	end
	local section = table_at(document, op.section, is_table)
	if not section then return end
	for key_id, seconds in pairs(retired) do
		local entry = section[key_id]
		if is_table(entry) and entry[op.key] == seconds then
			entry[op.key] = nil
			if next(entry) == nil then section[key_id] = nil end
		end
	end
	prune(document, op.section, is_table)
end

--- Migrates a decoded user document in place, then stamps it.
--- @param document table Decoded user document, edited in place.
--- @param registry table See M.parse_registry.
--- @param retired table Driver key id -> the delay an earlier build shipped
---   (key_catalog.retired_delays_for_platform).
--- @param is_table function(value) -> boolean Whether a value is a TOML table
---   rather than an array (tap_hold_shapes.is_table with the document's receipt).
--- @return string outcome "migrated", "current", "newer" or "invalid" (an
---   unusable stamp: the document is not edited).
--- @return number|string from The version the document carried, or why its
---   stamp is unusable.
function M.apply(document, registry, retired, is_table)
	local from, detail = M.version(document, registry, is_table)
	if from == nil then return "invalid", detail end
	if from > registry.current then return "newer", from end
	if from == registry.current then return "current", from end
	for _, step in ipairs(registry.steps) do
		if step.from >= from then
			for _, op in ipairs(step.ops) do apply_op(document, op, retired, is_table) end
		end
	end
	if document[M.META_SECTION] == nil then document[M.META_SECTION] = {} end
	document[M.META_SECTION][M.VERSION_KEY] = registry.current
	return "migrated", from
end

return M
