--- tests/unit/modules/keylogger/test_physical_history_session.lua

--- Exercises owned software subscriptions; no Mach, hardware or installation proof.
local helpers = require("tests.helpers")
local Lifetime = require("keylogger.physical_subscription_lifetime")
local Coordinator = require("keylogger.physical_history_coordinator")

local function fixture(options)
	options = options or {}
	local owner, controls = {}, { calls = {}, bindings = {}, refused = 0 }
	local clock_token, capture_token, time = {}, {}, 0
	local clock_life = Lifetime.new(owner, clock_token)
	clock_life.bind_detach(function() clock_life.detach(); return true end)
	local clock = clock_life.capability()
	clock.read = function(candidate, token)
		if options.clock_hook then options.clock_hook(controls) end
		if not clock.current(candidate, token) then return nil, "clock revoked" end
		time = time + 1
		return time
	end
	local capture = {
		identity = function() return capture_token end,
		current = function(token)
			if options.current_hook then options.current_hook(controls) end
			return token == capture_token and not controls.capture_revoked
		end,
		settled = function(token) return token == capture_token and controls.capture_settled == true end,
	}
	local binders = {}
	local function record(name, revision)
		time = time + 1
		if name == "configuration" then
			return { kind = "physical_configuration", revision = revision, at = time,
				disabled_apps = {}, private_filter_enabled = true, secure_field_filter_enabled = true,
				system_auth_filter_enabled = true }
		end
		if name == "context" then
			return { kind = "physical_context", revision = revision, at = time,
				source = "binding", stage = "boundary", complete = false, allowed = false }
		end
		return { kind = "physical_lifecycle", domain = name, revision = revision, at = time,
			source = "binding", stage = "boundary", complete = false, fields_complete = false, allowed = false }
	end
	for _, name in ipairs({ "configuration", "context", "engine", "system", "pause" }) do
		binders[name] = function(candidate, capacity, receive, refused)
			controls.calls[#controls.calls + 1] = name
			if options.throw_at == name then error("source bind failed") end
			local token, life = {}, nil
			life = Lifetime.new(candidate, token)
			life.bind_detach(function() life.detach(); return true end)
			local binding = { token = token, life = life, scope = life.capability(), receive = receive, refused = refused }
			controls.bindings[name] = binding
			local receipt = record(name, 1)
			local accepted = life.run(receive, receipt, token)
			if options.after_bootstrap then options.after_bootstrap(name, receipt, controls) end
			if options.fail_at == name then life.revoke(); return nil, "source bootstrap refused", binding.scope end
			if accepted ~= true then life.revoke(); return nil, "subscriber denied bootstrap", binding.scope end
			return token, nil, binding.scope
		end
	end
	local projection_life, projected = Lifetime.new(owner, {}), 0
	projection_life.bind_detach(function() projection_life.detach(); return true end)
	controls.projection_scope = projection_life.capability()
	local dependencies = { capture = capture, clock = clock, binders = binders,
		projection = function(history)
			controls.projected_after = #controls.calls
			if options.projection_hook then options.projection_hook(controls, history) end
			return {
				context = function()
					projected = projected + 1
					if options.projection_read_hook then options.projection_read_hook(controls) end
					return history.resolve_interval(capture_token, clock_token, 1, time)
				end,
				context_interval = function() return history.resolve_interval(capture_token, clock_token, 1, time) end,
				stop = projection_life.revoke,
				subscription = function() return controls.projection_scope end,
			}
		end,
		on_refused = function(reason)
			controls.refused = controls.refused + 1
			controls.reason = reason
			if options.refusal_hook then options.refusal_hook(controls) end
		end,
	}
	function controls.construct(capacity) controls.coordinator = Coordinator.new(owner, capacity or 32, dependencies); return controls.coordinator end
	function controls.send(name, receipt, token)
		local b = controls.bindings[name]
		return b.life.run(b.receive, receipt or record(name, 2), token or b.token)
	end
	function controls.record(name, revision) return record(name, revision) end
	function controls.projected() return projected end
	function controls.retire()
		controls.coordinator.stop()
		controls.capture_revoked, controls.capture_settled = true, true
		return controls.coordinator.retired()
	end
	controls.clock, controls.clock_life, controls.capture = clock, clock_life, capture
	return controls
end

helpers.describe("physical history session owned binding composition", function()
	helpers.it("consumes all real-shaped bootstrap subscriptions before creating one projection", function()
		local c = fixture(); local owner = c.construct()
		helpers.assert_eq(c.projected_after, 5)
		helpers.assert_eq(owner.status().state, "bound")
		helpers.assert_eq(owner.status().retained_count, 6)
		helpers.assert_eq(owner.context("1").allowed, false)
		helpers.assert_eq(owner.context_interval("1", "2").allowed, false)
		helpers.assert_eq(owner.status().lifecycle_admission, "unqualified")
		helpers.assert_eq(owner.status().capture_admission, "unqualified")
		helpers.assert_eq(c.refused, 0)
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("copies bootstrap configuration before the foreign binder can mutate its receipt", function()
		local c = fixture({ after_bootstrap = function(name, receipt)
			if name == "configuration" then receipt.disabled_apps = function() end; receipt.revision = 99 end
		end })
		local owner = c.construct()
		helpers.assert_eq(owner.status().state, "bound")
		helpers.assert_eq(owner.status().retained_count, 6)
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("refuses bootstrap exhaustion without silently evicting source receipts", function()
		local c = fixture({ after_bootstrap = function(name, _, controls)
			if name == "configuration" then
				for revision = 2, 5 do controls.send(name, controls.record(name, revision)) end
			end
		end })
		local owner = c.construct(4)
		helpers.assert_eq(owner.status().state, "refused")
		helpers.assert_eq(c.refused, 1)
		helpers.assert_eq(#c.calls, 1)
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("keeps prior acquired sources when a later binder throws", function()
		local c = fixture({ throw_at = "context" }); local owner = c.construct()
		helpers.assert_eq(owner.status().state, "refused")
		helpers.assert_eq(c.refused, 1)
		helpers.assert_eq(c.bindings.configuration.scope.retired({}, {}), false)
		helpers.assert_eq(owner.retired(), false)
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("retains the exact failed-bootstrap scope and its actual unfinished frame", function()
		local c = fixture({ fail_at = "context" }); local owner = c.construct()
		local b = c.bindings.context
		local frame = b.life.enter()
		helpers.assert_eq(owner.status().state, "refused")
		helpers.assert_eq(c.retire(), false)
		helpers.assert_eq(b.life.leave(frame), true)
		helpers.assert_eq(owner.retired(), true)
	end)

	helpers.it("routes a changed exact source token to permanent denial", function()
		local c = fixture(); local owner = c.construct()
		local accepted = c.send("configuration", c.record("configuration", 2), {})
		helpers.assert_eq(accepted, false)
		helpers.assert_eq(owner.status().state, "refused")
		helpers.assert_eq(c.refused, 1)
		helpers.assert_eq(owner.context("1").allowed, false)
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("revokes before foreign refusal and retains the notifying source frame", function()
		local inside_context, inside_retired
		local c = fixture({ refusal_hook = function(controls)
			if controls.coordinator then
				inside_context = controls.coordinator.context("1").allowed
				controls.capture_settled = true
				inside_retired = controls.coordinator.retired()
			end
		end }); local owner = c.construct()
		local b = c.bindings.pause
		b.life.run(function() b.life.revoke(); b.refused("paused source failed", b.token) end)
		helpers.assert_eq(inside_context, false)
		helpers.assert_eq(inside_retired, false)
		helpers.assert_eq(c.refused, 1)
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("stops before the next foreign source when a bootstrap clock is revoked", function()
		local c = fixture({ clock_hook = function(controls) controls.clock_life.revoke() end })
		local owner = c.construct()
		helpers.assert_eq(owner.status().state, "refused")
		helpers.assert_eq(#c.calls, 0)
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("denies reentry from a foreign current capability before publishing", function()
		local triggered = false
		local c = fixture({ current_hook = function(controls)
			if controls.coordinator and not triggered then
				triggered = true
				controls.coordinator.context("1")
			end
		end }); local owner = c.construct()
		local before = owner.status().retained_count
		local accepted = c.send("configuration", c.record("configuration", 2))
		helpers.assert_eq(accepted, false)
		helpers.assert_eq(owner.status().retained_count, before)
		helpers.assert_eq(owner.status().state, "refused")
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("requires capture settlement plus each real detached source and projection frame", function()
		local c = fixture(); local owner = c.construct()
		local b = c.bindings.system
		local frame = b.life.enter()
		owner.stop()
		helpers.assert_eq(owner.retired(), false)
		c.capture_settled = true
		helpers.assert_eq(owner.retired(), false)
		helpers.assert_eq(owner.status().retained_count, 6)
		helpers.assert_eq(b.life.leave(frame), true)
		helpers.assert_eq(owner.retired(), true)
		helpers.assert_eq(owner.status().retained_count, 0)
	end)

	helpers.it("keeps private original capability methods despite public table replacement", function()
		local c = fixture(); local owner = c.construct()
		local b = c.bindings.context
		b.life.detach()
		b.scope.current = function() return true end
		b.scope.identity = function() return b.token end
		local decision = owner.context("1")
		helpers.assert_eq(decision.allowed, false)
		helpers.assert_eq(owner.status().state, "refused")
		helpers.assert_eq(c.projected(), 0)
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("does not accept a stale source callback after detach or reconstruct retained data", function()
		local c = fixture(); local owner = c.construct()
		helpers.assert_eq(c.retire(), true)
		local accepted = c.send("configuration", c.record("configuration", 2))
		helpers.assert_eq(accepted, false)
		helpers.assert_eq(owner.status().retained_count, 0)
		helpers.assert_eq(owner.context("1").allowed, false)
	end)

	helpers.it("refuses malformed pause release claims without promoting other observed facts", function()
		local c = fixture(); local owner = c.construct()
		local receipt = c.record("pause", 2)
		receipt.source, receipt.stage = "resume", "complete"
		receipt.complete, receipt.fields_complete, receipt.paused = true, true, false
		receipt.admission_released, receipt.settled, receipt.transition_generation = "true", true, 1
		local accepted = c.send("pause", receipt)
		helpers.assert_eq(accepted, false)
		helpers.assert_eq(owner.status().state, "refused")
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("revokes on projection reentry and waits for its original frame to unwind", function()
		local nested_retired
		local c = fixture({ projection_read_hook = function(controls)
			controls.coordinator.stop()
			controls.capture_settled = true
			nested_retired = controls.coordinator.retired()
		end }); local owner = c.construct()
		local result = owner.context("1")
		helpers.assert_eq(result.allowed, false)
		helpers.assert_eq(nested_retired, false)
		helpers.assert_eq(owner.retired(), true)
	end)
end)

helpers.describe("physical history explicit observed permission policy", function()
	helpers.it("does not backdate a newly observed baseline to delayed original event ticks", function()
		local c = fixture()
		c.capture.admitted = function() return "actual-incarnation:actual-lease" end
		local owner = c.construct()
		local count = owner.status().retained_count
		helpers.assert_eq(owner.capture_ready(), true)
		local result = owner.context("1")
		helpers.assert_eq(result.allowed, false)
		helpers.assert_eq(owner.status().capture_admission, "observed")
		helpers.assert_eq(owner.status().retained_count, count + 1)
		owner.context("2")
		helpers.assert_eq(owner.status().retained_count, count + 1)
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("waits for actual owned resume and positive posture observations before granting later ticks", function()
		local c = fixture(); local admitted
		c.capture.admitted = function() return admitted end
		local owner = c.construct()
		local revisions = { engine = 1, system = 1, pause = 1, context = 1 }
		local function pair(name, source, fields)
			for _, stage in ipairs({ "boundary", "complete" }) do
				revisions[name] = revisions[name] + 1
				local record = c.record(name, revisions[name])
				record.source, record.stage = source, stage
				record.complete, record.fields_complete = stage == "complete", stage == "complete"
				for key, value in pairs(fields or {}) do
					if stage == "complete" or key == "event" or key == "component" or key == "value" then record[key] = value end
				end
				helpers.assert_eq(c.send(name, record), true)
			end
		end
		pair("engine", "start", { enabled = true, paused = false, runtime_generation = 1 })
		local system = { enabled = true, paused = false, hardware_committed = true,
			hardware_generation = 1, context_refresh_generation = 1 }
		for index, row in ipairs({ { "system_wake", "system_awake" }, { "screens_wake", "screen_awake" }, { "unlock", "unlocked" } }) do
			system.event, system.component, system.value = index, row[2], true
			pair("system", row[1], system)
		end
		pair("pause", "resume", { paused = false, settled = true, admission_released = true, transition_generation = 1 })
		pair("context", "application", { correlated = true, allowed = true, private = false, secure = false,
			app = { name = "Editor", bundle_id = "org.editor", path = "/Editor.app", pid = 42 } })
		helpers.assert_eq(owner.status().lifecycle_admission, "observed_only")
		helpers.assert_eq(owner.context("1").allowed, false)
		admitted = "actual-incarnation:actual-lease"
		helpers.assert_eq(owner.capture_ready(), true)
		helpers.assert_eq(owner.context("1").allowed, false)
		-- The fixture projection selects its original full hold, so it remains denied.
		-- Real policy coverage is inspected by a captured resolver, not a fake latest app.
		helpers.assert_eq(owner.status().capture_admission, "observed")
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("vetoes retirement when an actual source retirement port reenters", function()
		local nested, fired = nil, false
		local c = fixture({ after_bootstrap = function(name, _, controls)
			if name == "configuration" then
				local b = controls.bindings[name]
				local original = b.scope.retired
				b.scope.retired = function(candidate, token)
					if controls.coordinator and not fired then
						fired = true
						nested = controls.coordinator.retired()
					end
					return original(candidate, token)
				end
			end
		end }); local owner = c.construct()
		local outer = c.retire()
		helpers.assert_eq(nested, false)
		helpers.assert_eq(outer, false)
		helpers.assert_eq(owner.status().retained_count, 6)
		helpers.assert_eq(owner.retired(), true)
	end)
end)

local function with_native_session(callback)
	local names = { "modules.keylogger.physical_history_session", "adapters.physical_history_context",
		"adapters.physical_observation_clock", "modules.keylogger.physical_capture", "modules.keylogger",
		"modules.keylogger.context_tracker", "modules.keylogger.watchers", "modules.shortcuts.script_control",
		"adapters.shell_runner", "modules.keylogger.physical_key_identity", "modules.keylogger.log_manager" }
	helpers.with_fresh_modules(names, function()
		local c, time, subscriber = { calls = {}, stops = 0, releases = 0, refusals = 0 }, 0, nil
		local capture_token, clock_token = {}, {}
		local function sample() time = time + 1; return time end
		local clock_life
		local clock = { bind_history_scope = function(owner)
			subscriber = owner
			clock_life = Lifetime.new(owner, clock_token)
			clock_life.bind_detach(function() clock_life.detach(); return true end)
			local scope = clock_life.capability()
			scope.read = function() return sample() end
			return scope
		end }
		local capture = {
			init = function(ports) c.ports = ports; return true end,
			stop = function() c.stops = c.stops + 1; c.settled = true; return true end,
			bind_history_scope = function(owner)
				c.capture_owner = owner
				return true, {
					identity = function() return capture_token end,
					current = function(token) return token == capture_token and not c.settled end,
					admitted = function() return nil end,
					clock = function() return nil end,
					settled = function(token) return token == capture_token and c.settled == true end,
					release = function(candidate, token)
						if candidate ~= owner or token ~= capture_token or not c.settled then return false end
						if c.release_hook then c.release_hook() end
						c.releases = c.releases + 1
						return true
					end,
				}
			end,
		}
		local function binder(name, boolean_result)
			return function(owner, _, receive, _, persist)
				c.calls[#c.calls + 1] = name
				if name == "context" then c.persist = persist end
				local token = {}
				local life = Lifetime.new(owner, token)
				life.bind_detach(function() life.detach(); return true end)
				local record
				if name == "configuration" then
					record = { kind = "physical_configuration", revision = 1, at = sample(), disabled_apps = {},
						private_filter_enabled = true, secure_field_filter_enabled = true, system_auth_filter_enabled = true }
				elseif name == "context" then
					record = { kind = "physical_context", revision = 1, at = sample(), source = "binding",
						stage = "boundary", complete = false, allowed = false }
				else
					record = { kind = "physical_lifecycle", domain = name, revision = 1, at = sample(), source = "binding",
						stage = "boundary", complete = false, fields_complete = false, allowed = false }
				end
				local accepted = life.run(receive, record, token)
				if accepted ~= true then life.revoke() end
				if boolean_result then return accepted, accepted and token or "refused", life.capability() end
				return accepted and token or nil, accepted and nil or "refused", life.capability()
			end
		end
		local may_persist = function() return true end
		local spawn, keycode, emit, emit_release = function() end, function() end, function() end, function() end
		local decode, encode = hs.json.decode, hs.json.encode
		package.loaded["adapters.physical_history_context"] = { new = function(owner, history)
			c.history, c.projected_owner = history, owner
			local Accepted = require("keylogger.physical_accepted_context")
			return Accepted.new(owner, { current = function() return true end, revision = history.retained_count,
				convert = tonumber, calendar = function() error("denied fixture must not sample wall") end,
				resolve_interval = function(first, last) return history.resolve_interval(capture_token, clock_token, first, last) end,
				on_refused = function() history.stop(capture_token) end })
		end }
		package.loaded["adapters.physical_observation_clock"] = clock
		package.loaded["modules.keylogger.physical_capture"] = capture
		package.loaded["modules.keylogger"] = { bind_physical_configuration_observer = binder("configuration", true),
			bind_physical_lifecycle_observer = binder("engine"), may_persist = may_persist }
		package.loaded["modules.keylogger.context_tracker"] = { bind_physical_correlated_context_observer = binder("context", true) }
		package.loaded["modules.keylogger.watchers"] = { bind_physical_lifecycle_observer = binder("system") }
		package.loaded["modules.shortcuts.script_control"] = { bind_physical_pause_observer = binder("pause") }
		package.loaded["adapters.shell_runner"] = { spawn = spawn }
		package.loaded["modules.keylogger.physical_key_identity"] = { resolve = keycode }
		package.loaded["modules.keylogger.log_manager"] = { log_physical_press = emit, log_physical_release = emit_release }
		local adapter = require("modules.keylogger.physical_history_session")
		local session = adapter.init(32, function() c.refusals = c.refusals + 1 end)
		c.adapter, c.expected = adapter, { spawn = spawn, decode = decode, encode = encode,
			keycode = keycode, emit = emit, emit_release = emit_release, may_persist = may_persist }
		callback(session, c)
	end)
end

helpers.describe("physical history native factory wiring with modeled native ports", function()
	helpers.it("installs exact native sink and transport functions without launching or sampling", function()
		with_native_session(function(session, c)
			helpers.assert_eq(session.status().state, "prepared")
			helpers.assert_eq(#c.calls, 0)
			for _, name in ipairs({ "spawn", "decode", "encode", "keycode", "emit", "emit_release" }) do
				helpers.assert_eq(rawequal(c.ports[name], c.expected[name]), true)
			end
			local duplicate, reason = c.adapter.init(32, function() end)
			helpers.assert_eq(duplicate, nil)
			helpers.assert_eq(reason, "physical_history_session_already_initialized")
			helpers.assert_eq(c.ports.context("1").allowed, false)
			helpers.assert_eq(c.stops, 0)
			session.stop()
			helpers.assert_eq(session.retired(), true)
		end)
	end)

	helpers.it("binds actual-shaped scopes and writers only within the real clock-ready port", function()
		with_native_session(function(session, c)
			local accepted = c.ports.clock_ready({ version = 1, domain = "mach_absolute_time", numer = 1, denom = 1 })
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#c.calls, 5)
			helpers.assert_eq(c.capture_owner, c.projected_owner)
			helpers.assert_eq(c.persist, c.expected.may_persist)
			helpers.assert_eq(session.status().retained_count, 6)
			helpers.assert_eq(c.ports.context("1").allowed, false)
			session.stop()
			helpers.assert_eq(c.stops, 1)
			helpers.assert_eq(session.retired(), true)
			helpers.assert_eq(c.releases, 1)
			session.stop()
			helpers.assert_eq(c.stops, 1)
			helpers.assert_eq(c.ports.clock_ready({}), false)
			helpers.assert_eq(session.retired(), true)
			helpers.assert_eq(c.releases, 1)
		end)
	end)

	helpers.it("retains ownership when CaptureScope.release reenters retirement", function()
		with_native_session(function(session, c)
			helpers.assert_eq(c.ports.clock_ready({ version = 1, domain = "mach_absolute_time", numer = 1, denom = 1 }), true)
			local nested
			c.release_hook = function() nested = session.retired() end
			session.stop()
			local outer = session.retired()
			helpers.assert_eq(nested, false)
			helpers.assert_eq(outer, false)
			c.release_hook = nil
			helpers.assert_eq(session.retired(), true)
		end)
	end)
end)

helpers.describe("physical history real policy crossing cancellation", function()
	helpers.it("permits later original ticks only after complete owned facts and cancels the whole paused crossing", function()
		local admitted, resolve
		local c = fixture({ projection_hook = function(controls, history)
			local original = history.resolve_interval
			history.resolve_interval = function(capture, clock, first, last)
				resolve = function(a, b) return original(capture, clock, a, b) end
				return original(capture, clock, first, last)
			end
		end })
		c.capture.admitted = function() return admitted end
		local owner = c.construct()
		owner.context("1") -- Capture exact resolver identities without promoting an event.
		local revisions = { engine = 1, system = 1, pause = 1, context = 1 }
		local function pair(name, source, fields)
			local last
			for _, stage in ipairs({ "boundary", "complete" }) do
				revisions[name] = revisions[name] + 1
				local record = c.record(name, revisions[name]); last = record.at
				record.source, record.stage = source, stage
				record.complete, record.fields_complete = stage == "complete", stage == "complete"
				for key, value in pairs(fields or {}) do
					if stage == "complete" or key == "event" or key == "component" or key == "value" then record[key] = value end
				end
				helpers.assert_eq(c.send(name, record), true)
			end
			return last
		end
		pair("engine", "start", { enabled = true, paused = false, runtime_generation = 1 })
		local system = { enabled = true, paused = false, hardware_committed = true,
			hardware_generation = 1, context_refresh_generation = 1 }
		for index, row in ipairs({ { "system_wake", "system_awake" }, { "screens_wake", "screen_awake" }, { "unlock", "unlocked" } }) do
			system.event, system.component, system.value = index, row[2], true
			pair("system", row[1], system)
		end
		pair("pause", "resume", { paused = false, settled = true, admission_released = true, transition_generation = 1 })
		pair("context", "application", { correlated = true, allowed = true, private = false, secure = false,
			app = { name = "Editor", bundle_id = "org.editor", path = "/Editor.app", pid = 42 } })
		helpers.assert_eq(resolve(1, 1).allowed, false)
		admitted = "actual-incarnation:actual-lease"
		helpers.assert_eq(owner.capture_ready(), true)
		owner.context("1")
		local first = c.record("configuration", 99).at
		local permitted = resolve(first, first)
		helpers.assert_eq(permitted.allowed, true)
		helpers.assert_eq(permitted.app.name, "Editor")
		local paused_at = pair("pause", "pause", { paused = true, settled = true, admission_released = false, transition_generation = 2 })
		helpers.assert_eq(resolve(first, paused_at).allowed, false)
		local resumed_at = pair("pause", "resume", { paused = false, settled = true, admission_released = true, transition_generation = 3 })
		helpers.assert_eq(resolve(first, resumed_at).allowed, false)
		helpers.assert_eq(resolve(resumed_at, resumed_at).allowed, true)
		helpers.assert_eq(c.retire(), true)
	end)
end)

helpers.describe("physical history consumption by the actual capture owner", function()
	helpers.it("retains actual scope in clock-ready before ACK and releases only after actual task settlement", function()
		local Fixture = require("tests.support.physical_capture_fixture")
		Fixture.run(function(capture, observed, controls)
			local names = { "modules.keylogger.physical_history_session", "adapters.physical_history_context",
				"adapters.physical_observation_clock", "modules.keylogger", "modules.keylogger.context_tracker",
				"modules.keylogger.watchers", "modules.shortcuts.script_control", "adapters.shell_runner",
				"modules.keylogger.physical_key_identity", "modules.keylogger.log_manager" }
			helpers.with_fresh_modules(names, function()
				local native, sample, ns = hs, nil, 0
				sample = function() ns = ns + 1; return ns end
				hs = { json = { decode = controls.dependencies.decode, encode = controls.dependencies.encode },
					timer = { absoluteTime = sample } }
				local ok, error_reason = pcall(function()
					local Clock = require("adapters.physical_observation_clock")
					local before_ack, exact_scope
					local function binder(name, boolean_result)
						return function(owner, _, receive)
							local token, record = {}, nil
							local lifetime = Lifetime.new(owner, token)
							lifetime.bind_detach(function() lifetime.detach(); return true end)
							if name == "configuration" then
								record = { kind = "physical_configuration", revision = 1, at = Clock.now(), disabled_apps = {},
									private_filter_enabled = true, secure_field_filter_enabled = true, system_auth_filter_enabled = true }
							elseif name == "context" then
								record = { kind = "physical_context", revision = 1, at = Clock.now(), source = "binding", stage = "boundary",
									complete = false, allowed = false }
							else
								record = { kind = "physical_lifecycle", domain = name, revision = 1, at = Clock.now(), source = "binding",
									stage = "boundary", complete = false, fields_complete = false, allowed = false }
							end
							local accepted = lifetime.run(receive, record, token)
							if boolean_result then return accepted, token, lifetime.capability() end
							return accepted and token or nil, nil, lifetime.capability()
						end
					end
					package.loaded["modules.keylogger"] = { bind_physical_configuration_observer = binder("configuration", true),
						bind_physical_lifecycle_observer = binder("engine"), may_persist = function() return true end }
					package.loaded["modules.keylogger.context_tracker"] = { bind_physical_correlated_context_observer = binder("context", true) }
					package.loaded["modules.keylogger.watchers"] = { bind_physical_lifecycle_observer = binder("system") }
					package.loaded["modules.shortcuts.script_control"] = { bind_physical_pause_observer = binder("pause") }
					package.loaded["adapters.shell_runner"] = { spawn = controls.dependencies.spawn }
					package.loaded["modules.keylogger.physical_key_identity"] = { resolve = controls.dependencies.keycode }
					package.loaded["modules.keylogger.log_manager"] = {
						log_physical_press = controls.dependencies.emit, log_physical_release = controls.dependencies.emit_release }
					package.loaded["adapters.physical_history_context"] = { new = function(owner, history, scopes)
						exact_scope = scopes.capture
						local token, clock_token = exact_scope.identity(), scopes.clock.identity(owner)
						before_ack = exact_scope.clock(token)
						local Accepted = require("keylogger.physical_accepted_context")
						return Accepted.new(owner, {
							current = function() return exact_scope.current(token) end,
							revision = history.retained_count,
							convert = function(ticks)
								local _, convert = exact_scope.clock(token)
								return convert(ticks)
							end,
							resolve_interval = function(first, last) return history.resolve_interval(token, clock_token, first, last) end,
							calendar = function() error("unknown lifecycle must not sample calendar") end,
							on_refused = function() history.stop(token) end,
						})
					end }
					local session = require("modules.keylogger.physical_history_session").init(32, function() end)
					helpers.assert_eq(#observed.tasks, 0)
					helpers.assert_eq(capture.start(controls.options), true)
					controls.verified(); controls.clocked()
					helpers.assert_eq(before_ack, nil)
					helpers.assert_eq(session.status().state, "bound")
					local token = exact_scope.identity()
					helpers.assert_eq(exact_scope.current(token), true)
					helpers.assert_eq(exact_scope.admitted(token), nil)
					controls.open()
					helpers.assert_eq(exact_scope.admitted(token), "production-fixture/7")
					helpers.assert_eq(session.status().capture_admission, "observed")
					session.stop()
					helpers.assert_eq(exact_scope.current(token), false)
					helpers.assert_eq(session.retired(), false)
					helpers.assert_eq(capture.start(controls.options), false)
					observed.tasks[3].done(0); observed.tasks[3].settle()
					helpers.assert_eq(session.retired(), true)
					helpers.assert_eq(capture.start(controls.options), true)
					local successor = observed.tasks[4]
					session.stop()
					helpers.assert_eq(successor.stops, 0)
					capture.stop(); successor.done(0); successor.settle()
				end)
				hs = native
				if not ok then error(error_reason, 0) end
			end)
		end)
	end)
end)

helpers.describe("physical history unknown posture and monotonic release guards", function()
	helpers.it("keeps initial awake posture unknown despite completed enabled writer snapshots", function()
		local resolve
		local c = fixture({ projection_hook = function(_, history)
			local original = history.resolve_interval
			history.resolve_interval = function(capture, clock, first, last)
				resolve = function(a, b) return original(capture, clock, a, b) end
				return original(capture, clock, first, last)
			end
		end })
		c.capture.admitted = function() return "actual-incarnation:actual-lease" end
		local owner = c.construct()
		helpers.assert_eq(owner.capture_ready(), true)
		owner.context("1")
		for _, recipe in ipairs({
			{ "engine", "start", { enabled = true, paused = false, runtime_generation = 1 } },
			{ "system", "hardware_start", { enabled = true, paused = false, hardware_committed = true,
				hardware_generation = 1, context_refresh_generation = 1 } },
			{ "pause", "resume", { paused = false, settled = true, admission_released = true, transition_generation = 1 } },
			{ "context", "application", { correlated = true, allowed = true, private = false, secure = false,
				app = { name = "Editor", bundle_id = "org.editor", path = "/Editor.app", pid = 42 } } },
		}) do
			for offset, stage in ipairs({ "boundary", "complete" }) do
				local record = c.record(recipe[1], offset + 1)
				record.source, record.stage = recipe[2], stage
				record.complete, record.fields_complete = stage == "complete", stage == "complete"
				if stage == "complete" then for key, value in pairs(recipe[3]) do record[key] = value end end
				helpers.assert_eq(c.send(recipe[1], record), true)
			end
		end
		local later = c.record("configuration", 99).at
		helpers.assert_eq(resolve(later, later).allowed, false)
		helpers.assert_eq(owner.status().lifecycle_admission, "unqualified")
		helpers.assert_eq(owner.status().capture_admission, "observed")
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("retains an exact release ACK once when a foreign completion frame vetoes retirement", function()
		with_native_session(function(session, c)
			helpers.assert_eq(c.ports.clock_ready({ version = 1, domain = "mach_absolute_time", numer = 1, denom = 1 }), true)
			c.release_hook = function() session.retired() end
			session.stop()
			helpers.assert_eq(session.retired(), false)
			helpers.assert_eq(c.releases, 1)
			c.release_hook = nil
			helpers.assert_eq(session.retired(), true)
			helpers.assert_eq(c.releases, 1)
		end)
	end)
end)

helpers.describe("physical history absent baseline admission", function()
	helpers.it("cannot grant capture from a missing admission adapter despite all positive writer observations", function()
		local resolve
		local c = fixture({ projection_hook = function(_, history)
			local original = history.resolve_interval
			history.resolve_interval = function(capture, clock, first, last)
				resolve = function(a, b) return original(capture, clock, a, b) end
				return original(capture, clock, first, last)
			end
		end })
		local owner = c.construct()
		owner.context("1")
		local revisions = { engine = 1, system = 1, pause = 1, context = 1 }
		local rows = {
			{ "engine", "start", { enabled = true, paused = false, runtime_generation = 1 } },
			{ "system", "system_wake", { enabled = true, paused = false, hardware_committed = true,
				hardware_generation = 1, context_refresh_generation = 1, event = 1, component = "system_awake", value = true } },
			{ "system", "screens_wake", { enabled = true, paused = false, hardware_committed = true,
				hardware_generation = 1, context_refresh_generation = 1, event = 2, component = "screen_awake", value = true } },
			{ "system", "unlock", { enabled = true, paused = false, hardware_committed = true,
				hardware_generation = 1, context_refresh_generation = 1, event = 3, component = "unlocked", value = true } },
			{ "pause", "resume", { paused = false, settled = true, admission_released = true, transition_generation = 1 } },
			{ "context", "application", { correlated = true, allowed = true, private = false, secure = false,
				app = { name = "Editor", bundle_id = "org.editor", path = "/Editor.app", pid = 42 } } },
		}
		for _, row in ipairs(rows) do
			for _, stage in ipairs({ "boundary", "complete" }) do
				revisions[row[1]] = revisions[row[1]] + 1
				local record = c.record(row[1], revisions[row[1]])
				record.source, record.stage = row[2], stage
				record.complete, record.fields_complete = stage == "complete", stage == "complete"
				for key, value in pairs(row[3]) do
					if stage == "complete" or key == "event" or key == "component" or key == "value" then record[key] = value end
				end
				helpers.assert_eq(c.send(row[1], record), true)
			end
		end
		local later = c.record("configuration", 99).at
		helpers.assert_eq(resolve(later, later).allowed, false)
		helpers.assert_eq(owner.status().capture_admission, "unqualified")
		helpers.assert_eq(owner.status().lifecycle_admission, "observed_only")
		helpers.assert_eq(c.retire(), true)
	end)
end)

helpers.describe("physical history native stop retry ownership", function()
	helpers.it("retries exact native shutdown while scope retirement has not acknowledged settlement", function()
		with_native_session(function(session, c)
			helpers.assert_eq(c.ports.clock_ready({ version = 1, domain = "mach_absolute_time", numer = 1, denom = 1 }), true)
			local held = true
			setmetatable(c, { __newindex = function(target, key, value)
				if key == "settled" and held then held = false; return end
				rawset(target, key, value)
			end })
			session.stop()
			helpers.assert_eq(c.stops, 1)
			helpers.assert_eq(c.settled, nil)
			local acknowledged = session.retired()
			helpers.assert_eq(acknowledged, true)
			helpers.assert_eq(c.stops, 2)
			helpers.assert_eq(c.releases, 1)
			session.stop()
			helpers.assert_eq(c.stops, 2)
		end)
	end)
end)

helpers.describe("physical history native initialization ownership", function()
	helpers.it("refuses initialization reentry before a foreign Capture.init can install two sessions", function()
		with_native_session(function(_, c)
			local first, reentrant, reentrant_reason = true, nil, nil
			local adapter
			package.loaded["modules.keylogger.physical_capture"].init = function()
				if first then
					first = false
					reentrant, reentrant_reason = adapter.init(32, function() end)
				end
				return true
			end
			package.loaded["modules.keylogger.physical_history_session"] = nil
			adapter = require("modules.keylogger.physical_history_session")
			local session = adapter.init(32, function() end)
			helpers.assert_eq(type(session), "table")
			helpers.assert_eq(reentrant, nil)
			helpers.assert_eq(reentrant_reason, "physical_history_session_already_initialized")
			session.stop()
			helpers.assert_eq(session.retired(), true)
		end)
	end)
end)


--- Independent pre-source generic stop-frame control, retained verbatim.
do
local function fixture(configure)
 local subscriber, capture_token, clock_token = {}, {}, {}
 local f = {subscriber=subscriber, capture_token=capture_token, clock_token=clock_token, sources={}, settled=false, capture_current=true, clock_current=true, clock_detached=false, notices=0, projection_frames=0, projection_detached=false, projection_active=true}
 local clock = {
  identity=function(owner) if owner==subscriber then return clock_token end end,
  current=function(owner,token) return owner==subscriber and token==clock_token and f.clock_current end,
  read=function(owner,token) assert(owner==subscriber and token==clock_token); return 100 end,
  detach=function(owner,token) if owner~=subscriber or token~=clock_token then return false end; f.clock_detached=true; f.clock_current=false; return true end,
  retired=function(owner,token) return owner==subscriber and token==clock_token and f.clock_detached end,
 }
 local capture = {
  identity=function() return capture_token end,
  current=function(token) return token==capture_token and f.capture_current end,
  admitted=function(token) assert(token==capture_token); return nil end,
  settled=function(token) return token==capture_token and f.settled end,
 }
 local binders={}
 for _,name in ipairs({'configuration','context','engine','system','pause'}) do
  local s={token={}, current=true, detached=false, frames=0}
  s.scope={
   identity=function(owner) if owner==subscriber then return s.token end end,
   current=function(owner,token) return owner==subscriber and token==s.token and s.current end,
   detach=function(owner,token) if owner~=subscriber or token~=s.token then return false end; s.detached=true; s.current=false; return true end,
   retired=function(owner,token) if s.retirement_callback then s.retirement_callback() end; return owner==subscriber and token==s.token and s.detached and s.frames==0 end,
  }
  binders[name]=function(owner,capacity,receive,on_refused)
   assert(owner==subscriber and capacity==32)
   s.receive,s.refuse=receive,on_refused
   return s.token,nil,s.scope
  end
  f.sources[name]=s
 end
 local projection_scope={
  identity=function(owner) if owner==subscriber then return f.projection_token end end,
  current=function(owner,token) return owner==subscriber and token==f.projection_token and f.projection_active end,
  detach=function(owner,token) if owner~=subscriber or token~=f.projection_token then return false end; f.projection_detached=true; f.projection_active=false; return true end,
  retired=function(owner,token) return owner==subscriber and token==f.projection_token and f.projection_detached and f.projection_frames==0 end,
 }
 f.projection_token={}
 local dependencies={capture=capture,clock=clock,binders=binders,projection=function(history)
  f.history=history
  return {context=function() return {allowed=false} end, context_interval=function() return {allowed=false} end,stop=function() f.projection_active=false; return true end,subscription=function() return projection_scope end}
 end,on_refused=function() f.notices=f.notices+1 end}
 f.dependencies=dependencies
 if configure then configure(f,dependencies) end
 f.owner=Coordinator.new(subscriber,32,dependencies)
 return f
end
helpers.describe('physical history public stop frame', function()
helpers.it('stop retains its actual foreign projection cleanup frame',function()
 local nested
 local f=fixture(function(state,dependencies)
  dependencies.projection=function(history)
   return {context=function() return {allowed=false} end, context_interval=function() return {allowed=false} end,
    stop=function() nested=state.owner.retired(); return true end,
    subscription=function() return {
     identity=function(owner) if owner==state.subscriber then return state.projection_token end end,
     detach=function() return true end,retired=function() return true end,
    } end}
  end
 end)
 f.settled=true
 f.owner.stop()
 assert(nested==false,'cleanup acknowledged while actual outer stop foreign frame remained')
 assert(f.owner.retired()==true)
end)
end)
end

helpers.describe("physical history exact baseline event consumption", function()
	helpers.it("refuses a claimed baseline callback while actual admission is still absent", function()
		local c = fixture()
		c.capture.admitted = function() return nil end
		local owner = c.construct()
		local accepted = owner.capture_ready()
		helpers.assert_eq(accepted, false)
		helpers.assert_eq(owner.status().state, "refused")
		helpers.assert_eq(owner.status().capture_admission, "unqualified")
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("never publishes admission from context and acknowledges only the actual readiness event", function()
		local admitted = "actual-incarnation:actual-lease"
		local c = fixture()
		c.capture.admitted = function() return admitted end
		local owner = c.construct()
		local before = owner.status().retained_count
		local denied = owner.context("1")
		helpers.assert_eq(denied.allowed, false)
		helpers.assert_eq(owner.status().retained_count, before)
		helpers.assert_eq(owner.status().capture_admission, "unqualified")
		local accepted = owner.capture_ready()
		helpers.assert_eq(accepted, true)
		helpers.assert_eq(owner.status().retained_count, before + 1)
		helpers.assert_eq(owner.status().capture_admission, "observed")
		owner.context("1")
		helpers.assert_eq(owner.status().retained_count, before + 1)
		admitted = nil
		helpers.assert_eq(owner.context("1").allowed, false)
		helpers.assert_eq(owner.status().state, "refused")
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("revokes reentrant readiness before publishing any capture permission", function()
		local nested, fired
		local c = fixture({ clock_hook = function(controls)
			if controls.coordinator and not fired then
				fired = true
				nested = controls.coordinator.capture_ready()
			end
		end })
		c.capture.admitted = function() return "actual-incarnation:actual-lease" end
		local owner = c.construct()
		local before = owner.status().retained_count
		local outer = owner.capture_ready()
		helpers.assert_eq(nested, false)
		helpers.assert_eq(outer, false)
		helpers.assert_eq(owner.status().retained_count, before)
		helpers.assert_eq(owner.status().state, "refused")
		helpers.assert_eq(c.retire(), true)
	end)
end)

helpers.describe("physical history native readiness port", function()
	helpers.it("installs the real optional baseline-ready port and refuses a premature callback", function()
		with_native_session(function(session, c)
			helpers.assert_eq(type(c.ports.baseline_ready), "function")
			helpers.assert_eq(c.ports.clock_ready({ version = 1, domain = "mach_absolute_time", numer = 1, denom = 1 }), true)
			local accepted = c.ports.baseline_ready()
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(c.refusals, 1)
			helpers.assert_eq(session.retired(), true)
		end)
	end)
end)

--- Consumes genuine initial observed state without inventing a completed writer.
local function initial_observation_fixture(options)
	options = options or {}
	local resolve
	local c = fixture({ projection_hook = function(_, history)
		local original = history.resolve_interval
		history.resolve_interval = function(capture, clock, first, last)
			resolve = function(a, b) return original(capture, clock, a, b) end
			return original(capture, clock, first, last)
		end
	end })
	if not options.missing_admission then c.capture.admitted = function() return "owned-observed-incarnation/7" end end
	local owner = c.construct()
	if not options.missing_admission then helpers.assert_eq(owner.capture_ready(), true) end
	owner.context("1")
	local revisions = { engine = 1, system = 1, pause = 1, context = 1 }
	function c.observe_initial(name, fields, qualified)
		revisions[name] = revisions[name] + 1
		local record = c.record(name, revisions[name])
		record.source, record.stage = "initial_snapshot", "observed"
		record.complete, record.fields_complete = false, true
		record.observation_complete, record.settled = qualified ~= false, qualified ~= false
		record.qualification = qualified ~= false and "observed" or "unknown"
		for key, value in pairs(fields) do record[key] = value end
		helpers.assert_eq(c.send(name, record), true)
		return record.at
	end
	function c.completed(name, source, fields)
		for _, stage in ipairs({ "boundary", "complete" }) do
			revisions[name] = revisions[name] + 1
			local record = c.record(name, revisions[name])
			record.source, record.stage = source, stage
			record.complete, record.fields_complete = stage == "complete", stage == "complete"
			for key, value in pairs(fields) do
				if stage == "complete" or key == "event" or key == "component" or key == "value" then record[key] = value end
			end
			helpers.assert_eq(c.send(name, record), true)
		end
	end
	function c.positive_posture()
		for event, row in ipairs({ { "system_wake", "system_awake" }, { "screens_wake", "screen_awake" }, { "unlock", "unlocked" } }) do
			c.completed("system", row[1], { enabled = true, paused = false, hardware_committed = true,
				hardware_generation = 1, context_refresh_generation = 1, event = event, component = row[2], value = true })
		end
	end
	function c.application()
		c.completed("context", "application", { correlated = true, allowed = true, private = false, secure = false,
			app = { name = "Editor", bundle_id = "org.editor", path = "/Editor.app", pid = 42 } })
	end
	function c.now() return c.record("configuration", 99).at end
	function c.resolve(first, last) return resolve(first, last) end
	return owner, c
end
local initial_engine = { enabled = true, paused = false, runtime_generation = 1 }
local initial_system = { enabled = true, paused = false, hardware_committed = true, hardware_generation = 1, context_refresh_generation = 1 }
local initial_pause = { paused = false, admission_released = true, transition_generation = 1 }

helpers.describe("physical history initial observed state policy", function()
	helpers.it("uses settled observed engine and released pause state after genuine positive posture events", function()
		local owner, c = initial_observation_fixture()
		c.observe_initial("engine", initial_engine)
		c.observe_initial("system", initial_system)
		c.observe_initial("pause", initial_pause)
		c.positive_posture(); c.application()
		local at = c.now()
		helpers.assert_eq(c.resolve(at, at).allowed, true)
		helpers.assert_eq(owner.status().state, "bound")
		helpers.assert_eq(owner.status().lifecycle_admission, "observed_only")
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("accepts initial scalar observations while keeping unknown OS posture denied", function()
		local owner, c = initial_observation_fixture()
		c.observe_initial("engine", initial_engine)
		c.observe_initial("system", initial_system)
		c.observe_initial("pause", initial_pause)
		c.application()
		local at = c.now()
		helpers.assert_eq(c.resolve(at, at).allowed, false)
		helpers.assert_eq(owner.status().state, "bound")
		helpers.assert_eq(owner.status().lifecycle_admission, "unqualified")
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("cannot promote an unsettled initial engine snapshot through later genuine wake events", function()
		local owner, c = initial_observation_fixture()
		c.observe_initial("engine", initial_engine, false)
		c.observe_initial("system", initial_system)
		c.observe_initial("pause", initial_pause)
		c.positive_posture(); c.application()
		local at = c.now()
		helpers.assert_eq(c.resolve(at, at).allowed, false)
		helpers.assert_eq(owner.status().state, "bound")
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("cannot replace actual pause settlement with unpaused scalar values", function()
		local owner, c = initial_observation_fixture()
		c.observe_initial("engine", initial_engine)
		c.observe_initial("system", initial_system)
		c.observe_initial("pause", initial_pause, false)
		c.positive_posture(); c.application()
		local at = c.now()
		helpers.assert_eq(c.resolve(at, at).allowed, false)
		helpers.assert_eq(owner.status().state, "bound")
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("requires actual baseline admission even with settled initial scalar observations", function()
		local owner, c = initial_observation_fixture({ missing_admission = true })
		c.observe_initial("engine", initial_engine)
		c.observe_initial("system", initial_system)
		c.observe_initial("pause", initial_pause)
		c.positive_posture(); c.application()
		local at = c.now()
		helpers.assert_eq(c.resolve(at, at).allowed, false)
		helpers.assert_eq(owner.status().capture_admission, "unqualified")
		helpers.assert_eq(owner.status().state, "bound")
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("cancels the entire interval crossing initially unknown posture instead of backdating permission", function()
		local _, c = initial_observation_fixture()
		c.observe_initial("engine", initial_engine)
		c.observe_initial("system", initial_system)
		c.observe_initial("pause", initial_pause)
		c.application()
		local before = c.now()
		helpers.assert_eq(c.resolve(before, before).allowed, false)
		c.positive_posture()
		local after = c.now()
		helpers.assert_eq(c.resolve(after, after).allowed, true)
		helpers.assert_eq(c.resolve(before, after).allowed, false)
		helpers.assert_eq(c.retire(), true)
	end)

	helpers.it("keeps exact initial source retirement debt after token refusal", function()
		local owner, c = initial_observation_fixture()
		c.observe_initial("engine", initial_engine)
		local source = c.bindings.engine
		local frame = source.life.enter()
		local record = c.record("engine", 3)
		helpers.assert_eq(c.send("engine", record, {}), false)
		helpers.assert_eq(owner.status().state, "refused")
		helpers.assert_eq(c.retire(), false)
		helpers.assert_eq(source.life.leave(frame), true)
		helpers.assert_eq(owner.retired(), true)
	end)
end)

helpers.describe("physical history native initial snapshot opt-in", function()
	helpers.it("requests real readonly observations only from the three actual lifecycle and pause owners", function()
		with_native_session(function(previous, c)
			previous.stop()
			local arguments = {}
			for _, row in ipairs({
				{ "configuration", "modules.keylogger", "bind_physical_configuration_observer" },
				{ "context", "modules.keylogger.context_tracker", "bind_physical_correlated_context_observer" },
				{ "engine", "modules.keylogger", "bind_physical_lifecycle_observer" },
				{ "system", "modules.keylogger.watchers", "bind_physical_lifecycle_observer" },
				{ "pause", "modules.shortcuts.script_control", "bind_physical_pause_observer" },
			}) do
				local original = package.loaded[row[2]][row[3]]
				package.loaded[row[2]][row[3]] = function(...)
					arguments[row[1]] = { n = select("#", ...), ... }
					return original(...)
				end
			end
			package.loaded["modules.keylogger.physical_history_session"] = nil
			local current = require("modules.keylogger.physical_history_session").init(32, function() end)
			helpers.assert_eq(c.ports.clock_ready({ version = 1, domain = "mach_absolute_time", numer = 1, denom = 1 }), true)
			helpers.assert_eq(arguments.configuration.n, 4)
			helpers.assert_eq(arguments.context.n, 5)
			helpers.assert_eq(type(arguments.context[5]), "function")
			for _, name in ipairs({ "engine", "system", "pause" }) do
				helpers.assert_eq(arguments[name].n, 5)
				helpers.assert_eq(arguments[name][5], true)
			end
			current.stop()
			helpers.assert_eq(current.retired(), true)
		end)
	end)
end)

--- Independently frozen initial observation controls, retained verbatim.
do
--- tests/unit/modules/keylogger/test_physical_history_session.lua

--- Exercises owned software subscriptions; no Mach, hardware or installation proof.
local helpers = require("tests.helpers")
local Lifetime = require("keylogger.physical_subscription_lifetime")
local Coordinator = require("keylogger.physical_history_coordinator")

local function fixture(options)
	options = options or {}
	local owner, controls = {}, { calls = {}, bindings = {}, refused = 0 }
	local clock_token, capture_token, time = {}, {}, 0
	local clock_life = Lifetime.new(owner, clock_token)
	clock_life.bind_detach(function() clock_life.detach(); return true end)
	local clock = clock_life.capability()
	clock.read = function(candidate, token)
		if options.clock_hook then options.clock_hook(controls) end
		if not clock.current(candidate, token) then return nil, "clock revoked" end
		time = time + 1
		return time
	end
	local capture = {
		identity = function() return capture_token end,
		current = function(token)
			if options.current_hook then options.current_hook(controls) end
			return token == capture_token and not controls.capture_revoked
		end,
		settled = function(token) return token == capture_token and controls.capture_settled == true end,
	}
	local binders = {}
	local function record(name, revision)
		time = time + 1
		if name == "configuration" then
			return { kind = "physical_configuration", revision = revision, at = time,
				disabled_apps = {}, private_filter_enabled = true, secure_field_filter_enabled = true,
				system_auth_filter_enabled = true }
		end
		if name == "context" then
			return { kind = "physical_context", revision = revision, at = time,
				source = "binding", stage = "boundary", complete = false, allowed = false }
		end
		return { kind = "physical_lifecycle", domain = name, revision = revision, at = time,
			source = "binding", stage = "boundary", complete = false, fields_complete = false, allowed = false }
	end
	for _, name in ipairs({ "configuration", "context", "engine", "system", "pause" }) do
		binders[name] = function(candidate, capacity, receive, refused)
			controls.calls[#controls.calls + 1] = name
			if options.throw_at == name then error("source bind failed") end
			local token, life = {}, nil
			life = Lifetime.new(candidate, token)
			life.bind_detach(function() life.detach(); return true end)
			local binding = { token = token, life = life, scope = life.capability(), receive = receive, refused = refused }
			controls.bindings[name] = binding
			local receipt = record(name, 1)
			local accepted = life.run(receive, receipt, token)
			if options.after_bootstrap then options.after_bootstrap(name, receipt, controls) end
			if options.fail_at == name then life.revoke(); return nil, "source bootstrap refused", binding.scope end
			if accepted ~= true then life.revoke(); return nil, "subscriber denied bootstrap", binding.scope end
			return token, nil, binding.scope
		end
	end
	local projection_life, projected = Lifetime.new(owner, {}), 0
	projection_life.bind_detach(function() projection_life.detach(); return true end)
	controls.projection_scope = projection_life.capability()
	local dependencies = { capture = capture, clock = clock, binders = binders,
		projection = function(history)
			controls.projected_after = #controls.calls
			controls.resolve = function(first, last) return history.resolve_interval(capture_token, clock_token, first, last) end
			if options.projection_hook then options.projection_hook(controls, history) end
			return {
				context = function()
					projected = projected + 1
					if options.projection_read_hook then options.projection_read_hook(controls) end
					return history.resolve_interval(capture_token, clock_token, 1, time)
				end,
				context_interval = function() return history.resolve_interval(capture_token, clock_token, 1, time) end,
				stop = projection_life.revoke,
				subscription = function() return controls.projection_scope end,
			}
		end,
		on_refused = function(reason)
			controls.refused = controls.refused + 1
			controls.reason = reason
			if options.refusal_hook then options.refusal_hook(controls) end
		end,
	}
	function controls.construct(capacity) controls.coordinator = Coordinator.new(owner, capacity or 32, dependencies); return controls.coordinator end
	function controls.send(name, receipt, token)
		local b = controls.bindings[name]
		return b.life.run(b.receive, receipt or record(name, 2), token or b.token)
	end
	function controls.record(name, revision) return record(name, revision) end
	function controls.projected() return projected end
	function controls.retire()
		controls.coordinator.stop()
		controls.capture_revoked, controls.capture_settled = true, true
		return controls.coordinator.retired()
	end
	controls.clock, controls.clock_life, controls.capture = clock, clock_life, capture
	return controls
end


local function with_native_session(callback)
	local names = { "modules.keylogger.physical_history_session", "adapters.physical_history_context",
		"adapters.physical_observation_clock", "modules.keylogger.physical_capture", "modules.keylogger",
		"modules.keylogger.context_tracker", "modules.keylogger.watchers", "modules.shortcuts.script_control",
		"adapters.shell_runner", "modules.keylogger.physical_key_identity", "modules.keylogger.log_manager" }
	helpers.with_fresh_modules(names, function()
		local c, time, subscriber = { calls = {}, stops = 0, releases = 0, refusals = 0, counts = {}, fifth = {} }, 0, nil
		local capture_token, clock_token = {}, {}
		local function sample() time = time + 1; return time end
		local clock_life
		local clock = { bind_history_scope = function(owner)
			subscriber = owner
			clock_life = Lifetime.new(owner, clock_token)
			clock_life.bind_detach(function() clock_life.detach(); return true end)
			local scope = clock_life.capability()
			scope.read = function() return sample() end
			return scope
		end }
		local capture = {
			init = function(ports) c.ports = ports; return true end,
			stop = function() c.stops = c.stops + 1; c.settled = true; return true end,
			bind_history_scope = function(owner)
				c.capture_owner = owner
				return true, {
					identity = function() return capture_token end,
					current = function(token) return token == capture_token and not c.settled end,
					admitted = function() return nil end,
					clock = function() return nil end,
					settled = function(token) return token == capture_token and c.settled == true end,
					release = function(candidate, token)
						if candidate ~= owner or token ~= capture_token or not c.settled then return false end
						if c.release_hook then c.release_hook() end
						c.releases = c.releases + 1
						return true
					end,
				}
			end,
		}
		local function binder(name, boolean_result)
			return function(owner, budget, receive, refused, ...)
				local persist = ...
				c.counts[name], c.fifth[name] = 4 + select("#", ...), persist
				c.calls[#c.calls + 1] = name
				if name == "context" then c.persist = persist end
				local token = {}
				local life = Lifetime.new(owner, token)
				life.bind_detach(function() life.detach(); return true end)
				local record
				if name == "configuration" then
					record = { kind = "physical_configuration", revision = 1, at = sample(), disabled_apps = {},
						private_filter_enabled = true, secure_field_filter_enabled = true, system_auth_filter_enabled = true }
				elseif name == "context" then
					record = { kind = "physical_context", revision = 1, at = sample(), source = "binding",
						stage = "boundary", complete = false, allowed = false }
				else
					record = { kind = "physical_lifecycle", domain = name, revision = 1, at = sample(), source = "binding",
						stage = "boundary", complete = false, fields_complete = false, allowed = false }
				end
				local accepted = life.run(receive, record, token)
				if accepted ~= true then life.revoke() end
				if boolean_result then return accepted, accepted and token or "refused", life.capability() end
				return accepted and token or nil, accepted and nil or "refused", life.capability()
			end
		end
		local may_persist = function() return true end
		local spawn, keycode, emit, emit_release = function() end, function() end, function() end, function() end
		local decode, encode = hs.json.decode, hs.json.encode
		package.loaded["adapters.physical_history_context"] = { new = function(owner, history)
			c.history, c.projected_owner = history, owner
			local Accepted = require("keylogger.physical_accepted_context")
			return Accepted.new(owner, { current = function() return true end, revision = history.retained_count,
				convert = tonumber, calendar = function() error("denied fixture must not sample wall") end,
				resolve_interval = function(first, last) return history.resolve_interval(capture_token, clock_token, first, last) end,
				on_refused = function() history.stop(capture_token) end })
		end }
		package.loaded["adapters.physical_observation_clock"] = clock
		package.loaded["modules.keylogger.physical_capture"] = capture
		package.loaded["modules.keylogger"] = { bind_physical_configuration_observer = binder("configuration", true),
			bind_physical_lifecycle_observer = binder("engine"), may_persist = may_persist }
		package.loaded["modules.keylogger.context_tracker"] = { bind_physical_correlated_context_observer = binder("context", true) }
		package.loaded["modules.keylogger.watchers"] = { bind_physical_lifecycle_observer = binder("system") }
		package.loaded["modules.shortcuts.script_control"] = { bind_physical_pause_observer = binder("pause") }
		package.loaded["adapters.shell_runner"] = { spawn = spawn }
		package.loaded["modules.keylogger.physical_key_identity"] = { resolve = keycode }
		package.loaded["modules.keylogger.log_manager"] = { log_physical_press = emit, log_physical_release = emit_release }
		local adapter = require("modules.keylogger.physical_history_session")
		local session = adapter.init(32, function() c.refusals = c.refusals + 1 end)
		c.adapter, c.expected = adapter, { spawn = spawn, decode = decode, encode = encode,
			keycode = keycode, emit = emit, emit_release = emit_release, may_persist = may_persist }
		callback(session, c)
	end)
end


local function point(name)
 local r = { source = "initial_snapshot", stage = "observed", complete = false,
  fields_complete = true, observation_complete = true, qualification = "observed", settled = true }
 if name == "pause" then
  r.paused, r.transition_generation, r.admission_released = false, 3, true
 else
  r.enabled, r.paused = true, false
  if name == "engine" then r.runtime_generation = 3
  else r.hardware_committed, r.hardware_generation, r.context_refresh_generation = true, 3, 4 end
 end
 return r
end
local function observed_case(options)
 options = options or {}
 local admission
 local c = fixture({ after_bootstrap = function(name, _, controls)
  if name == "engine" or name == "system" or name == "pause" then
   local r = controls.record(name, 2)
   for key, value in pairs(point(name)) do r[key] = value end
   if options.change then options.change(name, r) end
   -- Model an actually unknown generation rather than an inconsistent qualification tuple.
   if name == "engine" and r.observation_complete == false and r.settled == true then
    r.runtime_generation, r.fields_complete = nil, false
   end
   helpers.assert_eq(controls.send(name, r), true)
  end
 end })
 c.capture.admitted = function() return admission end
 local owner = c.construct()
 local revisions = { system = 2, context = 1 }
 local function pair(name, source, fields)
  for _, stage in ipairs({ "boundary", "complete" }) do
   revisions[name] = revisions[name] + 1
   local r = c.record(name, revisions[name])
   r.source, r.stage = source, stage
   r.complete, r.fields_complete = stage == "complete", stage == "complete"
   for key, value in pairs(fields) do
    if stage == "complete" or key == "event" or key == "component" or key == "value" then r[key] = value end
   end
   helpers.assert_eq(c.send(name, r), true)
  end
 end
 if not options.no_posture then
  for index, event in ipairs({ { "system_wake", "system_awake" }, { "screens_wake", "screen_awake" }, { "unlock", "unlocked" } }) do
   pair("system", event[1], { enabled = true, paused = false, hardware_committed = true,
    hardware_generation = 3, context_refresh_generation = 4, event = index, component = event[2], value = true })
  end
 end
 pair("context", "application", { correlated = true, allowed = true, private = false, secure = false,
  app = { name = "Independent Editor", bundle_id = "org.independent.editor", path = "/Independent.app", pid = 42 } })
 admission = "actual-incarnation:actual-lease"
 helpers.assert_eq(owner.capture_ready(), true)
 local first = c.record("configuration", 99).at
 return c, owner, first
end
helpers.describe("independent initial observed point consumption", function()
 helpers.it("opts in exactly the three lifecycle binders while preserving other native arguments", function()
  with_native_session(function(session, c)
   helpers.assert_eq(c.ports.clock_ready({ version = 1, domain = "mach_absolute_time", numer = 1, denom = 1 }), true)
   helpers.assert_eq(c.counts.configuration, 4); helpers.assert_eq(c.fifth.configuration, nil)
   helpers.assert_eq(c.counts.context, 5); helpers.assert_eq(rawequal(c.fifth.context, c.expected.may_persist), true)
   for _, name in ipairs({ "engine", "system", "pause" }) do
    helpers.assert_eq(c.counts[name], 5); helpers.assert_eq(c.fifth[name], true)
   end
   helpers.assert_eq(session.status().state, "bound")
   session.stop(); helpers.assert_eq(session.retired(), true)
  end)
 end)
 helpers.it("admits later ticks from observed engine and pause only after actual posture and baseline", function()
  local c, owner, first = observed_case()
  helpers.assert_eq(owner.status().state, "bound"); helpers.assert_eq(c.refused, 0)
  local result = c.resolve(first, first)
  helpers.assert_eq(result.allowed, true)
  helpers.assert_eq(result.app.name, "Independent Editor")
  helpers.assert_eq(c.retire(), true)
 end)
 helpers.it("leaves missing initial posture unqualified despite positive local point fields", function()
  local c, owner, first = observed_case({ no_posture = true })
  helpers.assert_eq(owner.status().state, "bound")
  helpers.assert_eq(owner.status().lifecycle_admission, "unqualified")
  helpers.assert_eq(c.resolve(first, first).allowed, false)
  helpers.assert_eq(c.retire(), true)
 end)
 helpers.it("cannot use pending pause observations to credit later input", function()
  local c, owner, first = observed_case({ change = function(name, r)
   if name == "pause" then r.settled, r.observation_complete, r.qualification = false, false, "unknown" end
  end })
  helpers.assert_eq(owner.status().state, "bound"); helpers.assert_eq(c.resolve(first, first).allowed, false)
  helpers.assert_eq(c.retire(), true)
 end)
 helpers.it("requires actual released admission even if the pause snapshot claims observed", function()
  local c, owner, first = observed_case({ change = function(name, r)
   if name == "pause" then r.admission_released = false end
  end })
  helpers.assert_eq(owner.status().state, "bound"); helpers.assert_eq(c.resolve(first, first).allowed, false)
  helpers.assert_eq(c.retire(), true)
 end)
 helpers.it("cannot infer local engine readiness from an unknown observation qualifier", function()
  local c, owner, first = observed_case({ change = function(name, r)
   if name == "engine" then r.observation_complete, r.qualification = false, "unknown" end
  end })
  helpers.assert_eq(owner.status().state, "bound"); helpers.assert_eq(c.resolve(first, first).allowed, false)
  helpers.assert_eq(c.retire(), true)
 end)
 helpers.it("requires explicit actual local engine settlement in the observed point", function()
  local c, owner, first = observed_case({ change = function(name, r)
   if name == "engine" then r.settled, r.observation_complete, r.qualification = false, false, "unknown" end
  end })
  helpers.assert_eq(owner.status().state, "bound"); helpers.assert_eq(c.resolve(first, first).allowed, false)
  helpers.assert_eq(c.retire(), true)
 end)
 helpers.it("never backdates a fully qualified observed point to delayed original ticks", function()
  local c, owner, first = observed_case()
  helpers.assert_eq(c.resolve(first, first).allowed, true)
  helpers.assert_eq(c.resolve(1, first).allowed, false)
  helpers.assert_eq(c.resolve(1, 1).allowed, false)
  helpers.assert_eq(c.retire(), true)
 end)
end)

end

helpers.describe("physical history synchronous initial observations", function()
	helpers.it("retains all copied initial snapshots before foreign binders return their exact scopes", function()
		local acknowledgements = {}
		local c = fixture({ after_bootstrap = function(name, _, controls)
			if name == "engine" or name == "system" or name == "pause" then
				local record = controls.record(name, 2)
				record.source, record.stage = "initial_snapshot", "observed"
				record.complete, record.fields_complete = false, true
				record.observation_complete, record.qualification, record.settled = true, "observed", true
				local fields = name == "engine" and initial_engine or name == "system" and initial_system or initial_pause
				for key, value in pairs(fields) do record[key] = value end
				acknowledgements[name] = controls.send(name, record)
				-- The source can reuse this public table only after its callback returned.
				record.qualification, record.observation_complete, record.settled = "unknown", false, false
				record.revision = 99
			end
		end })
		c.capture.admitted = function() return "actual-synchronous-baseline/7" end
		local owner = c.construct()
		for _, name in ipairs({ "engine", "system", "pause" }) do helpers.assert_eq(acknowledgements[name], true) end
		helpers.assert_eq(owner.status().state, "bound")
		helpers.assert_eq(owner.status().retained_count, 9)
		helpers.assert_eq(owner.status().lifecycle_admission, "unqualified")
		helpers.assert_eq(owner.capture_ready(), true)
		helpers.assert_eq(owner.context("1").allowed, false)
		local source = c.bindings.system
		local frame = source.life.enter()
		helpers.assert_eq(c.retire(), false)
		helpers.assert_eq(source.life.leave(frame), true)
		helpers.assert_eq(owner.retired(), true)
	end)
end)
