--- modules/keylogger/physical_capture.lua

--- Owns one dormant physical capture session and its exact native task lifetime.
--- A trusted owned-runtime caller must explicitly initialize and start this port.
--- Default boot does not require it. The context owner explicitly accepts the
--- native clock; preparation/status/open remain in one capture process. Retained
--- context and recovery belong to the future runtime owner; this never retries.
local M = {}
local Logger = require("infra.logger")
local Accounting = require("modules.keylogger.physical_accounting_mode")
local Delivery = require("modules.keylogger.physical_delivery")
local Transport = require("modules.keylogger.physical_transport")
local Protocol = require("modules.keylogger.physical_protocol")
local Wire = require("modules.keylogger.physical_wire")
local Clock = require("modules.keylogger.physical_clock")
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

--- Completes the one retained notification after this exact session retires.
--- Detach before external dispatch so callback reentry cannot replay the receipt.
---@param candidate table Captured session identity whose stop is committed.
local function notify_stop(candidate)
	local observer = candidate.stop_observer
	if not observer then return end
	candidate.stop_observer = nil
	local ok, failure = xpcall(function() observer(true) end, debug.traceback)
	if not ok then Logger.error(LOG, "Physical capture stop observer failed: %s.", tostring(failure)) end
end

--- Retires accounting only when every exact native child has settled.
---@param candidate table Captured session identity.
---@return boolean settled
local function finish_stop(candidate)
	if not current(candidate) or not candidate.stop_requested or candidate.acquiring
		or candidate.accounting_transition or candidate.clock_starting or candidate.clock_publishing
		or candidate.baseline_publishing or candidate.baseline_revocation_pending then return false end
	if candidate.state == "stopped" then return true end
	if candidate.verifier and not candidate.verifier_settled then return false end
	if candidate.clock and not candidate.clock_settled then return false end
	if candidate.transport and not candidate.transport.isSettled() then return false end
	if candidate.accounting_owned then
		if accounting_transition(candidate, Accounting.release, OWNER) ~= true then return false end
		candidate.accounting_owned = false
	end
	candidate.state = "stopped"
	Logger.success(LOG, "Physical capture session stopped.")
	notify_stop(candidate)
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

--- Creates the one native prepare/status/open process after clock ownership.
---@param candidate table Captured session identity.
local function start_stream(candidate)
	if not current(candidate) or candidate.stop_requested or candidate.failure then return end
	if candidate.clock_published ~= true then return end
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

--- Transfers a validated timebase only after the exact successful worker retires.
---@param candidate table Captured session identity.
local function publish_clock(candidate)
	if not current(candidate) or candidate.stop_requested or candidate.failure or candidate.clock_published
		or candidate.clock_publishing or candidate.acquiring or candidate.clock_starting then return end
	if not candidate.clock_observed or not candidate.clock_settled or candidate.clock_start_accepted ~= true then return end
	if not candidate.clock_completed then
		unavailable(candidate, "clock_incomplete", "Native clock task settled without a completion verdict")
		return
	end
	if candidate.clock_exit ~= 0 then
		unavailable(candidate, "clock_command_refused", "Owned capture executable could not provide its native clock")
		return
	end
	local ok, information, convert = pcall(function()
		assert(type(candidate.clock_output) == "string" and #candidate.clock_output <= 1024,
			"Invalid physical clock output")
		local receipt, decode_error = dependencies.decode(candidate.clock_output)
		assert(decode_error == nil and type(receipt) == "table", decode_error or "Invalid physical clock JSON")
		Protocol.require_version("clock", receipt.version, 1)
		Wire.fields(receipt, { "version", "domain", "numer", "denom" })
		local snapshot = { version = receipt.version, domain = receipt.domain, numer = receipt.numer, denom = receipt.denom }
		return snapshot, Clock.new(snapshot)
	end)
	if not ok then
		if Protocol.is_unavailable(information) then failed(candidate, tostring(information), information)
		else unavailable(candidate, "invalid_clock", tostring(information)) end
		return
	end
	if candidate.stop_requested then finish_stop(candidate); return end
	if not current(candidate) or candidate.failure then return end
	local owned_information = { version = information.version, domain = information.domain,
		numer = information.numer, denom = information.denom }
	-- External context publication may request stop. Keep accounting ownership
	-- until the callback unwinds, and revalidate before granting stream authority.
	candidate.clock_publishing = true
	local published, accepted = pcall(dependencies.clock_ready, information, convert)
	candidate.clock_publishing = false
	if candidate.stop_requested then finish_stop(candidate); return end
	if not current(candidate) or candidate.failure then return end
	if not published or accepted ~= true then
		unavailable(candidate, "clock_context_refused", "Context owner refused the validated native clock")
		return
	end
	candidate.clock_published, candidate.convert, candidate.clock_information = true, convert, owned_information
	start_stream(candidate)
