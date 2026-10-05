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
		return active == request and matches(request)
	end

	local function reject(request, reason, receipt)
		local choice = context.reject(request.snapshot.origin, reason, receipt,
			request.snapshot, function() return matches(request) end)
		-- A modal choice can outlive source, pause or scope admission.
		if choice == "retry" and matches(request) then return owner.enable() end
		return false
	end

	local function settle(request, receipt)
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
		if not active then return true end
		active.cancelled = true
		if Http.cancel(OWNER) ~= true then return false end
		active = nil
		return true
	end

	--- Dispatches read-only proof; a synchronous callback cannot outrun refusal.
	--- @return boolean dispatched
	function owner.enable()
		if active then return false end
		local ok, snapshot = pcall(context.snapshot)
		if not ok or type(snapshot) ~= "table" then
			Logger.warn(LOG, "Local AI enable admission refused an unreadable configuration.")
			return false
		end
		if not Policy.requires_probe(snapshot.backend) then
			local committed = snapshot.backend == "api" and snapshot.enabled == false
				and snapshot.paused == false and snapshot.blocked == false
				and context.commit(snapshot.source) == true
			if committed and type(context.changed) == "function" then context.changed() end
			return committed
		end
		if not Policy.current(snapshot, snapshot) then return false end
		local request = { snapshot = snapshot, dispatching = true }
		active = request
		local called, dispatched = pcall(function()
			return Http.get(snapshot.origin:gsub("/$", "") .. Policy.VERSION_PATH, {}, {
				owner = OWNER, timeout_ms = Timings.ms("llm", "local_server_probe_timeout_ms"),
				follow_redirects = false,
			}, function(receipt)
				if active ~= request then return end
				if request.cancelled then active = nil return end
				if request.dispatching then request.receipt = receipt
				else settle(request, receipt) end
			end)
		end)
		request.dispatching = false
		if not called or dispatched ~= true then
			request.cancelled = true
			if Http.cancel(OWNER) == true and active == request then active = nil end
			if matches(request) then return reject(request, "ollama_unreachable", nil) end
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
