--- _shared/lua/llm/local_server_discovery.lua

--- ==============================================================================
--- MODULE: Local Server Discovery Controller
--- DESCRIPTION:
--- Centralizes ordered joint publication, cache age, captured probe identities
--- and superseding sweep generations. Native HTTP/credential/cleanup owners
--- remain injected by the driver: a generation fence never acknowledges native
--- process, task or timer retirement.
--- ==============================================================================

local M = {}
local AuthPolicy = require("llm.local_server_auth")

M.STATUS_UP = "up"
M.STATUS_NEEDS_KEY = "needs_key"
M.STATUS_DOWN = "down"

--- Classifies one models response using the catalogue's shared typed codec.
--- @param response table|nil Actual HTTP adapter response.
--- @return string status
--- @return table|nil models
function M.classify(response)
	if type(response) ~= "table" then return M.STATUS_DOWN, nil end
	local status = tonumber(response.status) or 0
	if status == 401 or status == 403 then return M.STATUS_NEEDS_KEY, nil end
	if response.ok ~= true then return M.STATUS_DOWN, nil end
	local models = AuthPolicy.models_receipt(response)
	if not models then return M.STATUS_DOWN, nil end
	return M.STATUS_UP, models
end

--- Compares only the owned observable verdict fields and ordered model IDs.
--- @param a table|nil
--- @param b table|nil
--- @return boolean
local function verdict_changed(a, b)
	if a == nil or b == nil then return a ~= b end
	if a.status ~= b.status or a.base_url ~= b.base_url or #a.models ~= #b.models then return true end
	for index, model in ipairs(a.models) do
		if b.models[index] ~= model then return true end
	end
	return false
end

--- Creates an independent controller; clock and max_age use the same host units.
--- No timing literal lives here: drivers pass their shared timings registry.
--- @param options table { order, clock, max_age, on_publish?, on_error? }.
--- @return table controller
function M.new(options)
	assert(type(options) == "table", "local discovery controller options are required")
	assert(type(options.order) == "table", "local discovery controller order is required")
	assert(type(options.clock) == "function", "local discovery controller clock is required")
	assert(type(options.max_age) == "function", "local discovery controller cache age is required")
	local order = {}
	for index, id in ipairs(options.order) do order[index] = id end
	local results, checked_at, generation, active, waiters = {}, nil, 0, false, {}
	local controller = {}

	--- Reports a contained producer/observer refusal through the native log port.
	--- @param kind string
	--- @param detail any
	--- @param id any
	local function report(kind, detail, id)
		if type(options.on_error) == "function" then options.on_error(kind, detail, id) end
	end

	--- Invokes an observer with a traceback on both Lua 5.1 and Lua 5.4.
	--- @param callback function
	--- @param changed boolean
	local function observe(callback, changed)
		local ok, err = xpcall(function() callback(changed) end, debug.traceback)
		if not ok then report("observer", err) end
	end

	--- Starts a logical sweep; the producer retains its physical lifecycle owner.
	--- @param targets table Array of { id, base_url, token?, ... }.
	--- @param probe function (captured_target, settle, ticket) -> boolean dispatched.
	--- @param on_done function|nil Receives changed when the newest sweep publishes.
	--- @return boolean
	function controller.sweep(targets, probe, on_done)
		if type(targets) ~= "table" or type(probe) ~= "function" then
			error("local_servers.sweep: targets and a probe are required")
		end
		if on_done ~= nil and type(on_done) ~= "function" then
			error("local_servers.sweep: on_done must be a function")
		end
		-- Copy before any producer runs. A native producer may annotate its input
		-- or pump a callback that changes the caller's next target record.
		local captured = {}
		for index, target in ipairs(targets) do
			local copy = {}
			for key, value in pairs(target) do copy[key] = value end
			captured[index] = copy
		end
		generation = generation + 1
		local own_generation = generation
		active = true
		if on_done then waiters[#waiters + 1] = on_done end
		local fresh, pending = {}, #captured

		local function finish()
			if own_generation ~= generation then return end
			active = false
			local changed = false
			for _, id in ipairs(order) do
				if verdict_changed(results[id], fresh[id]) then changed = true end
			end
			results, checked_at = fresh, options.clock()
			-- Detach these callers before a publishing hook can reenter a new
			-- sweep: its fresh callers must not be consumed by this publication.
			local completed_waiters = waiters
			waiters = {}
			if type(options.on_publish) == "function" then
				local ok, err = xpcall(function() options.on_publish(fresh, changed) end, debug.traceback)
				if not ok then report("publication", err) end
			end
			for _, waiter in ipairs(completed_waiters) do observe(waiter, changed) end
		end

		if pending == 0 then finish(); return true end
		for _, target in ipairs(captured) do
			-- A producer can reenter while acquiring a native request. Continuing
			-- this older dispatch loop could cancel the newer exact HTTP owner.
			if own_generation ~= generation then return true end
			local id, base_url = target.id, target.base_url
			local settled = false
			local function settle(response)
				if settled or own_generation ~= generation then return end
				settled = true
				local status, models = M.classify(response)
				fresh[id] = { status = status, base_url = base_url, models = models or {} }
				pending = pending - 1
				if pending == 0 then finish() end
			end
			-- A retained asynchronous producer can use this logical ticket before
			-- acquiring or delivering. It never acknowledges native retirement.
			local ticket = { is_current = function()
				return own_generation == generation and not settled
			end }
			local ok, dispatched = xpcall(function() return probe(target, settle, ticket) end, debug.traceback)
			if not ok or dispatched ~= true then
				report("probe", ok and "the probe was refused" or dispatched, id)
				settle(nil)
			end
		end
		return true
	end

	--- Returns the last jointly published verdict of a catalogue server.
	--- @param id string
	--- @return table|nil
	function controller.result(id) return results[id] end

	--- Returns answering servers in the authoritative catalogue order.
	--- @return table
	function controller.detected()
		local ids = {}
		for _, id in ipairs(order) do
			local verdict = results[id]
			if verdict and verdict.status ~= M.STATUS_DOWN then ids[#ids + 1] = id end
		end
		return ids
	end

	--- Returns whether a new logical sweep is due; native debt belongs to its port.
	--- @return boolean
	function controller.is_stale()
		if active then return false end
		if checked_at == nil then return true end
		return options.clock() - checked_at >= options.max_age()
	end

	--- Invalidates logical tickets and observers while retaining the last cache.
	--- Native callers separately retain cancellation/cleanup ownership.
	function controller.invalidate()
		generation = generation + 1
		active, checked_at, waiters = false, nil, {}
	end

	--- Returns logical discovery activity, never physical native retirement.
	--- @return boolean
	function controller.is_sweeping() return active end

	return controller
end

return M