end

--- Observes exact retirement independently of the clock's success callback.
---@param candidate table Captured session identity.
local function observe_clock(candidate)
	if candidate.clock_observed then return end
	local accepted = candidate.clock.onSettled(function()
		if not current(candidate) or candidate.clock_settled then return end
		candidate.clock_settled = true
		guarded(candidate, function()
			if candidate.stop_requested then finish_stop(candidate) else publish_clock(candidate) end
		end)
	end)
	assert(accepted == true, "Physical clock settlement observer refused")
	candidate.clock_observed = true
end

--- Starts the existing clock CLI only after pinned identity success and retirement.
---@param candidate table Captured session identity.
local function start_clock(candidate)
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
	if candidate.clock_attempted then return end
	candidate.clock_attempted, candidate.acquiring, candidate.state = true, true, "clocking"
	local ok, failure = pcall(function()
		candidate.clock = dependencies.spawn(candidate.options.executable, { "--hs274-clock" }, function(code, stdout)
			if not current(candidate) or candidate.clock_completed then return end
			candidate.clock_completed, candidate.clock_exit, candidate.clock_output = true, code, stdout
			guarded(candidate, function() publish_clock(candidate) end)
		end)
		candidate.acquiring = false
		assert(type(candidate.clock) == "table", "Physical clock task was not created")
		observe_clock(candidate)
		if candidate.stop_requested then
			if not candidate.clock_settled then candidate.clock.terminate() end
			finish_stop(candidate)
			return
		end
		assert(not candidate.clock_settled, "Physical clock task settled before start")
		candidate.clock_starting = true
		local started = candidate.clock.start()
		candidate.clock_start_accepted = started == true
		candidate.clock_starting = false
		assert(started == true, "Physical clock task start failed")
		if candidate.stop_requested then finish_stop(candidate) else publish_clock(candidate) end
	end)
	candidate.acquiring, candidate.clock_starting = false, false
	if not ok then
		unavailable(candidate, "clock_start_refused", tostring(failure))
		if candidate.clock and not candidate.clock_settled then pcall(candidate.clock.terminate) end
		if candidate.stop_requested then finish_stop(candidate) end
	end
end

