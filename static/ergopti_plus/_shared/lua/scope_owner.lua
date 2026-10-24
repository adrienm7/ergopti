--- _shared/lua/scope_owner.lua

--- ==============================================================================
--- MODULE: Scope Owner (native scalar field protocol)
--- DESCRIPTION:
--- One copy of the protocol a driver module follows when it lends one runtime
--- field (the locale, the log level, the error-window switch) to the shared
--- configuration scope transaction: scope_acquire, scope_release,
--- scope_capture, scope_apply, scope_restore and scope_forget, each capture
--- answered by an opaque receipt.
---
--- FEATURES & RATIONALE:
--- 1. One protocol: the six methods were retyped in six driver modules on
---    macOS and Linux; a fix to one copy (a reentry gate, a generation check)
---    silently missed the other five.
--- 2. Declared fields: the owning module names what its snapshot holds and
---    which of those fields apply() publishes. Equality and the restore
---    admission are derived from that declaration instead of being hand-typed
---    beside it, where a new field was compared in one place and not the other.
--- 3. Explicit ownership: new() creates the admission state at the top of the
---    owning module, so its ordinary mutators can refuse while a transaction
---    holds the field; install() publishes the methods once and refuses a
---    second call.
--- 4. Opaque failure: every refusal, including a throwing owner callback,
---    answers false or nil, as the transaction's compensation journal expects.
--- ==============================================================================

local M = {}

-- The methods install() publishes on the owning module, in protocol order.
local METHOD_NAMES = { "scope_acquire", "scope_release", "scope_capture", "scope_apply", "scope_restore", "scope_forget" }





-- =====================================
-- =====================================
-- ======= 1/ Declaration checks =======
-- =====================================
-- =====================================

