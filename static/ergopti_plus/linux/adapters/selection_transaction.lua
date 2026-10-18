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
--- @param options table Live focus, privacy and capture_text_owner callbacks.
--- @return table owner
function M.new(options)
	assert(type(options) == "table" and type(options.focus_id) == "function"
		and type(options.privacy_guard) == "function", "selection admission callbacks required")
	local owner, active, writing, stopped, generation = {}, nil, nil, false, 0
	local capture_text_owner = options.capture_text_owner
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
		if active or writing or stopped then callback(nil); return false end
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
	--- @param emit function emit(text, publication) returns its physical cleanup receipt.
	--- @param callback function Receives literal true only for a committed edit.
	--- @return boolean accepted Workflow accepted; completion requires callback.
	function owner.replace(receipt, text, authorized, emit, callback)
		assert(type(callback) == "function", "selection replacement callback required")
		local held = receipts[receipt]
		if not held or active or writing or stopped or type(text) ~= "string" or text == "" or type(emit) ~= "function" then callback(false); return false end
		return capture(held.focus, authorized, function(observed)
			local original = held.snapshot
			if not observed or observed.bus ~= original.bus or observed.path ~= original.path or observed.role ~= original.role
				or observed.first ~= original.first or observed.last ~= original.last or observed.text ~= original.text
				or receipts[receipt] ~= held then callback(false); return end
			-- Reserve before callbacks: the native capture has settled, but the
			-- physical writer and its cleanup have not acquired an ACK yet.
			local write = { generation = generation, revoked = false }
			writing = write
			local function retained()
				return writing == write and not write.revoked and not stopped and generation == write.generation
			end
			local admitted_write = retained() and admitted(held.focus, authorized) and retained()
			local captured, field = false, nil
			if admitted_write and type(capture_text_owner) == "function" then
				captured, field = pcall(capture_text_owner, held.focus)
			end
			local current = captured and type(field) == "table" and getmetatable(field) == nil and rawget(field, "current") or nil
			local cached = captured and type(field) == "table" and getmetatable(field) == nil and rawget(field, "cached") or nil
			if type(current) ~= "function" or type(cached) ~= "function" or not retained()
				or not admitted(held.focus, authorized) or not retained() then
				if writing == write then writing = nil end
				callback(false); return
			end
			local checking = false
			local function check(use_cached)
				if checking or not retained() then return false end
				checking = true
				local ok, allowed = pcall(function()
					if authorized() ~= true or not retained() then return false end
					if (use_cached and cached or current)() ~= true or not retained() then return false end
					if authorized() ~= true or not retained() then return false end
					return cached() == true and retained()
				end)
				checking = false
				return ok and allowed == true and retained()
			end
			local publication = { current = function() return check(false) end, cached = function() return check(true) end }
			if not check(false) then
				if writing == write then writing = nil end
				callback(false); return
			end
			-- A consumed read receipt never becomes the private write lease.
			receipts[receipt] = nil
			local ok, result = pcall(emit, text, publication)
			-- Injector.cleanup_ok covers native keys/modifiers. Clipboard restore
			-- has its own canonical failed phase and must remain physical debt.
			local cleaned = ok and type(result) == "table" and getmetatable(result) == nil
				and rawget(result, "cleanup_ok") == true and rawget(result, "failed_phase") ~= "clipboard restoration"
			local committed = cleaned and rawget(result, "ok") == true and check(false)
			write.revoked = true
			if cleaned and writing == write then writing = nil end
			callback(committed == true)
		end)
	end

	--- Revokes range and write authority while retaining physical cleanup ownership.
	--- @return boolean settled
	function owner.cancel()
		-- An idle read is an immutable observation, not action authority. A new
		-- translation may revalidate it after cancelling a superseded tone step.
		generation = generation + 1
		if writing then writing.revoked = true end
		local native_settled = not active or retire(active)
		return not writing and native_settled
	end

	--- Reports whether this owner retains any native operation or dispatch frame.
	--- @return boolean settled
	function owner.is_settled() return active == nil and writing == nil end

	--- Revokes all range authority and acknowledges only physical settlement.
	--- @return boolean settled
	function owner.stop()
		stopped = true
		receipts = setmetatable({}, { __mode = "k" })
		return owner.cancel()
	end

	return owner
end

return M
