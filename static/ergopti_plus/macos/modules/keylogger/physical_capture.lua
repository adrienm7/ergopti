--- modules/keylogger/physical_capture.lua

--- Owns one dormant physical capture session and its exact native task lifetime.
--- A trusted owned-runtime caller must explicitly initialize and start this port.
--- Default boot does not require it. Clock, preparation, retained context and
--- recovery belong to the future runtime owner; this session never retries.
local M = {}
local Logger = require("infra.logger")
local Accounting = require("modules.keylogger.physical_accounting_mode")
local Delivery = require("modules.keylogger.physical_delivery")
local Transport = require("modules.keylogger.physical_transport")
local Protocol = require("modules.keylogger.physical_protocol")
local Wire = require("modules.keylogger.physical_wire")
local LOG = "keylogger.physical_capture"
local OWNER = "modules.keylogger.physical_capture"
local dependencies, session

--- Reports whether a native session still belongs to this singleton owner.
---@param candidate table Captured session identity.
---@return boolean current
local function current(candidate) return session == candidate end

--- Fences callback cancellation until one exact accounting publication unwinds.
---@param candidate table Captured session identity.
---@param operation function Accounting owner's transition port.
---@return boolean accepted
local function accounting_transition(candidate, operation, ...)
	assert(not candidate.accounting_transition, "Physical accounting transition is pending")
	candidate.accounting_transition = true
	local results = table.pack(pcall(operation, ...))
	candidate.accounting_transition = false
	if not results[1] then error(results[2], 0) end
	return table.unpack(results, 2, results.n)
end

--- Revokes credits before awaiting any task termination or successor.
---@param candidate table Captured session identity.
---@return boolean interrupted
local function revoke(candidate)
	if candidate.receiver then candidate.receiver.stop() end
	if candidate.capture then
		if accounting_transition(candidate, Accounting.interrupt, OWNER, candidate.capture) ~= true then return false end
		candidate.capture = nil
	end
	return true
end

--- Retires accounting only when every exact native child has settled.
---@param candidate table Captured session identity.
---@return boolean settled
local function finish_stop(candidate)
	if not current(candidate) or not candidate.stop_requested or candidate.acquiring
		or candidate.accounting_transition then return false end
	if candidate.state == "stopped" then return true end
	if candidate.verifier and not candidate.verifier_settled then return false end
	if candidate.transport and not candidate.transport.isSettled() then return false end
	if candidate.accounting_owned then
		if accounting_transition(candidate, Accounting.release, OWNER) ~= true then return false end
		candidate.accounting_owned = false
	end
	candidate.state = "stopped"
	Logger.success(LOG, "Physical capture session stopped.")
	return true
end

--- Publishes one terminal verdict without retrying or returning to legacy input.
---@param candidate table Captured session identity.
---@param message string Diagnostic explanation.
---@param failure any Original producer failure, if available.
local function failed(candidate, message, failure)
	if not current(candidate) or candidate.stop_requested or candidate.failure then return end
	candidate.failure = message
	local unavailable = Protocol.is_unavailable(failure)
	candidate.state = unavailable and "unavailable" or "failed"
	candidate.reason = unavailable and failure.code or "capture_failed"
	if not revoke(candidate) then
		Logger.error(LOG, "Physical capture accounting settlement remains pending.")
	end
	if unavailable then
		Logger.warn(LOG, "Physical capture unavailable (%s): %s.", candidate.reason, message)
	else
		Logger.error(LOG, "Physical capture failed: %s.", message)
	end
end

--- Converts identity failure into the same typed unavailable verdict as admission.
---@param candidate table Captured session identity.
---@param code string Explicit refusal reason.
---@param message string Diagnostic explanation.
local function unavailable(candidate, code, message)
	local _, failure = pcall(Protocol.unavailable, code, message)
	failed(candidate, message, failure)
end

--- Creates and starts the stream only after verified native identity settlement.
---@param candidate table Captured session identity.
local function start_stream(candidate)
	if not current(candidate) or candidate.stop_requested or candidate.failure then return end
	if not candidate.verifier_observed or not candidate.verifier_settled
		or candidate.verifier_start_accepted ~= true or candidate.verifier_starting then return end
	if not candidate.verifier_completed then
		unavailable(candidate, "identity_verification_incomplete", "Owned identity task settled without a completion verdict")
		return
	end
	if candidate.verification_exit ~= 0 then
		unavailable(candidate, "identity_verification_refused", "Owned capture executable identity was refused")
		return
	end
	if candidate.transport then return end
	candidate.state = "opening"
	candidate.transport = Transport.new({ receiver = candidate.receiver,
		frame_limit = candidate.options.frame_limit,
		spawn = dependencies.spawn, decode = dependencies.decode, encode = dependencies.encode,
		on_error = function(message, failure) failed(candidate, message, failure) end,
		on_settled = function() if candidate.stop_requested then finish_stop(candidate) end end,
	})
	candidate.transport.start(candidate.options.executable, candidate.options.arguments)
