--- modules/llm/model_inventory.lua

--- ==============================================================================
--- MODULE: Owned Ollama Model Inventory
--- DESCRIPTION:
--- Keeps synchronous model projections separate from deferred, physically owned
--- HTTP acquisition. A failed cold attempt is retried only by an explicit request
--- or by a fresh runtime source, never by repeated menu projections.
--- ==============================================================================

local M = {}
local Http = require("adapters.http_client")
local Deferred = require("infra.managed_http_deadline")
local Monotonic = require("infra.monotonic")
local Bridge = require("infra.llm_bridge")
local Policy = require("llm.local_model_policy")
local Json = require("json")
local Logger = require("logger.shim")
local LOG = "modules.llm.model_inventory"
local OWNER = "ollama_model_inventory"






-- =======================================
-- =======================================
-- ======= 1/ Retained Acquisition =======
-- =======================================
-- =======================================

--- Creates one inventory owned by an exact Profiles initialization.
--- @param context table Original engine, capture/current ports, origin and owner.
--- @return table owner Synchronous projections and physical cancellation.
function M.new(context)
	local owner, active, attempt, cache, reading = {}, nil, nil, nil, nil
	local engine, capture, current = context.engine, context.capture, context.current
	local origin, retained, changed = context.origin, context.retained, context.changed
	local get, defer, clock = Http.get_owned, Deferred.start, Monotonic.now_ms
	local finish, dispatch, request

	local function source_current(frame)
		if not frame or not retained() or package.loaded["modules.llm.prediction_engine"] ~= engine
			or engine.capture_runtime_response ~= capture or engine.runtime_response_current ~= current then return false end
		local ok, admitted = pcall(current, frame.receipt, origin)
		return ok and admitted == true and retained()
			and package.loaded["modules.llm.prediction_engine"] == engine
			and engine.capture_runtime_response == capture and engine.runtime_response_current == current
	end

	local function authorized(frame)
		if active ~= frame or frame.revoked or not source_current(frame) then return false end
		return active == frame and not frame.revoked and package.loaded["adapters.http_client"] == Http
			and Http.get_owned == get and package.loaded["infra.managed_http_deadline"] == Deferred
			and Deferred.start == defer and Monotonic.now_ms == clock
	end

	local function settled(capability)
		if not capability then return true end
		local op = capability.operation
		if op.cancel ~= capability.cancel or op.is_settled ~= capability.settled
			or op.on_settled ~= capability.notify or (capability.result and op.settled_result ~= capability.result) then return false end
		local ok, closed = pcall(capability.settled, op)
		return ok and closed == true and op.cancel == capability.cancel and op.is_settled == capability.settled
			and op.on_settled == capability.notify and (not capability.result or op.settled_result == capability.result)
	end

	local function physically_settled(frame)
		return not frame.constructing and not frame.unknown_debt and settled(frame.deferred) and settled(frame.http)
	end

	local function retire(capability)
		if not capability then return true end
		local ok, accepted = pcall(capability.cancel, capability.operation)
		return ok and accepted == true and settled(capability)
	end

	local function cancel_frame(frame)
		frame.after_mutation = nil
		frame.revoked = true
		local deferred_closed, http_closed = retire(frame.deferred), retire(frame.http)
		local closed = deferred_closed and http_closed and physically_settled(frame)
		if closed and active == frame then active = nil end
		return closed and active ~= frame
	end

	local function attach(frame, operation, is_http)
		if type(operation) ~= "table" or type(operation.cancel) ~= "function"
			or type(operation.is_settled) ~= "function" or type(operation.on_settled) ~= "function"
			or type(operation.started) ~= "boolean" or (is_http and type(operation.settled_result) ~= "function") then
			frame.unknown_debt, frame.revoked = true, true
			return false
		end
		local capability = { operation = operation, cancel = operation.cancel, settled = operation.is_settled,
			notify = operation.on_settled, result = is_http and operation.settled_result or nil }
		if is_http then frame.http = capability else frame.deferred = capability end
		local ok, accepted = pcall(capability.notify, operation, function() finish(frame) end)
		if not ok or accepted ~= true then frame.revoked = true; return false end
		return true
	end

	--- Consumes only this source's post-install intent after its old native ACK.
	local function follow_mutation(frame)
		local intent = frame.after_mutation
		if not intent then return false end
		local ok, receipt = pcall(capture)
		local fresh = { receipt = ok and receipt or nil }
		if not source_current(intent) or not source_current(fresh) or not authorized(frame)
			or not physically_settled(frame) or active ~= frame or frame.revoked
			or frame.after_mutation ~= intent then
			frame.finishing = false
			cancel_frame(frame)
			return true
		end
		frame.after_mutation, frame.finishing = nil, false
		active = nil
		request(fresh)
		return true
	end

	finish = function(frame)
		if active ~= frame or frame.constructing or frame.finishing then return end
		if frame.revoked then
			frame.after_mutation = nil
			if physically_settled(frame) then active = nil end
			return
		end
		if not authorized(frame) then cancel_frame(frame); return end
		if not frame.http then
			if frame.fired and settled(frame.deferred) then dispatch(frame) end
			return
		end
		if not physically_settled(frame) then return end
		frame.finishing = true
		if follow_mutation(frame) then return end
		local ok, result = pcall(frame.http.result, frame.http.operation)
		local parsed, names = pcall(Policy.list_receipt, ok and result or nil)
		local models = {}
		if parsed and names then
			local decoded, root = pcall(Json.decode_lossless, result.body)
			if not decoded or type(root) ~= "table" or not Json.is_array(root.models) then names = nil
			else
				for _, entry in ipairs(root.models) do
					models[#models + 1] = type(entry.name) == "string" and entry.name ~= "" and entry.name or entry.model
				end
			end
		end
		if not authorized(frame) then frame.finishing = false; cancel_frame(frame); return end
		if follow_mutation(frame) then return end
		if names then
			cache = { frame = frame, models = models }
			Logger.info(LOG, "Fetched %d model(s) from Ollama.", #models)
		else Logger.warn(LOG, "Ollama model inventory is unavailable.") end
		if follow_mutation(frame) then return end
		frame.finishing = false
		if active == frame then active = nil end
		local published = cache
		if names and published and published.frame == frame and source_current(frame) and cache == published
			and type(changed) == "function" then
			local notified = pcall(changed)
			if not notified then Logger.error(LOG, "Model inventory notification raised.") end
		end
	end

	dispatch = function(frame)
		if not authorized(frame) then cancel_frame(frame); return end
		frame.constructing = true
		local endpoint = Bridge.ollama_endpoint(origin, "tags")
		if not endpoint or not authorized(frame) then frame.constructing = false; cancel_frame(frame); return end
		local ok, operation = pcall(get, endpoint, {}, {
			owner = OWNER, timeout_ms = 5000, follow_redirects = false, failure_log_level = "warn",
			authorized = function() return authorized(frame) end,
		}, function() finish(frame) end)
		if not ok then frame.unknown_debt, frame.revoked = true, true
		elseif not attach(frame, operation, true) then frame.revoked = true end
		frame.constructing = false
		if frame.http and frame.http.operation.started ~= true then frame.revoked = true end
		if frame.revoked then cancel_frame(frame) else finish(frame) end
	end

	request = function(frame)
		active, attempt, cache = frame, frame, nil
		frame.constructing = true
		local observed, instant = pcall(clock)
		if not observed or not authorized(frame) then frame.constructing = false; cancel_frame(frame); return end
		local ok, operation = pcall(defer, instant, function() frame.fired = true; finish(frame) end)
		if not ok then frame.unknown_debt, frame.revoked = true, true
		elseif not attach(frame, operation, false) then frame.revoked = true end
		frame.constructing = false
		if frame.deferred and frame.deferred.operation.started ~= true then frame.revoked = true end
		if frame.revoked then cancel_frame(frame) else finish(frame) end
	end

	local function project(explicit, cold, mutation)
		local invocation = {}
		reading = invocation
		local observed_cache, observed_attempt, observed_active = cache, attempt, active
		local ok, receipt = pcall(capture)
		local frame = { receipt = ok and receipt or nil }
		local function unchanged()
			return reading == invocation and cache == observed_cache and attempt == observed_attempt and active == observed_active
		end
		if not source_current(frame) or not unchanged() then return {} end
		local cached = observed_cache and source_current(observed_cache.frame)
		if not unchanged() then return {} end
		if not explicit and cached then return observed_cache.models end
		if not explicit and not cold then return {} end
		if observed_active then
			if mutation and authorized(observed_active) and unchanged() and source_current(frame) and unchanged() then
				-- Ordinary refreshes still coalesce. Installation instead requires an
				-- observation begun after the mutation, without releasing old debt.
				observed_active.after_mutation = observed_active.after_mutation or frame
				cache = nil
				finish(observed_active)
			end
			return cached and not mutation and observed_cache.models or {}
		end
		local tried = observed_attempt and source_current(observed_attempt)
		if not unchanged() or not source_current(frame) or not unchanged() then return {} end
		if not explicit and tried then return {} end
		request(frame)
		return {}
	end

	--- Returns the validated cache and reserves at most one cold acquisition.
	--- @return table models Immediate array projection.
	function owner.get() return project(false, true) end
	--- Returns only a validated cache; never starts acquisition.
	--- @return table models Immediate array projection.
	function owner.peek() return project(false, false) end
	--- Requests one coalesced explicit acquisition and returns immediately.
	--- @return table models Immediate array projection.
	function owner.refresh() return project(true, false) end
	--- Requests one fresh post-install observation after older retained work settles.
	--- @return table models Immediate unknown projection.
	function owner.refresh_after_mutation() return project(true, false, true) end
	--- Revokes publication before retiring the exact retained resources.
	--- @return boolean acknowledged Physical timer and HTTP cleanup.
	function owner.cancel()
		reading = nil
		cache = nil
		return not active or cancel_frame(active)
	end
	--- Reports pending construction or retained native cleanup ownership.
	--- @return boolean pending
	function owner.pending() return active ~= nil end
	return owner
end

return M
