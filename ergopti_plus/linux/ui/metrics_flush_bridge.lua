--- ui/metrics_flush_bridge.lua

--- Owns dashboard requests across SQLite settlement and native page replacement.
local M = {}
local Logger = require("logger.shim")
local LOG = "bridge.metrics_flush"
local API = { "get_flush_status", "is_flush_pending", "has_flush_debt", "when_flush_settled" }

--- Reads the mandatory RAM-only flush contract, refusing incomplete owners.
--- @param keylogger table|nil
--- @return table|nil status
function M.status(keylogger)
	if type(keylogger) ~= "table" then return nil end
	for _, name in ipairs(API) do
		if type(keylogger[name]) ~= "function" then return nil end
	end
	local ok, status = pcall(keylogger.get_flush_status)
	if not ok or type(status) ~= "table" or type(status.phase) ~= "string"
		or type(status.generation) ~= "number" or status.generation < 0
		or status.generation % 1 ~= 0 then return nil end
	for _, name in ipairs({ "pending", "has_debt", "read_safe", "committed", "stopping" }) do
		if type(status[name]) ~= "boolean" then return nil end
	end
	local ok_pending, pending = pcall(keylogger.is_flush_pending)
	local ok_debt, debt = pcall(keylogger.has_flush_debt)
	if not ok_pending or not ok_debt or pending ~= status.pending or debt ~= status.has_debt
		or (status.pending and status.read_safe) then return nil end
	return status
end

local function manager_for(state)
	if state.webview_manager ~= nil then return state.webview_manager end
	return require("ui.webview_manager")
end

local function page_current(app, state, context)
	if context == nil or context.epoch == nil then return true end
	if context.app_name ~= app or type(context.epoch) ~= "number" then return false end
	local ok, current = pcall(function()
		return manager_for(state).page_current(app, context.epoch)
	end)
	return ok and current == true
end

--- Sends a complete dashboard payload only to the exact native requesting page.
--- @param app string
--- @param bridge string
--- @param payload table
--- @param state table
--- @param context table|nil
--- @return boolean pushed
function M.push(app, bridge, payload, state, context)
	if not context or type(context.epoch) ~= "number" or not page_current(app, state, context) then return false end
	local Json, Base64 = require("json"), require("compat.base64")
	local code = string.format("if(window.__hostBridgeResponse)window.__hostBridgeResponse('%s',true,'%s')",
		bridge, Base64.encode(Json.encode(payload)))
	if not page_current(app, state, context) then return false end
	return manager_for(state).eval_js(app, code) == true
end

--- Creates one request owner for a dashboard bridge.
--- @param app string
--- @param push function
--- @param commit function|nil Called only after a complete admitted result.
--- @return table controller
function M.new(app, push, commit)
	local controller = {}
	local read_generation, closed_epoch, revision = 0, 0, 0
	local batch = nil

	--- Admits or queues one action; only reads supersede previous reads.
	--- @param state table
	--- @param context table|nil
	--- @param execute function
	--- @param mutation boolean
	--- @param force_push boolean|nil
	--- @return table|nil payload
	function controller.run(state, context, execute, mutation, force_push)
		if context ~= nil and (type(context) ~= "table"
			or (context.epoch ~= nil and type(context.epoch) ~= "number")) then return nil end
		if context ~= nil then
			context = { app_name = context.app_name, epoch = context.epoch }
		end
		local keylogger = state.keylogger
		local status = keylogger and M.status(keylogger) or nil
		if status and status.stopping then return nil end
		if keylogger and (not status or (not status.pending and not status.read_safe)) then
			Logger.error(LOG, "Dashboard request refused: the keylogger has no readable flush owner.")
			return nil
		end
		read_generation = read_generation + 1
		local request = { generation = status and status.generation, state = state, context = context }
		local read_id, request_revision = read_generation, revision
		local methods = {}
		for _, name in ipairs(API) do methods[name] = keylogger and keylogger[name] end

		local function owned()
			if request_revision ~= revision or state.keylogger ~= keylogger
				or (not mutation and read_id ~= read_generation) then return false end
			if context and context.epoch and context.epoch <= closed_epoch then return false end
			if not page_current(app, state, context) then return false end
			for _, name in ipairs(API) do
				if keylogger and keylogger[name] ~= methods[name] then return false end
			end
			return true
		end

		function request.valid()
			if not owned() then return false end
			if not keylogger then return true end
			local current = M.status(keylogger)
			return owned() and current ~= nil and current.generation == request.generation
				and current.read_safe and not current.pending and not current.stopping
		end

		--- Only reset_session's positive ACK authorizes its own one-step generation change.
		function request.accept_reset()
			if not owned() or not keylogger then return false end
			local current = M.status(keylogger)
			if not current or current.generation ~= request.generation + 1 or not current.read_safe
				or current.pending or current.has_debt or current.stopping or not owned() then return false end
			request.generation = current.generation
			return true
		end

		local function finish(delayed)
			if not request.valid() then return nil end
			local ok, result, cache = pcall(execute, request)
			if not ok then
				Logger.error(LOG, "Dashboard request failed: %s", tostring(result))
				return nil
			end
			if type(result) ~= "table" or not request.valid() then return nil end
			if commit then commit(result, cache, keylogger, request.generation) end
			if not request.valid() then return nil end
			if delayed or force_push then push(result, state, context) end
			return result
		end

		if not owned() then return nil end
		if not status or status.read_safe then return finish(false) end
		if not batch or batch.keylogger ~= keylogger or batch.generation ~= status.generation then
			batch = { keylogger = keylogger, generation = status.generation, requests = {} }
		end
		local pending = batch
		-- Polls replace only older reads. Mutations retain their own page/generation.
		if not mutation then
			for index = #pending.requests, 1, -1 do
				if not pending.requests[index].mutation then table.remove(pending.requests, index) end
			end
		end
		pending.requests[#pending.requests + 1] = { finish = finish, mutation = mutation }
		if pending.subscribed then return nil end
		pending.subscribed = true
		local function deliver()
			if batch ~= pending or not pending.armed or pending.delivered then return end
			pending.delivered, batch = true, nil
			for _, queued in ipairs(pending.requests) do queued.finish(true) end
			pending.requests = {}
		end
		local ok, accepted = pcall(methods.when_flush_settled, function()
			pending.notified = true
			if pending.armed then deliver() end
		end)
		if not ok or accepted ~= true then
			if batch == pending then batch = nil end
			pending.requests = {}
			Logger.error(LOG, "Dashboard settlement subscription was refused.")
			return nil
		end
		pending.armed = true
		if pending.notified then deliver() end
		return nil
	end

	--- Revokes callbacks belonging to a closed native page, retaining other owners.
	--- @param epoch number
	function controller.close(epoch)
		if type(epoch) == "number" then closed_epoch = math.max(closed_epoch, epoch) end
	end

	--- Revokes every outstanding request without reusing cancellation tokens.
	function controller.reset()
		revision, batch = revision + 1, nil
	end

	return controller
end

return M
