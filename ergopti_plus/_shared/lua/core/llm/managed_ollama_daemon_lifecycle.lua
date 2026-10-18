--- _shared/lua/core/llm/managed_ollama_daemon_lifecycle.lua
--- Shared foreground lifecycle over exact transport ports. A start acknowledgement
--- is not READY, and physical exit alone is not the native RETIRED receipt.
local M = {}
local Receipt = require("core.llm.managed_ollama_daemon_receipt")

function M.new(original, nonce, ports, callbacks)
	if type(ports) ~= "table" or type(callbacks) ~= "table" then return nil, "state" end
	local start = rawget(ports, "start")
	local cancel = rawget(ports, "cancel")
	local observe = rawget(ports, "observe")
	if type(start) ~= "function" or type(cancel) ~= "function" or type(observe) ~= "function" then
		return nil, "state"
	end
	local on_ready, on_done, on_debt = callbacks.on_ready, callbacks.on_done, callbacks.on_debt
	if type(on_ready) ~= "function" or type(on_done) ~= "function" or type(on_debt) ~= "function" then
		return nil, "state"
	end
	local receipt, reason = Receipt.new(original, nonce, {
		max_protocol_bytes = rawget(ports, "max_protocol_bytes"),
		is_settled = rawget(ports, "is_settled"),
		was_start_attempted = rawget(ports, "was_start_attempted"),
	})
	if not receipt then return nil, reason end
	local handle = {}
	local observers = {}
	local committed, starting, published, joined = false, false, false, false
	local completion, completion_status, debt_sent = false, nil, false

	local function debt(reason_value)
		if not debt_sent then
			debt_sent = true
			pcall(on_debt, handle, reason_value)
		end
	end

	local function notify()
		local pending = observers
		observers = {}
		for _, callback in ipairs(pending) do pcall(callback) end
	end

	local function reconcile()
		if joined or starting then return joined end
		if completion then
			local retired, state = receipt.finish(original, completion_status)
			if retired == true then
				joined = true
				pcall(on_done, handle, completion_status)
				notify()
			elseif state ~= "pending" then debt(state) end
			return joined
		end
		if committed and not published and receipt.ready_observed(original) == true then
			published = true
			pcall(on_ready, handle)
		end
		return false
	end

	function handle.feed(chunk)
		if receipt.feed(original, chunk) ~= true then
			debt("protocol")
			pcall(cancel, original)
			return false
		end
		reconcile()
		return true
	end

	function handle.complete(status, remainder)
		if completion then return false end
		completion, completion_status = true, status
		if type(remainder) ~= "string" or receipt.feed(original, remainder) ~= true then
			debt("protocol")
		end
		reconcile()
		return true
	end

	function handle.start()
		if committed or starting or joined or completion or debt_sent then return false end
		starting = true
		local ok, accepted = pcall(start, original)
		starting = false
		committed = ok == true and accepted == true
		reconcile()
		if not committed then handle.terminate() end
		return committed
	end

	function handle.terminate()
		if joined then return true, "settled" end
		local ok, accepted = pcall(cancel, original)
		if receipt.rollback_prepared(original) == true then
			joined = true
			notify()
			return true, "settled"
		end
		reconcile()
		if joined then return true, "settled" end
		return ok == true and accepted == true, "pending"
	end

	function handle.isSettled() return joined end
	function handle.onSettled(callback)
		if type(callback) ~= "function" then return false end
		if joined then pcall(callback); return true end
		observers[#observers + 1] = callback
		return true
	end

	-- The port observes only physical settlement; reconciliation still requires
	-- the exact complete native receipt and matching completion status.
	local ok, observed = pcall(observe, original, reconcile)
	if not ok or observed ~= true then debt("observation") end
	return handle, nil
end

return M
