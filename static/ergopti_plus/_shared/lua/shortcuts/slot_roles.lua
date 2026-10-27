--- _shared/lua/shortcuts/slot_roles.lua

--- ==============================================================================
--- MODULE: Neutral Keyboard Slot Roles
--- DESCRIPTION:
--- Resolves the neutral slot ids of the one-shortcut model (PAR-41) to the
--- modifier names of one driver and back. A slot id is modifier ROLES in a fixed
--- order, then one key: primary_g, primary_shift_v, meta_space. The role table
--- is generated from _shared/modules/actions/slot_roles.json.
---
--- FEATURES & RATIONALE:
--- 1. Pure: no I/O, no driver state, so every driver replays the same contract.
--- 2. Closed vocabulary: an unknown role, a repeated or misordered role, a
---    missing key or an unknown driver is refused with a reason, never guessed.
--- 3. Absence is explicit: a role a keyboard lacks returns the table's reason,
---    so a menu can say why the slot is not offered there.
--- ==============================================================================

local Data = require("shortcuts.slot_roles_data")

local M = {}

local RANK = {}
for rank, role in ipairs(Data.modifier_order) do RANK[role] = rank end

--- Inverse of Data.roles for one driver: native modifier id -> role.
local function inverse(driver)
	local result = {}
	for _, role in ipairs(Data.modifier_order) do
		local native = Data.roles[role][driver]
		if native ~= nil then result[native] = role end
	end
	return result
end

--- Fails fast on a driver the table does not describe.
local function require_driver(driver)
	local known = false
	for _, role in pairs(Data.roles) do
		if role[driver] ~= nil then known = true end
	end
	assert(known, "slot roles: unknown driver " .. tostring(driver))
end

--- The roles in canonical order, as a detached array.
--- @return table roles
function M.roles()
	local result = {}
	for index, role in ipairs(Data.modifier_order) do result[index] = role end
	return result
end

--- Parses a neutral slot id.
--- @param slot any Candidate slot id.
--- @return table|nil parsed { roles = {…}, key = string }.
--- @return string|nil reason Why the id is not a neutral slot.
function M.parse(slot)
	if type(slot) ~= "string" or slot == "" then return nil, "not a string" end
	local tokens = {}
	for token in slot:gmatch("[^_]+") do tokens[#tokens + 1] = token end
	if slot:find("__", 1, true) or slot:sub(1, 1) == "_" or slot:sub(-1) == "_" then
		return nil, "empty token"
	end
	local roles, last = {}, 0
	for index = 1, #tokens - 1 do
		local rank = RANK[tokens[index]]
		if rank == nil then return nil, "unknown role " .. tokens[index] end
		if rank <= last then return nil, "role out of order or repeated: " .. tokens[index] end
		last = rank
		roles[#roles + 1] = tokens[index]
	end
	local key = tokens[#tokens]
	if key == nil then return nil, "no key" end
	if RANK[key] ~= nil then return nil, "no key after the roles" end
	if #roles == 0 then return nil, "no modifier: a bare key is never a shortcut slot" end
	return { roles = roles, key = key }
end

--- Builds a neutral slot id.
--- @param roles table Roles in canonical order.
--- @param key string Key id.
--- @return string|nil slot
--- @return string|nil reason
function M.id(roles, key)
	if type(key) ~= "string" or key == "" or key:find("_", 1, true) then return nil, "invalid key" end
	local parts = {}
	for _, role in ipairs(roles) do parts[#parts + 1] = role end
	parts[#parts + 1] = key
	local id = table.concat(parts, "_")
	local parsed, reason = M.parse(id)
	if parsed == nil then return nil, reason end
	return id
end

--- Resolves a neutral slot to one driver's modifier names.
--- @param driver string "windows", "macos" or "linux".
--- @param slot string Neutral slot id.
--- @return table|nil native { modifiers = {native ids in role order}, key = string }.
--- @return string|nil reason Invalid slot, or why this keyboard cannot honour a role.
function M.native(driver, slot)
	require_driver(driver)
	local parsed, reason = M.parse(slot)
	if parsed == nil then return nil, reason end
	local modifiers = {}
	for _, role in ipairs(parsed.roles) do
		local native = Data.roles[role][driver]
		if native == nil then return nil, Data.absent_reason[role] end
		modifiers[#modifiers + 1] = native
	end
	return { modifiers = modifiers, key = parsed.key }
end

--- Names the neutral slot a driver's native chord corresponds to.
--- @param driver string "windows", "macos" or "linux".
--- @param modifiers table Native modifier ids, any order.
--- @param key string Key id.
--- @return string|nil slot
--- @return string|nil reason
function M.from_native(driver, modifiers, key)
	require_driver(driver)
	local to_role, seen, roles = inverse(driver), {}, {}
	for _, native in ipairs(modifiers) do
		local role = to_role[native]
		if role == nil then return nil, "unknown modifier " .. tostring(native) end
		if seen[role] then return nil, "repeated modifier " .. tostring(native) end
		seen[role] = true
		roles[#roles + 1] = role
	end
	table.sort(roles, function(a, b) return RANK[a] < RANK[b] end)
	return M.id(roles, key)
end

return M
