--- _shared/lua/storage_owned.lua

--- ==============================================================================
--- MODULE: Storage Owned-Alias Protocol
--- DESCRIPTION:
--- The part of the Storage port's owned-alias protocol that does not depend on
--- the backend: alias gates, receipt authority, detached update cells and the
--- finalization of a primary journal. The macOS adapter (hs.settings) and the
--- Linux adapter (a JSON file) keep only capture, publish and restore, which
--- read and write their own native store.
---
--- FEATURES & RATIONALE:
--- 1. One copy: both adapters carried the same 220 lines (104 identical 8-line
---    windows); a refusal added to one gate was missing from the other.
--- 2. Detached values: copy() admits only finite settings/JSON values, so a
---    caller cannot keep a reference into a captured snapshot.
--- 3. Backend hooks, not branches: admit(), quiet() and live() let the Linux
---    adapter refuse while its ordinary commit is in flight or its JSON codec
---    was replaced; macOS passes none and every hook admits.
--- 4. Explicit ownership: new() is called once by the adapter that owns the
---    receipts; the tables it returns are that adapter's, never shared state.
--- ==============================================================================

local M = {}
local json = require("json")

-- The adapter capabilities a receipt pins; a reentrant callback that replaces
-- one of them invalidates every receipt captured before.
local PINNED_METHODS = { "acquire_owned", "release_owned", "capture_owned", "publish_owned",
	"restore_owned", "pending_owned", "forget_owned", "set", "delete", "clear" }
local OPTIONAL_PINNED_METHODS = { "set_many", "delete_exact" }

local OPTIONS = { name = true, module = true, logical_key = true, logger = true, log = true,
	admit = true, quiet = true, live = true }





-- =======================================
-- =======================================
-- ======= 1/ Detached value cells =======
-- =======================================
-- =======================================

--- Copies only finite native settings/JSON values without caller ownership.
--- @param value any
--- @param seen table|nil
--- @return any copy
function M.copy(value, seen)
	if json.is_null(value) then return value end
	local kind = type(value)
	if kind == "number" then
		assert(value == value and value ~= math.huge and value ~= -math.huge, "non-finite value")
		local encoded = assert(json.encode(value))
		local decoded = json.decode_lossless(encoded)
		assert(type(decoded) == "number" and decoded == value
			and (value ~= 0 or 1 / decoded == 1 / value), "numeric backup cannot round-trip")
		return value
	end
	if kind == "string" or kind == "boolean" or kind == "nil" then return value end
	assert(kind == "table" and getmetatable(value) == nil, "unsupported storage value")
	seen = seen or {}
	assert(not seen[value], "cyclic storage value")
	seen[value] = true
	local copy, numeric, textual, count = {}, false, false, 0
	for key, child in pairs(value) do
		assert(type(key) == "string" or (type(key) == "number" and key >= 1 and key % 1 == 0), "invalid value key")
		numeric, textual = numeric or type(key) == "number", textual or type(key) == "string"
		count = count + 1
		copy[key] = M.copy(child, seen)
	end
	assert(not (numeric and textual), "mixed storage table")
	if numeric then for index = 1, count do assert(rawget(copy, index) ~= nil, "sparse storage array") end end
	seen[value] = nil
	if json.is_array(value) then copy = json.array(copy) end
	return copy
end

--- Compares captured native identities, including JSON arrays and null.
--- @param left any
--- @param right any
--- @return boolean equal
function M.equal(left, right)
	if json.is_null(left) or json.is_null(right) then return left == right end
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	if json.is_array(left) ~= json.is_array(right) then return false end
	for key, value in pairs(left) do if not M.equal(value, right[key]) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end

--- Tests a cell without conflating false, zero, absence or native value kinds.
--- @param left table
--- @param right table
--- @return boolean equal
function M.cell_equal(left, right)
	return left.present == right.present and (not left.present or M.equal(left.value, right.value))
end





-- ==============================
-- ==============================
-- ======= 2/ Alias gates =======
-- ==============================
-- ==============================

--- Returns the hook, or one that always admits when the adapter has none.
--- @param hook any
--- @param label string
--- @return function hook
local function hook_or_true(hook, label)
	if hook == nil then return function() return true end end
	assert(type(hook) == "function", "storage owned: " .. label .. " must be a function")
	return hook
