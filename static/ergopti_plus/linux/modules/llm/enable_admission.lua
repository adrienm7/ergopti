--- modules/llm/enable_admission.lua

--- ===============================================================================
--- MODULE: Owned Local AI Enable Probe
--- DESCRIPTION:
--- Performs a read-only Ollama version request before the existing preference
--- owner can enable the AI. Exact cancellation debt blocks every successor.
--- ===============================================================================

local M = {}
local Policy = require("llm.enable_admission")
local Http = require("adapters.http_client")
local Timings = require("infra.timings")
local Logger = require("logger.shim")
local LOG = "modules.llm.enable_admission"
local OWNER = "llm_enable_admission"





-- ===================================
-- ===================================
-- ======= 1/ Native Lifecycle =======
-- ===================================
-- ===================================

--- Creates the native owner around existing source, writer and UI ports.
--- @param context table { snapshot, commit, reject, changed }.
--- @return table
function M.new(context)
	assert(type(context) == "table" and type(context.snapshot) == "function"
		and type(context.commit) == "function" and type(context.reject) == "function",
		"Local AI enable admission requires exact snapshot, commit and rejection owners")
	local active = nil
	local owner = {}

	local function matches(request)
		local ok, live = pcall(context.snapshot)
		return ok and Policy.current(request.snapshot, live)
	end

	local function current(request)
		return matches(request) and active == request and not request.cancelled
	end

	local function reject(request, reason, receipt, cleanup_only)
		local choice = context.reject(request.snapshot.origin, reason, receipt,
			request.snapshot, function() return matches(request) end, cleanup_only == true)
		-- A modal choice can outlive source, pause or scope admission.
		if choice == "retry" and matches(request) then return owner.enable() end
		return false
	end

	local function settle(request, receipt)
		local observed, retired = false, false
		if not request.acquiring and request.operation and request.started == true then
			observed, retired = pcall(request.settled, request.operation)
		end
		if not observed or retired ~= true then request.receipt = receipt; return false end
		request.receipt = nil
		if not current(request) then
			if active == request then active = nil end
			return false
		end
		local admitted, reason = Policy.receipt(receipt)
		active = nil
		if admitted then
			local committed = context.commit(request.snapshot.source) == true
			if committed and type(context.changed) == "function" then context.changed() end
			return committed
		end
		Logger.warn(LOG, "Local AI enable admission refused: %s.", reason)
		return reject(request, reason, receipt)
	end

	--- Cancels only this probe; refusal retains its exact identity for retry.
	--- @return boolean
	function owner.cancel()
		local request = active
		if not request then return true end
		request.cancelled = true
		if request.creating or request.acquiring or not request.operation then return false end
		local called = pcall(request.retire, request.operation)
		local observed, settled = pcall(request.settled, request.operation)
		if not called or not observed or settled ~= true then return false end
		if active == request then active = nil end
		return active == nil
	end

	--- Dispatches read-only proof; a synchronous callback cannot outrun refusal.
	--- @return boolean dispatched
	function owner.enable()
		if active then return false end
		-- Reserve the source/constructor frame before even the snapshot can reenter.
		local request = { creating = true, dispatching = true }
		active = request
		local ok, snapshot = pcall(context.snapshot)
		request.creating = false
		if not ok or type(snapshot) ~= "table" or request.cancelled then
			if active == request then active = nil end
			Logger.warn(LOG, "Local AI enable admission refused an unreadable configuration.")
			return false
		end
		request.snapshot = snapshot
		if not Policy.requires_probe(snapshot.backend) then
			request.creating = true
			local committed = snapshot.backend == "api" and snapshot.enabled == false
				and snapshot.paused == false and snapshot.blocked == false
				and context.commit(snapshot.source) == true
			request.creating = false
			committed = committed and not request.cancelled and active == request
			if active == request then active = nil end
			if committed and type(context.changed) == "function" then context.changed() end
			return committed
		end
		if not Policy.current(snapshot, snapshot) then
			if active == request then active = nil end
			return false
		end
		request.acquiring = true
		local called, operation = pcall(Http.get_owned, snapshot.origin:gsub("/$", "") .. Policy.VERSION_PATH, {}, {
			owner = OWNER, timeout_ms = Timings.ms("llm", "local_server_probe_timeout_ms"),
			follow_redirects = false, authorized = function() return current(request) end,
		}, function(receipt)
			if active ~= request or request.cancelled then return end
			if request.dispatching then request.receipt = receipt
			else settle(request, receipt) end
		end)
		request.dispatching, request.acquiring = false, false
		if not called or type(operation) ~= "table" or type(operation.cancel) ~= "function"
			or type(operation.is_settled) ~= "function" or type(operation.on_settled) ~= "function"
			or type(operation.started) ~= "boolean" then
			request.cancelled = true
			-- Unknown constructor unwind cannot prove native resources absent.
			return false
		end
		request.operation, request.retire, request.settled = operation, operation.cancel, operation.is_settled
		request.started = operation.started
		local notify = operation.on_settled
		notify(operation, function()
			if active ~= request then return end
			local allowed = not request.cancelled and current(request)
			if active ~= request then return end
			if not allowed then owner.cancel()
			elseif request.started and request.receipt then settle(request, request.receipt) end
		end)
		if request.cancelled then owner.cancel(); return false end
		if request.started ~= true then
			local allowed = current(request)
			local retired = owner.cancel() == true
			if allowed then return reject(request, "ollama_unreachable", nil, not retired) end
			return false
		end
		if request.receipt then settle(request, request.receipt) end
		return true
	end

	--- Whether a probe or refused cancellation still owns native work.
	--- @return boolean
	function owner.pending() return active ~= nil end

	return owner
end

return M
