--- adapters/selection_transaction.lua

--- ==============================================================================
--- MODULE: Native Selection Transaction (Linux)
--- DESCRIPTION:
--- Captures an opaque selected-range receipt through an owned cold helper and
--- revalidates its native field, offsets and text before physical replacement.
--- No selected text is stored in the resident privacy worker or clipboard.
--- ==============================================================================

local M = {}
local Atspi = require("adapters.atspi_focus")
local Timings = require("infra.timings")
local Clock = require("infra.monotonic")
local Logger = require("logger.shim")

--- Creates one explicit-action selection owner without loading native libraries.
--- @param options table Live focus and privacy admission callbacks.
--- @return table owner
function M.new(options)
	assert(type(options) == "table" and type(options.focus_id) == "function"
		and type(options.privacy_guard) == "function", "selection admission callbacks required")
	local owner, active, stopped = {}, nil, false
	local receipts = setmetatable({}, { __mode = "k" })
	local native_owner = "selection:" .. tostring(owner)

	local function admitted(focus, authorized)
		if stopped or type(authorized) ~= "function" then return false end
		local ok, allowed = pcall(authorized)
		if not ok or allowed ~= true or stopped then return false end
		local checked, blocked = pcall(options.privacy_guard)
		if not checked or blocked ~= false or stopped then return false end
		local identified, current = pcall(options.focus_id)
		if not identified or current ~= focus or focus == "" or stopped then return false end
		ok, allowed = pcall(authorized)
		return ok and allowed == true and not stopped
	end

	local function settled(request)
		local operation = request.operation
		if type(operation) ~= "table" or type(operation.is_settled) ~= "function" then return false end
		local ok, done = pcall(operation.is_settled, operation)
		return ok and done == true
	end

	local function retire(request)
		request.revoked, request.snapshot = true, nil
		local operation = request.operation
		if type(operation) == "table" and type(operation.cancel) == "function" then pcall(operation.cancel, operation) end
		if request.inconclusive then return false end
		if settled(request) then return true end
		return false
	end

	local function capture(focus, authorized, callback)
		if active or stopped then callback(nil); return false end
		local request = { revoked = false, dispatching = true }
		active = request
		local function authorized_request()
			if active ~= request or request.revoked then return false end
			local checked, allowed = pcall(authorized)
			return checked and allowed == true and active == request and not request.revoked and not stopped
		end
		if not admitted(focus, authorized) or not authorized_request() then active = nil; callback(nil); return false end
		local field = Atspi.cached_snapshot()
		if not field or type(field.native_bus_name) ~= "string" or type(field.native_object_path) ~= "string"
			or "atspi:" .. field.native_bus_name .. ":" .. field.native_object_path ~= focus then
			active = nil; callback(nil); return false
		end
		local deadline = Clock.now_ms() + Timings.ms("privacy", "atspi_probe_timeout_ms")
		local function complete()
			if request.dispatching or request.inconclusive or request.completed or not settled(request) then return end
			request.completed = true
			local snapshot = not request.revoked and Clock.now_ms() <= deadline and request.snapshot or nil
			request.snapshot = nil
			if snapshot and (not admitted(focus, authorized) or not authorized_request()) then snapshot = nil end
			if active == request then active = nil end
			callback(snapshot)
		end
		local ok, operation = pcall(Atspi.start_selection_capture, {
			bus = field.native_bus_name, path = field.native_object_path, role = field.role,
		}, { owner = native_owner, authorized = authorized_request }, function(snapshot)
			if authorized_request() then request.snapshot = snapshot end
		end)
		if not ok then
			request.inconclusive, request.revoked, request.snapshot = true, true, nil
			Logger.error("adapters.selection_transaction", "Selection dispatch threw; native ownership remains inconclusive.")
			return false
		end
		if operation == nil then active = nil; callback(nil); return false end
		request.operation = operation
		if type(operation) ~= "table" or type(operation.on_settled) ~= "function" or type(operation.cancel) ~= "function"
			or type(operation.is_settled) ~= "function" then
			request.inconclusive = true
			retire(request)
			return false
		end
		local registered, accepted = pcall(operation.on_settled, operation, complete)
		if not registered or accepted ~= true then
			request.inconclusive = true
			retire(request)
			return false
		end
		request.dispatching = false
		if request.revoked or stopped then retire(request) end
		complete()
		return true
	end

	--- Starts a read; accepted dispatch is not a completed native observation.
	--- @param focus string Exact admitted native field token.
	--- @param authorized function Originating action remains current.
	--- @param callback function Receives success, text, reason and opaque receipt.
	--- @return boolean accepted Workflow accepted; completion requires callback.
	function owner.read(focus, authorized, callback)
		assert(type(callback) == "function", "selection read callback required")
		return capture(focus, authorized, function(snapshot)
			if not snapshot then callback(false, "", "selection_unavailable"); return end
			local receipt = {}
			receipts[receipt] = { focus = focus, snapshot = snapshot }
			callback(true, snapshot.text, nil, receipt)
		end)
	end

	--- Revalidates a range and reports commit only after the physical ACK.
	--- @param receipt table Opaque receipt returned by read().
	--- @param text string Replacement.
	--- @param authorized function Originating action remains current.
	--- @param emit function Physical injector returning its structured receipt.
	--- @param callback function Receives literal true only for a committed edit.
	--- @return boolean accepted Workflow accepted; completion requires callback.
	function owner.replace(receipt, text, authorized, emit, callback)
		assert(type(callback) == "function", "selection replacement callback required")
		local held = receipts[receipt]
		if not held or active or type(text) ~= "string" or text == "" or type(emit) ~= "function" then callback(false); return false end
		return capture(held.focus, authorized, function(observed)
			local original = held.snapshot
			if not observed or observed.bus ~= original.bus or observed.path ~= original.path or observed.role ~= original.role
				or observed.first ~= original.first or observed.last ~= original.last or observed.text ~= original.text
				or receipts[receipt] ~= held or not admitted(held.focus, authorized) then callback(false); return end
			-- Consume before calling the injector: a nested accept cannot reuse it.
			receipts[receipt] = nil
			local ok, result = pcall(emit, text)
			callback(ok and type(result) == "table" and result.ok == true)
		end)
	end

	--- Revokes a pending operation while retaining physical cleanup ownership.
	--- @return boolean settled
	function owner.cancel()
		return not active or retire(active)
	end

	--- Reports whether this owner retains any native operation or dispatch frame.
	--- @return boolean settled
	function owner.is_settled() return active == nil end

	--- Revokes all range authority and acknowledges only physical settlement.
	--- @return boolean settled
	function owner.stop()
		stopped = true
		receipts = setmetatable({}, { __mode = "k" })
		return not active or retire(active)
	end

	return owner
end

return M