end

--- Contains callbacks whose errors would otherwise escape through native dispatch.
---@param candidate table Captured session identity.
---@param operation function Internal publication operation.
local function guarded(candidate, operation)
	local ok, failure = pcall(operation)
	if not ok then failed(candidate, tostring(failure), failure) end
end

--- Registers one settlement observer, independently of native completion status.
---@param candidate table Captured session identity.
local function observe_verifier(candidate)
	if candidate.verifier_observed then return end
	local accepted = candidate.verifier.onSettled(function()
		if not current(candidate) or candidate.verifier_settled then return end
		candidate.verifier_settled = true
		guarded(candidate, function()
			if candidate.stop_requested then finish_stop(candidate) else start_stream(candidate) end
		end)
	end)
	assert(accepted == true, "Physical identity settlement observer refused")
	candidate.verifier_observed = true
end

--- Validates and copies pending native arguments so callers cannot change their target.
---@param options table Explicit executable, arguments, pinned requirement and limits.
---@return table snapshot
local function snapshot_options(options)
	assert(type(options) == "table", "Missing physical capture options")
	assert(type(options.executable) == "string" and options.executable:sub(1, 1) == "/"
		and not options.executable:find("[%z\r\n]"), "Physical capture requires an absolute executable")
	assert(type(options.requirement) == "string" and options.requirement ~= ""
		and not options.requirement:find("[%z\r\n]"), "Missing pinned physical executable requirement")
	local count = Wire.array(options.arguments, 0, 256)
	local arguments = {}
	for index = 1, count do
		assert(type(options.arguments[index]) == "string" and not options.arguments[index]:find("%z"),
			"Invalid physical capture argument")
		arguments[index] = options.arguments[index]
	end
	for _, name in ipairs({ "batch_limit", "frame_limit" }) do
		assert(type(options[name]) == "number" and options[name] >= 1 and options[name] % 1 == 0,
			"Invalid physical capture " .. name)
	end
	return { executable = options.executable, arguments = arguments, requirement = options.requirement,
		batch_limit = options.batch_limit, frame_limit = options.frame_limit }
end

--- Binds the native ports once without acquiring tasks or changing accounting.
--- The caller owns retained privacy/time context and the acknowledged log sink.
---@param ports table spawn, decode, encode, context, keycode and emit callbacks.
---@return boolean initialized
function M.init(ports)
	if dependencies then return false end
	assert(type(ports) == "table", "Missing physical capture native ports")
	local snapshot = {}
	for _, name in ipairs({ "spawn", "decode", "encode", "context", "keycode", "emit" }) do
		assert(type(ports[name]) == "function", "Missing physical capture port: " .. name)
		snapshot[name] = ports[name]
	end
	Logger.start(LOG, "Initializing dormant physical capture owner…")
	dependencies = snapshot
	Logger.success(LOG, "Dormant physical capture owner initialized.")
	return true
end