--- Registers one settlement observer, independently of native completion status.
---@param candidate table Captured session identity.
local function observe_verifier(candidate)
	if candidate.verifier_observed then return end
	local accepted = candidate.verifier.onSettled(function()
		if not current(candidate) or candidate.verifier_settled then return end
		candidate.verifier_settled = true
		guarded(candidate, function()
			if candidate.stop_requested then finish_stop(candidate) else start_clock(candidate) end
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
--- clock_ready(information, convert) must return literal true after accepting the
--- native timebase; context still resolves original ticks through that owner.
--- context_interval(first_ticks, last_ticks, device) must resolve the entire
--- retained interval; emit_release transfers the approved match to its FIFO.
--- Optional baseline_ready() observes actual completed admission before any raw batch.
--- It receives no identity payload and must acknowledge with literal true.
---@param ports table spawn, decode, encode, clock_ready, context, context_interval, keycode, emit and emit_release; optional baseline_ready.
---@return boolean initialized
function M.init(ports)
	if dependencies then return false end
	assert(type(ports) == "table", "Missing physical capture native ports")
	local snapshot = {}
	for _, name in ipairs({ "spawn", "decode", "encode", "clock_ready", "context", "context_interval",
		"keycode", "emit", "emit_release" }) do
		assert(type(ports[name]) == "function", "Missing physical capture port: " .. name)
		snapshot[name] = ports[name]
	end
	local baseline_ready = rawget(ports, "baseline_ready")
	assert(baseline_ready == nil or type(baseline_ready) == "function", "Invalid physical baseline observer")
	snapshot.baseline_ready = baseline_ready
	Logger.start(LOG, "Initializing dormant physical capture owner…")
	dependencies = snapshot
	Logger.success(LOG, "Dormant physical capture owner initialized.")
	return true
end

--- Starts one explicit session with asynchronous pinned identity and native clock.
--- The requirement must come from the trusted runtime artifact owner, not user input.
---@param options table Executable, arguments, requirement, batch_limit and frame_limit.
---@return boolean accepted False while an earlier owner or native task is retained.
function M.start(options)
	assert(dependencies, "Physical capture owner is not initialized")
	if session and (session.state ~= "stopped" or session.history_binding ~= nil) then return false end
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
		baseline_ready = dependencies.baseline_ready and function()
			local original_capture = candidate.capture
			assert(current(candidate) and candidate.state == "capturing" and not candidate.stop_requested
				and not candidate.failure and candidate.clock_published and original_capture ~= nil
				and Accounting.admitted_capture() == original_capture and candidate.receiver.ready() == true,
				"Physical baseline completion owner was revoked")
			candidate.baseline_publishing = true
			local published, accepted = pcall(dependencies.baseline_ready)
			candidate.baseline_publishing = false
			if candidate.stop_requested then
				-- The owning Transport dispatch will terminate its revoked receiver once.
				-- Keep an explicit refused accounting obligation through native settlement.
				candidate.baseline_revocation_pending = true
				if revoke(candidate) then
					candidate.baseline_revocation_pending = nil
					finish_stop(candidate)
				end
			end
			if not published then error(accepted, 0) end
			assert(current(candidate) and candidate.state == "capturing" and not candidate.stop_requested
				and not candidate.failure and candidate.capture == original_capture
				and Accounting.admitted_capture() == original_capture and candidate.receiver.ready() == true,
				"Physical baseline completion was revoked")
			return accepted
		end,
		context = dependencies.context, keycode = dependencies.keycode,
		emit = function(press)
			assert(current(candidate) and candidate.state == "capturing"
				and Accounting.admitted_capture() == press.capture, "Physical capture publication was revoked")
			return dependencies.emit(press)
		end,
		holds = {
			convert = function(ticks)
				assert(current(candidate) and candidate.state == "capturing" and candidate.clock_published,
					"Physical hold clock was revoked")
				return candidate.convert(ticks)
			end,
			context = dependencies.context_interval,
			emit = function(release)
				assert(current(candidate) and candidate.state == "capturing"
					and Accounting.admitted_capture() == release.capture, "Physical capture publication was revoked")
				return dependencies.emit_release(release)
			end,
		},
	})
	local previous = session
	session = candidate
	local selected, accepted = pcall(accounting_transition, candidate, Accounting.select_stream, OWNER)
	if not selected or accepted ~= true then
		candidate.receiver.stop()
		candidate.acquiring = false
		session = previous
		-- A stop latched inside refused selection still owns its notification,
		-- but no accounting source or native child was acquired to release.
		if candidate.stop_requested then
			candidate.state = "stopped"
			Logger.success(LOG, "Physical capture session stopped.")
			notify_stop(candidate)
		end
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
				guarded(candidate, function() start_clock(candidate) end)
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
		start_clock(candidate)
	end)
	candidate.acquiring = false
	if not ok then
		failed(candidate, tostring(failure), failure)
		if candidate.verifier and not candidate.verifier_settled then
			pcall(candidate.verifier.terminate)
		elseif candidate.stop_requested then finish_stop(candidate) end
	end
	return candidate.state == "verifying" or candidate.state == "clocking"
		or candidate.state == "opening" or candidate.state == "capturing"