--- Validates one declared field list and adds its names to the shared index.
--- @param list any Declared field names.
--- @param label string Declaration name for the failure message.
--- @param seen table Names already declared by another list.
--- @return table names Detached dense list of names.
local function field_list(list, label, seen)
	assert(type(list) == "table" and getmetatable(list) == nil, "scope owner: " .. label .. " must be a plain list")
	local names = {}
	for index, name in ipairs(list) do
		assert(type(name) == "string" and name ~= "", "scope owner: " .. label .. " names must be non-empty strings")
		assert(name ~= "module", "scope owner: the module field is the protocol's own")
		assert(not seen[name], "scope owner: field declared twice: " .. name)
		seen[name], names[index] = true, name
	end
	local count = 0
	for _ in pairs(list) do count = count + 1 end
	assert(count == #names, "scope owner: " .. label .. " must be a dense list")
	return names
end

--- Validates an optional predicate, defaulting to one that always admits.
--- @param value any Declared predicate.
--- @param label string Declaration name for the failure message.
--- @return function predicate
local function optional_predicate(value, label)
	if value == nil then return function() return true end end
	assert(type(value) == "function", "scope owner: " .. label .. " must be a function")
	return value
end





-- ==================================
-- ==================================
-- ======= 2/ Admission state =======
-- ==================================
-- ==================================

--- Creates the admission state of one module's scope field.
--- @param options table { name = package.loaded key, module = the owning module table }.
--- @return table scope Admission queries and the one-shot install().
function M.new(options)
	assert(type(options) == "table" and getmetatable(options) == nil, "scope owner: options must be a plain table")
	local name, module = options.name, options.module
	assert(type(name) == "string" and name ~= "", "scope owner: name must be the module's package.loaded key")
	assert(type(module) == "table", "scope owner: module must be the owning module table")
	for key in pairs(options) do
		assert(key == "name" or key == "module", "scope owner: unknown option " .. tostring(key))
	end

	local holder, busy, generation, installed = nil, false, 0, false
	-- Receipts are weak keys: a transaction that drops its receipt drops the inverse.
	local receipts = setmetatable({}, { __mode = "k" })
	local scope = {}

	--- Whether no transaction holds the field and no scope call is running.
	--- @return boolean idle
	function scope.idle() return holder == nil and not busy end

	--- Admits one ordinary mutation: refused while a transaction holds the
	--- field, otherwise it invalidates every receipt captured before it.
	--- @return boolean admitted
	function scope.admit_change()
		if holder ~= nil or busy then return false end
		generation = generation + 1
		return true
	end

	--- The generation an asynchronous caller compares to detect a later change.
	--- @return integer generation
	function scope.generation() return generation end

	--- Publishes the six scope methods on the owning module, once.
	--- @param spec table Field declaration and the module's own callbacks:
	---   state() -> table of the declared fields (the protocol adds `module`);
	---   identity, stable, published: field-name lists (identity compared with
	---   rawequal, the others with ==; only published fields may change);
	---   accept(value) -> table of the published fields' next values, or nil to refuse;
	---   publish(target) writes target's published values, raising on refusal;
	---   ready() optional, checked before a transaction may acquire;
	---   live() optional, checked at every step (a replaced backend refuses).
	function scope.install(spec)
		assert(not installed, "scope owner: " .. name .. " installed its scope methods twice")
		assert(type(spec) == "table" and getmetatable(spec) == nil, "scope owner: spec must be a plain table")
		for key in pairs(spec) do
			assert(key == "state" or key == "identity" or key == "stable" or key == "published" or key == "accept"
				or key == "publish" or key == "ready" or key == "live", "scope owner: unknown spec field " .. tostring(key))
		end
		assert(type(spec.state) == "function", "scope owner: state must be a function")
		assert(type(spec.accept) == "function", "scope owner: accept must be a function")
		assert(type(spec.publish) == "function", "scope owner: publish must be a function")
		local seen = {}
		local identity = field_list(spec.identity or {}, "identity", seen)
		local stable = field_list(spec.stable or {}, "stable", seen)
		local published = field_list(spec.published, "published", seen)
		assert(#published > 0, "scope owner: published must name at least one field")
		local ready, live = optional_predicate(spec.ready, "ready"), optional_predicate(spec.live, "live")
		local read_state, accept, publish = spec.state, spec.accept, spec.publish
		for _, method in ipairs(METHOD_NAMES) do
			assert(rawget(module, method) == nil, "scope owner: " .. name .. " already defines " .. method)
		end

		local function current_module() return rawequal(package.loaded[name], module) end

		local function state()
			local snapshot = read_state()
			assert(type(snapshot) == "table" and snapshot.module == nil, "scope owner: state must return the declared fields")
			snapshot.module = package.loaded[name]
			return snapshot
		end

		local function equal(left, right)
			if not rawequal(left.module, right.module) then return false end
			for _, field in ipairs(identity) do if not rawequal(left[field], right[field]) then return false end end
			for _, field in ipairs(stable) do if left[field] ~= right[field] then return false end end
			for _, field in ipairs(published) do if left[field] ~= right[field] then return false end end
			return true
		end

		-- A restore admits a published field still at its captured or applied
		-- value; every other field must be exactly as captured.
		local function restorable(current, before, expected)
			if not rawequal(current.module, before.module) then return false end
			for _, field in ipairs(identity) do if not rawequal(current[field], before[field]) then return false end end
			for _, field in ipairs(stable) do if current[field] ~= before[field] then return false end end
			for _, field in ipairs(published) do
				if current[field] ~= before[field] and current[field] ~= expected[field] then return false end
			end
			return true
		end

		local function next_state(before, value)
			local values = accept(value)
			if type(values) ~= "table" then return nil end
			local declared = {}
			for _, field in ipairs(published) do declared[field] = true end
			for field in pairs(values) do assert(declared[field], "scope owner: accept returned an undeclared field") end
			local next_value = {}
			for key, child in pairs(before) do next_value[key] = child end
			for _, field in ipairs(published) do next_value[field] = values[field] end
			return next_value
		end

		--- Runs one protocol step behind the reentry gate.
		--- @param step function Unguarded step.
		--- @param refused any Value answered while busy or when the step throws.
		--- @return function guarded
		local function guarded(step, refused)
			return function(...)
				if busy then return refused end
				busy = true
				local called, result = pcall(step, ...)
				busy = false
				if not called then return refused end
				return result
			end
		end

		local function acquire(owner)
			if type(owner) ~= "table" or type(owner.pending) ~= "function" or holder ~= nil
				or not current_module() then return false end
			if not ready() or not live() or not current_module() then return false end
			holder = owner
			return true
		end

		local function capture(owner)
			if not rawequal(holder, owner) or not current_module() or not live() then return nil end
			local captured_generation = generation
			local receipt, before = {}, state()
			if not rawequal(holder, owner) or not current_module() or generation ~= captured_generation
				or not live() then return nil end
			receipts[receipt] = { owner = owner, before = before, expected = before, generation = generation }
			return receipt
		end

		local function apply(owner, receipt, value)
			local data = receipts[receipt]
			if not rawequal(holder, owner) or not data or not rawequal(data.owner, owner) or data.forgotten or data.attempted
				or data.generation ~= generation or not live() or not equal(state(), data.expected)
				or not current_module() then return false end
			local next_value = next_state(data.before, value)
			if next_value == nil then return false end
			generation = generation + 1
			data.generation, data.expected, data.attempted = generation, next_value, true
			local called = pcall(publish, next_value)
			local observed = state()
			return called and equal(observed, next_value) and rawequal(holder, owner)
				and current_module() and live() and data.generation == generation
		end

		local function restore(owner, receipt)
			local data = receipts[receipt]
			if not rawequal(holder, owner) or not data or not rawequal(data.owner, owner) or data.forgotten
				or data.generation ~= generation or not live() then return false end
			local current = state()
			if not rawequal(current.module, module) or not current_module() or not live()
				or not restorable(current, data.before, data.expected) then return false end
			if not data.attempted or data.restored then return equal(current, data.before) end
			local called = pcall(publish, data.before)
			local observed = state()
			if not called or not equal(observed, data.before) or not rawequal(holder, owner)
				or not current_module() or not live() or data.generation ~= generation then return false end
			generation = generation + 1
			data.generation, data.expected, data.restored = generation, data.before, true
			return true
		end

		local methods = {}
		local guarded_acquire = guarded(acquire, false)

		--- Acquires the declared runtime field for one primary transaction token.
		--- pending() describes the token's primary compensation only.
		methods.scope_acquire = function(owner) return guarded_acquire(owner) == true end

		--- Releases the admission gate while retaining opaque inverse receipts.
		methods.scope_release = function(owner)
			if busy or not rawequal(holder, owner) or owner.pending() ~= false then return false end
			holder = nil
			return true
		end

		--- Captures an opaque, source-bound runtime inverse under the native claim.
		methods.scope_capture = guarded(capture, nil)

		--- Applies one canonical value after proving the captured runtime still owns it.
		methods.scope_apply = guarded(apply, false)

		--- Restores only this receipt's acknowledged or interrupted publication.
		methods.scope_restore = guarded(restore, false)

		--- Forgets only a finalized inverse, without changing live native state.
		methods.scope_forget = function(owner, receipt)
			local data = receipts[receipt]
			if busy or rawequal(holder, owner) or not data or not rawequal(data.owner, owner)
				or owner.pending() ~= false then return false end
			if data.forgotten then return true end
			data.before, data.expected, data.generation = nil, nil, nil
			data.forgotten = true
			return true
		end

		for _, method in ipairs(METHOD_NAMES) do module[method] = methods[method] end
		installed = true
	end

	return scope
end

return M