--- Starts one explicit session after asynchronous pinned-identity verification.
--- The requirement must come from the trusted runtime artifact owner, not user input.
---@param options table Executable, arguments, requirement, batch_limit and frame_limit.
---@return boolean accepted False while an earlier owner or native task is retained.
function M.start(options)
	assert(dependencies, "Physical capture owner is not initialized")
	if session and session.state ~= "stopped" then return false end
	local candidate = { state = "verifying", options = snapshot_options(options), acquiring = true }
	candidate.receiver = Delivery.new({ batch_limit = candidate.options.batch_limit,
		admit = function(frame)
			assert(current(candidate) and candidate.state == "opening", "Physical capture admission was revoked")
			if frame.coverage ~= Accounting.COMPLETE_COVERAGE then
				Protocol.unavailable("incomplete_coverage", "Physical producer coverage is not complete")
			end
			local capture = frame.incarnation .. "/" .. frame.lease
			assert(accounting_transition(candidate, Accounting.admit, OWNER, capture, frame.coverage) == true,
				"Physical accounting admission refused")
			candidate.capture = capture
			-- Settlement may have latched stop before the accounting owner committed.
			-- Attach that exact obligation and retire it after the publication unwinds.
			if not current(candidate) or candidate.state ~= "opening" or candidate.stop_requested or candidate.failure then
				assert(revoke(candidate), "Physical accounting admission revocation refused")
				error("Physical capture admission was revoked")
			end
			candidate.state = "capturing"
			return capture
		end,
		context = dependencies.context, keycode = dependencies.keycode,
		emit = function(press)
			assert(current(candidate) and candidate.state == "capturing"
				and Accounting.admitted_capture() == press.capture, "Physical capture publication was revoked")
			return dependencies.emit(press)
		end,
	})
	local previous = session
	session = candidate
	local selected, accepted = pcall(accounting_transition, candidate, Accounting.select_stream, OWNER)
	if not selected or accepted ~= true then
		candidate.receiver.stop()
		session = previous
		if not selected then error(accepted, 0) end
		return false
	end
	candidate.accounting_owned = true
	if candidate.stop_requested then
		candidate.acquiring = false
		finish_stop(candidate)
		return false
	end
	Logger.info(LOG, "Physical capture session verifying its owned executable.")
	if candidate.stop_requested then
		candidate.acquiring = false
		finish_stop(candidate)
		return false
	end
	local ok, failure = pcall(function()
		candidate.verifier = dependencies.spawn("/usr/bin/codesign",
			{ "--verify", "--strict", "-R", "=" .. candidate.options.requirement, candidate.options.executable },
			function(code)
				if not current(candidate) or candidate.verifier_completed then return end
				candidate.verifier_completed, candidate.verification_exit = true, code
				guarded(candidate, function() start_stream(candidate) end)
			end)
		candidate.acquiring = false
		assert(type(candidate.verifier) == "table", "Physical identity task was not created")
		observe_verifier(candidate)
		if candidate.stop_requested then
			if not candidate.verifier_settled then candidate.verifier.terminate() end
			finish_stop(candidate)
			return
		end
		assert(not candidate.verifier_settled, "Physical identity task settled before start")
		candidate.verifier_starting = true
		local started = candidate.verifier.start()
		candidate.verifier_start_accepted = started == true
		candidate.verifier_starting = false
		assert(started == true, "Physical identity task start failed")
		start_stream(candidate)
	end)
	candidate.acquiring = false
	if not ok then
		failed(candidate, tostring(failure), failure)
		if candidate.verifier and not candidate.verifier_settled then
			pcall(candidate.verifier.terminate)
		elseif candidate.stop_requested then finish_stop(candidate) end
	end
	return candidate.state == "verifying" or candidate.state == "opening" or candidate.state == "capturing"
end

--- Revokes delivery immediately; accepted termination alone cannot release ownership.
--- Repeated calls retry only the same retained child, never start a replacement.
---@return boolean settled True only after exact native settlement and accounting release.
---@return string|nil status Pending while an exact child or settlement refusal remains.
function M.stop()
	if not session or session.state == "stopped" then return true end
	local candidate = session
	if not candidate.stop_requested then
		candidate.stop_requested, candidate.state = true, "stopping"
		Logger.start(LOG, "Stopping physical capture session…")
	end
	if candidate.receiver then candidate.receiver.stop() end
	if candidate.accounting_transition or candidate.acquiring then return false, "pending" end
	if revoke(candidate) ~= true then return false, "settlement_refused" end
	local ok, failure = pcall(function()
		if candidate.transport and not candidate.transport.isSettled() then candidate.transport.stop() end
		if candidate.verifier and not candidate.verifier_settled then
			observe_verifier(candidate)
			candidate.verifier.terminate()
		end
	end)
	if not ok then Logger.error(LOG, "Physical capture native stop remains pending: %s.", tostring(failure)) end
	if candidate.state == "stopped" or finish_stop(candidate) then return true end
	return false, "pending"
end

--- Returns an independent diagnostic snapshot, never live native ownership tables.
---@return table status State, explicit reason and actual settlement verdict.
function M.status()
	if not session then return { state = dependencies and "idle" or "uninitialized", settled = true } end
	local settled = not session.acquiring and not session.accounting_transition
		and (not session.verifier or session.verifier_settled == true)
		and (not session.transport or session.transport.isSettled())
	return { state = session.state, reason = session.reason, settled = settled }
end

return M