end

--- Creates one adapter's owned-alias state.
--- @param options table name (package.loaded key), module (the adapter table),
---   logical_key(key) -> boolean, logger (with .error) and log (its module tag);
---   optional admit() (may settle backend debt first), quiet() (no backend
---   commit in flight) and live() (backend capabilities still the loaded ones).
--- @return table owned Gate tables and protocol functions for that adapter.
function M.new(options)
	assert(type(options) == "table" and getmetatable(options) == nil, "storage owned: options must be a plain table")
	for key in pairs(options) do assert(OPTIONS[key], "storage owned: unknown option " .. tostring(key)) end
	local name, module, logical_key = options.name, options.module, options.logical_key
	local logger, log = options.logger, options.log
	assert(type(name) == "string" and name ~= "", "storage owned: name must be the adapter's package.loaded key")
	assert(type(module) == "table", "storage owned: module must be the adapter table")
	assert(type(logical_key) == "function", "storage owned: logical_key must be a function")
	assert(type(logger) == "table" and type(logger.error) == "function", "storage owned: logger needs error()")
	assert(type(log) == "string" and log ~= "", "storage owned: log must name the adapter")
	local admit = hook_or_true(options.admit, "admit")
	local quiet = hook_or_true(options.quiet, "quiet")
	local live = hook_or_true(options.live, "live")

	local owned = {}
	-- Private receipts deliberately do not retain their weak-map token key. A
	-- journal keeps a committed token alive; unsettled effects remain gate-owned.
	local gates, aliases, generations = {}, {}, {}
	local receipts = setmetatable({}, { __mode = "k" })
	local epoch = 0
	local finalizing = {}
	owned.gates, owned.aliases, owned.generations, owned.receipts = gates, aliases, generations, receipts

	--- Admits a caller's dense, unique logical alias set before acquiring any gate.
	--- @param list table
	--- @return table|nil aliases_copy
	function owned.alias_list(list)
		if type(list) ~= "table" or getmetatable(list) ~= nil then return nil end
		local count, seen, copy = 0, {}, {}
		for index in pairs(list) do
			if type(index) ~= "number" or index < 1 or index % 1 ~= 0 then return nil end
			count = count + 1
		end
		if count == 0 then return nil end
		for index = 1, count do
			local alias = rawget(list, index)
			if type(alias) ~= "string" or alias == "" or alias:find("\0", 1, true) or seen[alias] or not logical_key(alias) then return nil end
			seen[alias], copy[index] = true, alias
		end
		table.sort(copy)
		return copy
	end

	--- Acquires just the supplied aliases for one private aggregate owner.
	--- @param owner table Opaque primary transaction owner.
	--- @param list table Dense logical keys.
	--- @return boolean acquired
	function owned.acquire(owner, list)
		if not admit() then return false end
		if type(owner) ~= "table" or gates[owner] ~= nil or finalizing[owner] or not quiet() then return false end
		local keys = owned.alias_list(list)
		if not keys then return false end
		for _, key in ipairs(keys) do if aliases[key] ~= nil then return false end end
		epoch = epoch + 1
		local gate = { keys = keys, epoch = epoch, sequence = 0, busy = false }
		gates[owner] = gate
		for _, key in ipairs(keys) do aliases[key] = owner end
		return true
	end

	--- Releases gates only after primary compensation and native effects settle.
	--- Committed receipt inverses stay privately valid for a later reacquisition.
	--- @param owner table
	--- @return boolean released
	function owned.release(owner)
		local gate = gates[owner]
		if not gate or gate.busy or gate.debt ~= nil then return false end
		gate.busy = true
		local pending = rawget(owner, "pending")
		local okay = true
		if pending ~= nil then
			local called, result = false, nil
			if type(pending) == "function" then called, result = pcall(pending) end
			okay = called and result == false and rawequal(rawget(owner, "pending"), pending)
		end
		gate.busy = false
		if not okay then return false end
		for _, key in ipairs(gate.keys) do aliases[key] = nil end
		gates[owner] = nil
		return true
	end

	--- Reports only unsettled native effect/cleanup debt, never a held alias gate.
	--- @param owner table
	--- @param receipt table Opaque native token.
	--- @return boolean pending
	function owned.pending(owner, receipt)
		local record = receipts[receipt]
		return record ~= nil and rawequal(record.owner, owner) and record.pending == true
	end

	--- Verifies receipt ownership and the same acquired alias set across reentry.
	--- @param owner table
	--- @param receipt table
	--- @param publishing boolean
	--- @return table|nil gate
	--- @return table|nil record
	function owned.authority(owner, receipt, publishing)
		if not admit() then return nil end
		local gate, record = gates[owner], receipts[receipt]
		if not rawequal(package.loaded[name], module) or not live() then return nil end
		if not gate or gate.busy or not record or not rawequal(record.owner, owner) or not M.equal(gate.keys, record.keys) then return nil end
		if gate.debt ~= nil and not rawequal(gate.debt, record) then return nil end
		if publishing and (record.used or record.epoch ~= gate.epoch or record.sequence ~= gate.sequence) then return nil end
		return gate, record
	end

	--- Detaches validated update cells and rejects keys outside the acquired set.
	--- @param owner table
	--- @param updates table
	--- @return table|nil detached
	function owned.updates(owner, updates)
		if type(updates) ~= "table" or getmetatable(updates) ~= nil then return nil end
		local called, copy = pcall(function()
			local result = {}
			for key, cell in pairs(updates) do
				assert(type(key) == "string" and rawequal(aliases[key], owner), "unowned alias")
				assert(type(cell) == "table" and getmetatable(cell) == nil and type(cell.present) == "boolean", "invalid cell")
				for field in pairs(cell) do assert(field == "present" or field == "value", "invalid cell field") end
				assert((cell.present and cell.value ~= nil) or (not cell.present and cell.value == nil), "invalid presence")
				result[key] = { present = cell.present, value = M.copy(cell.value) }
			end
			return result
		end)
		return called and copy or nil
	end

	--- Pins live adapter methods so reentrant callbacks cannot replace the owner.
	--- @param record table
	--- @return boolean current
	function owned.live(record)
		if not rawequal(package.loaded[name], module) or not live() then return false end
		for method, callback in pairs(record.methods) do if not rawequal(module[method], callback) then return false end end
		if record.file_owner then
			for method, callback in pairs(record.file_methods) do if not rawequal(record.file_owner[method], callback) then return false end end
		end
		return true
	end

	--- Captures the adapter capability identities, never a caller-supplied image.
	--- @return table methods
	function owned.methods()
		local methods = {}
		for _, method in ipairs(PINNED_METHODS) do methods[method] = module[method] end
		for _, method in ipairs(OPTIONAL_PINNED_METHODS) do
			if module[method] then methods[method] = module[method] end
		end
		return methods
	end

	--- Finalizes a primary journal without deleting backup files or changing values.
	--- A weak owner tombstone retains exact idempotence while breaking LuaJIT cycles.
	--- @param owner table
	--- @param receipt table
	--- @return boolean forgotten
	function owned.forget(owner, receipt)
		if type(owner) ~= "table" then return false end
		local record = receipts[receipt]
		if not record then return false end
		if record.forgotten then return rawequal(record.owner_box[1], owner) end
		local gate = gates[owner]
		if not rawequal(record.owner, owner) or record.pending or gate ~= nil
			or finalizing[owner] then return false end
		finalizing[owner] = true
		local pending = rawget(owner, "pending")
		local okay = pending == nil
		if type(pending) == "function" then
			local called, result = pcall(pending)
			okay = called and result == false and rawequal(rawget(owner, "pending"), pending)
		end
		finalizing[owner] = nil
		if not okay or record.pending or not rawequal(receipts[receipt], record) then return false end
		-- A JIT-retained publication closure can still root this retired journal.
		-- Detach its owner only after every finalization refusal has been checked.
		local forgotten = { forgotten = true, owner_box = setmetatable({ owner }, { __mode = "v" }) }
		record.owner = nil
		receipts[receipt] = forgotten
		return true
	end

	--- Keeps native callback reentry from changing receipt state mid-operation.
	--- @param gate table
	--- @param callback function
	--- @return any result
	--- @return any cells
	function owned.guard(gate, callback)
		gate.busy = true
		local okay, result, cells = pcall(callback)
		gate.busy = false
		if not okay then logger.error(log, "Owned storage operation refused — %s.", tostring(result)); return false end
		return result, cells
	end

	return owned
end

return M