end

--- Revokes delivery immediately; accepted termination alone cannot release ownership.
--- Repeated calls retry only the same retained child, never start a replacement.
--- One optional observer is retained per actual session; retries may reuse it.
--- Absence or an already-stopped session returns true without retaining or calling
--- the observer. An actual session may notify synchronously during cancellation.
---@param on_stopped function|nil Called once with true after exact retirement and accounting release.
---@return boolean settled True only after exact native settlement and accounting release.
---@return string|nil status Pending while an exact child or settlement refusal remains.
function M.stop(on_stopped)
	assert(on_stopped == nil or type(on_stopped) == "function", "Invalid physical stop observer")
	if not session or session.state == "stopped" then return true end
	local candidate = session
	if on_stopped then
		if candidate.stop_observer and candidate.stop_observer ~= on_stopped then return false, "observer_conflict" end
		candidate.stop_observer = on_stopped
	end
	if not candidate.stop_requested then
		candidate.stop_requested, candidate.state = true, "stopping"
		Logger.start(LOG, "Stopping physical capture session…")
	end
	if candidate.receiver then candidate.receiver.stop() end
	if candidate.accounting_transition or candidate.acquiring or candidate.clock_publishing
		or candidate.baseline_publishing then return false, "pending" end
	if revoke(candidate) ~= true then return false, "settlement_refused" end
	candidate.baseline_revocation_pending = nil
	local ok, failure = pcall(function()
		if candidate.transport and not candidate.transport.isSettled() then candidate.transport.stop() end
		if candidate.clock and not candidate.clock_settled then
			observe_clock(candidate)
			candidate.clock.terminate()
		end
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
		and not session.clock_starting and not session.clock_publishing
		and not session.baseline_publishing and not session.baseline_revocation_pending
		and (not session.verifier or session.verifier_settled == true)
		and (not session.clock or session.clock_settled == true)
		and (not session.transport or session.transport.isSettled())
	return { state = session.state, reason = session.reason, settled = settled }
end


--- Binds one history capability to the actual existing native session owner.
--- No task starts, clock samples, history, privacy decision or capture is admitted.
--- Its opaque identity names only this Lua session, never a process incarnation.
---@param owner table Exact trusted history adapter owner.
---@return boolean bound False without an owned session or while another scope remains.
---@return table|string scope Exact-session ports, or explicit refusal reason.
function M.bind_history_scope(owner)
	assert(type(owner) == "table", "Missing physical history scope owner")
	local candidate = session
	if not candidate or candidate.stop_requested or candidate.failure or candidate.state == "stopped"
		or candidate.acquiring or candidate.accounting_transition then return false, "No available physical capture session" end
	if candidate.history_binding ~= nil then return false, "Physical history scope already owned" end
	local binding = { owner = owner, token = {}, active = true, busy = false, released = false }
	candidate.history_binding = binding
	local scope = {}

	local function exact(token)
		return not binding.released and rawequal(candidate.history_binding, binding) and rawequal(token, binding.token)
	end
	local function current_scope()
		return binding.active and not binding.released and current(candidate)
			and rawequal(candidate.history_binding, binding) and not candidate.stop_requested and not candidate.failure
			and candidate.state ~= "stopped" and candidate.state ~= "stopping"
	end
	local function enter(token, retirement)
		if not exact(token) then return false end
		if binding.busy then binding.active = false; return false end
		if not retirement and not current_scope() then return false end
		binding.busy = true
		return true
	end
	local function settled()
		return candidate.state == "stopped" and candidate.accounting_owned ~= true and candidate.capture == nil
			and not candidate.acquiring and not candidate.accounting_transition and not candidate.clock_starting
			and not candidate.clock_publishing and not candidate.baseline_publishing and not candidate.baseline_revocation_pending
			and (not candidate.verifier or candidate.verifier_settled == true)
			and (not candidate.clock or candidate.clock_settled == true)
	end
	local scoped_convert = function(ticks)
		assert(enter(binding.token), "Physical history clock scope is revoked")
		if candidate.clock_published ~= true or type(candidate.convert) ~= "function" then
			binding.busy = false; binding.active = false
			error("Physical history native clock is unavailable", 2)
		end
		local original = candidate.convert
		local ok, converted = pcall(original, ticks)
		local accepted = ok and current_scope() and rawequal(candidate.convert, original)
			and math.type(converted) == "integer" and converted >= 0
		binding.busy = false
		if not accepted then
			binding.active = false
			if not ok then error(converted, 0) end
			error("Physical history clock conversion was revoked or invalid", 2)
		end
		return converted
	end

	--- Returns the exact owned session token, including while native retirement is pending.
	---@return table token Opaque Lua session identity without a native incarnation claim.
	function scope.identity() return binding.token end

	--- Reports current session ownership; complete baseline admission is a separate port.
	---@param token table Exact returned session token.
	---@return boolean owned Whether this captured native session still owns authority.
	function scope.current(token)
		if not enter(token) then return false end
		local owned = current_scope()
		binding.busy = false
		return owned
	end

	--- Reports only the original admitted stream after its actual baseline completes.
	---@param token table Exact returned session token.
	---@return string|nil capture Original validated producer incarnation/lease, without reconstruction.
	function scope.admitted(token)
		if not enter(token) then return nil end
		local ok, admitted = pcall(function()
			if candidate.state == "capturing" and candidate.receiver.ready() == true
				and candidate.capture ~= nil and Accounting.admitted_capture() == candidate.capture then
				return candidate.capture
			end
		end)
		if not ok then binding.active = false end
		if not ok or not current_scope() then admitted = nil end
		binding.busy = false
		return admitted
	end

	--- Returns detached verified timebase and one converter fenced to this exact session.
	--- Native clock information is published only after its original context acknowledgement.
	---@param token table Exact returned session token.
	---@return table|nil information Copied validated native timebase, never a wall epoch.
	---@return function|nil convert Original ticks to exact nanoseconds while still owned.
	function scope.clock(token)
		if not enter(token) then return nil end
		local information
		if candidate.clock_published == true and candidate.clock_information ~= nil then
			local native = candidate.clock_information
			information = { version = native.version, domain = native.domain, numer = native.numer, denom = native.denom }
		end
		if not current_scope() then information = nil end
		binding.busy = false
		if information then return information, scoped_convert end
		return nil
	end

	--- Observes actual stop plus exact native child settlement and accounting release.
	--- A diagnostic settled snapshot alone cannot satisfy this retirement obligation.
	---@param token table Exact returned session token.
	---@return boolean retired Whether the actual captured session committed native retirement.
	function scope.settled(token)
		if not enter(token, true) then return false end
		local retired = settled()
		binding.busy = false
		return retired
	end

	--- Releases only exact scope ownership after the actual native session has retired.
	--- Its history adapter must separately settle its other native observation owners.
	---@param adapter_owner table Exact owner supplied at binding.
	---@param token table Exact returned session token.
	---@return boolean released Whether this exact native history scope was released.
	function scope.release(adapter_owner, token)
		if not rawequal(adapter_owner, binding.owner) or not enter(token, true) then return false end
		local complete = settled()
		binding.busy = false
		if not complete then return false end
		binding.active, binding.released = false, true
		candidate.history_binding = nil
		return true
	end
	return true, scope
end

return M
