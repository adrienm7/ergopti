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
local Utf8 = require("compat.utf8")

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

	local function capture(focus, authorized, callback, write, span)
		if active or (writing and writing ~= write) or stopped then callback(nil); return false end
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
		local deadline = write and write.deadline or Clock.now_ms() + Timings.ms("privacy", "atspi_probe_timeout_ms")
		if Clock.now_ms() >= deadline then active = nil; callback(nil); return false end
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
		}, { owner = native_owner, authorized = authorized_request, span = span,
			timeout_ms = deadline - Clock.now_ms() }, function(snapshot)
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

	--- Replaces through staged preparation, range verification and caret verification.
	--- @param receipt table Original opaque read receipt, consumed at dispatch.
	--- @param text string Private replacement bytes.
	--- @param authorized function Original action authority.
	--- @param construct function Pure constructor for the pinned selected output.
	--- @param callback function Receives boolean commit and private physical receipt.
	--- @param on_payload function|nil Invalidates document caches before the next await.
	--- @return boolean accepted
	function owner.replace_staged(receipt, text, authorized, construct, callback, on_payload)
		assert(type(callback) == "function", "selection replacement callback required")
		local held = receipts[receipt]
		local length = type(text) == "string" and Utf8.len(text)
		if not held or active or writing or stopped or not length or length == 0 or type(construct) ~= "function"
			or (on_payload ~= nil and type(on_payload) ~= "function") then callback(false); return false end
		local write = { generation = generation, revoked = false,
			deadline = Clock.now_ms() + Timings.ms("privacy", "atspi_probe_timeout_ms") }
		writing = write
		local function retained()
			return writing == write and not write.revoked and not stopped and generation == write.generation
				and Clock.now_ms() < write.deadline
		end
		local function abandon()
			write.revoked = true
			if writing == write then writing = nil end
			callback(false)
		end
		if not admitted(held.focus, authorized) or not retained() then abandon(); return false end
		local captured, field = pcall(capture_text_owner, held.focus)
		local current = captured and type(field) == "table" and getmetatable(field) == nil and rawget(field, "current")
		local cached = captured and type(field) == "table" and getmetatable(field) == nil and rawget(field, "cached")
		if type(current) ~= "function" or type(cached) ~= "function" or not retained() then abandon(); return false end
		local checking = false
		local function check(use_cached)
			if checking or not retained() then return false end
			checking = true
			local ok, allowed = pcall(function()
				return authorized() == true and retained() and (use_cached and cached or current)() == true
					and retained() and authorized() == true and cached() == true and retained()
			end)
			checking = false
			return ok and allowed == true and retained()
		end
		local publication = { current = function() return check(false) end, cached = function() return check(true) end }
		if not check(false) then abandon(); return false end
		receipts[receipt] = nil
		local built, stage = pcall(construct, text, publication)
		if not built or type(stage) ~= "table" or getmetatable(stage) ~= nil then
			write.revoked = true
			Logger.error("adapters.selection_transaction", "Selected output construction has inconclusive cleanup.")
			return false
		end
		local prepare, payload, reselect, close = rawget(stage, "prepare"), rawget(stage, "payload"), rawget(stage, "reselect"), rawget(stage, "close")
		if type(prepare) ~= "function" or type(payload) ~= "function" or type(reselect) ~= "function" or type(close) ~= "function" then
			write.revoked = true; return false
		end
		write.close = close
		local completed, payload_written, keys_clean = false, false, true
		local function finish(committed, result)
			if completed then return end
			completed = true
			local ok, cleaned = pcall(close)
			local allowed = committed == true and check(false)
			write.revoked, write.finished, write.native_clean = true, true, keys_clean
			cleaned = ok and cleaned == true and keys_clean
			if cleaned and writing == write then writing = nil end
			local receipt_result = { ok = allowed and cleaned, cleanup_ok = cleaned, payload_written = payload_written,
				failed_phase = result and result.failed_phase or "selection observation" }
			if payload_written and not receipt_result.ok then
				Logger.warn("adapters.selection_transaction", "Selected payload may have been written; final selection could not be committed.")
			end
			callback(receipt_result.ok == true, receipt_result)
		end
		if not check(false) then finish(false); return true end
		local ok, ready = pcall(prepare)
		if not ok or ready ~= true or not check(false) then finish(false); return true end
		local original = held.snapshot
		capture(held.focus, publication.current, function(observed)
			if not observed or observed.bus ~= original.bus or observed.path ~= original.path or observed.role ~= original.role
				or observed.first ~= original.first or observed.last ~= original.last or observed.text ~= original.text
				or not check(false) then finish(false); return end
			local emitted, result = pcall(payload)
			local valid = emitted and type(result) == "table" and getmetatable(result) == nil
			payload_written = valid and rawget(result, "payload_written") == true
			keys_clean = valid and rawget(result, "native_cleanup_ok") == true
			local notified = true
			if payload_written and on_payload then notified = pcall(on_payload) end
			if not notified or not keys_clean or rawget(result, "ok") ~= true or not check(false) then finish(false, valid and result); return end
			local span = { first = original.first, last = original.first + length }
			capture(held.focus, publication.current, function(inserted)
				if not inserted or inserted.bus ~= original.bus or inserted.path ~= original.path or inserted.role ~= original.role
					or inserted.first ~= span.first or inserted.last ~= span.last or inserted.text ~= text
					or not check(false) then finish(false); return end
				local selected, final = pcall(reselect)
				local final_valid = selected and type(final) == "table" and getmetatable(final) == nil
				keys_clean = keys_clean and final_valid and rawget(final, "native_cleanup_ok") == true
				finish(keys_clean and rawget(final, "ok") == true, final_valid and final)
			end, write, span)
		end, write)
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

	--- Revokes range and write authority while retaining physical cleanup ownership.
	--- @return boolean settled
	function owner.cancel()
		-- An idle read is an immutable observation, not action authority. A new
		-- translation may revalidate it after cancelling a superseded tone step.
		generation = generation + 1
		if writing then writing.revoked = true end
		if writing and writing.close then
			local write = writing
			local ok, cleaned = pcall(write.close)
			-- A cleanup ACK may arrive after the admission deadline. It retires
			-- only an unwound frame with known wire cleanup, never an active await.
			if ok and cleaned == true and write.finished and write.native_clean and not active and writing == write then writing = nil end
		end
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
