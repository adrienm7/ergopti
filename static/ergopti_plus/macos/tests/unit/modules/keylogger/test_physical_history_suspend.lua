--- tests/unit/modules/keylogger/test_physical_history_suspend.lua

--- Exercises real lease/accounting/dispatch ownership over explicitly modeled native leaves.
local helpers = require("tests.helpers")
local Lifetime = require("keylogger.physical_subscription_lifetime")

--- Borrowed byte-exact driver from the current 78-case session fixture.
local function with_managed_session(options, callback)
	options = options or {}
	local names = { "modules.keylogger.physical_history_session", "adapters.physical_history_context",
		"adapters.physical_observation_clock", "adapters.timer_scheduler", "keylogger.physical_lease_policy",
		"modules.keylogger", "modules.keylogger.context_tracker", "modules.keylogger.watchers",
		"modules.shortcuts.script_control", "adapters.shell_runner", "modules.keylogger.physical_key_identity",
		"modules.keylogger.log_manager", "modules.keylogger.physical_protocol", "modules.keylogger.physical_transport",
		"modules.keylogger.physical_delivery" }
	helpers.with_fresh_modules(names, function()
		require("tests.support.physical_capture_fixture").run(function(capture, observed, native)
			local previous_hs, ticks = hs, 0
			local d = { observed = observed, mode = native.mode, options = native.options, timers = {},
				actors = {}, bindings = {}, leases = {}, refusals = {}, native = native }
			local function sample() ticks = ticks + 1; return ticks end
			native.on_spawn = function(task)
				if task.executable == "/usr/bin/codesign" then
					d.leases[#d.leases + 1] = { base = #observed.tasks }
				end
			end
			local hs_model = { json = { decode = native.dependencies.decode, encode = native.dependencies.encode }, timer = {} }
			hs_model.timer.absoluteTime = sample
			function hs_model.timer.new(delay, callback_fn)
				local timer = { delay = delay, callback = callback_fn, starts = 0, stops = 0, running_value = false }
				d.timers[#d.timers + 1] = timer; timer.index = #d.timers
				function timer:start()
					self.starts = self.starts + 1
					if d.start_refusal == self.index then return false end
					self.running_value = true
					if d.fire_before_commit == self.index then self.callback() end
					return true
				end
				function timer:stop()
					self.stops = self.stops + 1
					if self.refuse_stop then return false end
					self.running_value = false
					return true
				end
				function timer:running() return self.running_value end
				return timer
			end
			hs = hs_model
			local function lifetime_source(name, boolean_result)
				return function(owner, _, receive, refused)
					local token, life = {}, nil
					life = Lifetime.new(owner, token)
					life.bind_detach(function() life.detach(); return true end)
					local binding = { owner = owner, token = token, life = life, scope = life.capability(),
						receive = receive, refused = refused, revision = 1 }
					d.bindings[name] = binding
					local receipt
					if name == "configuration" then
						receipt = { kind = "physical_configuration", revision = 1, at = sample(), disabled_apps = {},
							private_filter_enabled = true, secure_field_filter_enabled = true, system_auth_filter_enabled = true }
					else
						receipt = { kind = "physical_context", revision = 1, at = sample(), source = "binding",
							stage = "boundary", complete = false, allowed = false }
					end
					local ack = life.run(receive, receipt, token)
					if ack ~= true then life.revoke() end
					if boolean_result then return ack, ack == true and token or "fixture_binding_refused", binding.scope end
					return ack == true and token or nil, ack == true and nil or "fixture_binding_refused", binding.scope
				end
			end
			local Actor = require("keylogger.physical_lifecycle_observation")
			local fields = {
				engine = { enabled = true, paused = false, runtime_generation = 1, settled = true },
				system = { enabled = true, paused = false, hardware_committed = true, hardware_generation = 1,
					context_refresh_generation = 1, settled = true },
				pause = { paused = false, transition_generation = 1, admission_released = true, settled = true },
			}
			local function actor_source(name)
				local actor = Actor.new(name, sample, function(reason) d.actor_refusal = reason end)
				d.actors[name] = actor
				return function(owner, budget, receive, refused, initial)
					local token, reason, scope = actor.bind(owner, budget, receive, refused,
						initial == true and function() return fields[name] end or nil)
					d.bindings[name] = { owner = owner, token = token, scope = scope, actor = actor }
					return token, reason, scope
				end
			end
			package.loaded["modules.keylogger"] = { bind_physical_configuration_observer = lifetime_source("configuration", true),
				bind_physical_lifecycle_observer = actor_source("engine"), may_persist = function() return true end }
			package.loaded["modules.keylogger.context_tracker"] = { bind_physical_correlated_context_observer = lifetime_source("context", true),
				sample_physical_context = function(owner, token)
					local binding = d.bindings.context
					return binding ~= nil and binding.scope.current(owner, token) == true
				end }
			package.loaded["modules.keylogger.watchers"] = { bind_physical_lifecycle_observer = actor_source("system") }
			package.loaded["modules.shortcuts.script_control"] = { bind_physical_pause_observer = actor_source("pause") }
			package.loaded["adapters.shell_runner"] = { spawn = native.dependencies.spawn }
			package.loaded["modules.keylogger.physical_key_identity"] = { resolve = native.dependencies.keycode }
			package.loaded["modules.keylogger.log_manager"] = { log_physical_press = native.dependencies.emit,
				log_physical_release = native.dependencies.emit_release }
			local original_init = capture.init
			capture.init = function(ports)
				d.ports = ports
				if options.on_verdict then
					local verdict = ports.on_verdict
					ports.on_verdict = function(record) options.on_verdict(record, d); return verdict(record) end
				end
				return original_init(ports)
			end
			package.loaded["adapters.physical_history_context"] = { new = function(owner, history, scopes)
				local capture_token, clock_token = scopes.capture.identity(), scopes.clock.identity(owner)
				local cap_current, clk_current = scopes.capture.current, scopes.clock.current
				local Accepted = require("keylogger.physical_accepted_context")
				return Accepted.new(owner, {
					current = function() return cap_current(capture_token) and clk_current(owner, clock_token) end,
					revision = history.retained_count, convert = tonumber,
					calendar = function() return "2026-10-05 12:00:00.000" end,
					resolve_interval = function(first, last)
						return history.resolve_interval(capture_token, clock_token, first, last)
					end,
					on_refused = function() history.stop(capture_token) end,
				})
			end }
			function d.start()
				return d.manager.start(d.options)
			end
			local function current_task(offset)
				local lease = d.leases[#d.leases]
				assert(lease, "No modeled native lease")
				return assert(observed.tasks[lease.base + offset], "Missing actual owned task")
			end
			function d.verify() local task = current_task(0); task.done(0); task.settle() end
			function d.clock() local task = current_task(1); task.done(0, "clock\n", ""); task.settle() end
			function d.baseline() current_task(2).chunk(nil, "opened\npage\nready\n") end
			function d.loss(reason)
				native.frames.lost = { version = 1, kind = "lost", coverage = "complete", incarnation = "production-fixture", lease = "7", reason = reason }
				current_task(2).chunk(nil, "lost\n")
			end
			function d.settle_native(index)
				local lease = assert(d.leases[index or #d.leases])
				for offset = 0, 2 do
					local task = observed.tasks[lease.base + offset]
					if task and task.state ~= "settled" then task.done(0); if task.settle then task.settle() end end
				end
			end
			function d.hold_writer(domain) return d.actors[domain].begin(domain == "pause" and "pause" or (domain == "system" and "hardware_stop" or "stop")) end
			function d.finish_writer(domain, ticket) return d.actors[domain].finish(ticket, function() return fields[domain] end, true) end
			function d.fire(index) local timer = assert(d.timers[index]); if timer.running_value then timer.callback() end end
			function d.refuse_timer_start(index) d.start_refusal = index end
			function d.refuse_timer_stop(index, refuse) d.timers[index].refuse_stop = refuse end
			function d.posture()
				for event, row in ipairs({ { "system_wake", "system_awake" }, { "screens_wake", "screen_awake" }, { "unlock", "unlocked" } }) do
					d.actors.system.run({ source = row[1], event = event, component = row[2], value = true },
						function() return true end, function() return fields.system end)
				end
			end
			function d.context()
				local b = d.bindings.context
				for _, stage in ipairs({ "boundary", "complete" }) do
					b.revision = b.revision + 1
					b.life.run(b.receive, { kind = "physical_context", revision = b.revision, at = sample(), source = "application",
						stage = stage, complete = stage == "complete", allowed = stage == "complete", correlated = stage == "complete", fields_complete = stage == "complete",
						private = false, secure = false, app = { name = "Editor", bundle_id = "org.editor", path = "/Editor.app", pid = 42 } }, b.token)
				end
			end
			local ok, result = pcall(function()
				local adapter = require("modules.keylogger.physical_history_session")
				d.adapter = adapter
				local manager, reason
				if not options.omit_manager then
					manager, reason = adapter.init(128, function(message) d.refusals[#d.refusals + 1] = message end, { managed = true })
				end
				d.manager, d.reason = manager, reason
				callback(manager, d)
			end)
			hs = previous_hs
			if not ok then error(result, 0) end
		end)
	end)
end

local function running_timer(d, delay)
	for index, timer in ipairs(d.timers) do
		if timer.delay == delay and timer.running_value then return index end
	end
end
local function flush(d)
	-- Deliver at most one existing owner continuation; never poll a native source.
	local index = running_timer(d, 0)
	if index then d.fire(index) end
end
local function admit(d)
	helpers.assert_eq(d.start(), true)
	d.verify(); d.clock(); d.baseline()
end
local function finish(manager, d)
	manager.stop(); d.settle_native(); flush(d)
	helpers.assert_eq(manager.retired(), true)
end

helpers.describe("managed suspend and resume actual ownership", function()
	helpers.it("retains dormant initialization and resumes without acquiring a lease", function()
		with_managed_session({}, function(manager, d)
			helpers.assert_eq(manager.suspend(), true)
			helpers.assert_eq(manager.status().state, "suspended")
			helpers.assert_eq(manager.quiescent(), true)
			helpers.assert_eq(manager.retired(), false)
			helpers.assert_eq(manager.resume(), true)
			helpers.assert_eq(manager.status().state, "prepared")
			helpers.assert_eq(#d.observed.spawns, 0); helpers.assert_eq(#d.timers, 0)
			local duplicate, reason = d.adapter.init(128, function() end, { managed = true })
			helpers.assert_eq(duplicate, nil); helpers.assert_eq(reason, "physical_history_session_already_initialized")
			admit(d); finish(manager, d)
		end)
	end)
	helpers.it("accepts suspension without announcing native retirement or releasing GAP", function()
		with_managed_session({}, function(manager, d)
			admit(d); local old = manager.lease()
			helpers.assert_eq(manager.suspend(), true)
			helpers.assert_eq(manager.status().state, "suspending")
			helpers.assert_eq(manager.quiescent(), false); helpers.assert_eq(old.retired(), false)
			helpers.assert_eq(d.mode.credit_source(), "gap"); helpers.assert_eq(d.mode.legacy_credits(), false)
			helpers.assert_eq(running_timer(d, 600), nil)
			d.settle_native(); flush(d)
			helpers.assert_eq(manager.status().state, "suspended")
			helpers.assert_eq(manager.quiescent(), true); helpers.assert_eq(old.retired(), true)
			helpers.assert_eq(manager.retired(), false); helpers.assert_eq(d.mode.credit_source(), "gap")
			helpers.assert_eq(#d.leases, 1); finish(manager, d)
			helpers.assert_eq(d.mode.credit_source(), "legacy")
		end)
	end)
	helpers.it("holds one resume intent until genuine prior native settlement", function()
		with_managed_session({}, function(manager, d)
			admit(d); local old = manager.lease()
			helpers.assert_eq(manager.suspend(), true); helpers.assert_eq(manager.resume(), true)
			helpers.assert_eq(manager.resume(), true)
			helpers.assert_eq(#d.leases, 1); helpers.assert_eq(manager.quiescent(), false)
			d.settle_native(); flush(d)
			helpers.assert_eq(#d.leases, 2); helpers.assert_eq(old.retired(), true)
			helpers.assert_eq(manager.status().state, "starting")
			d.verify(); d.clock(); d.baseline()
			helpers.assert_eq(manager.status().state, "admitted")
			helpers.assert_eq(d.ports.context("1").allowed, false)
			helpers.assert_eq(#d.observed.credits, 0)
			old.stop(); helpers.assert_eq(manager.status().state, "admitted")
			finish(manager, d)
		end)
	end)
	helpers.it("waits for actual pause writer debt after native settlement", function()
		with_managed_session({}, function(manager, d)
			admit(d); local ticket = d.hold_writer("pause")
			helpers.assert_eq(manager.suspend(), true); helpers.assert_eq(manager.resume(), true)
			d.settle_native(); flush(d)
			helpers.assert_eq(#d.leases, 1); helpers.assert_eq(manager.quiescent(), false)
			local timers = #d.timers; flush(d); helpers.assert_eq(#d.timers, timers)
			d.finish_writer("pause", ticket); flush(d)
			helpers.assert_eq(#d.leases, 2); finish(manager, d)
		end)
	end)
	helpers.it("latches suspension and resume within an actual source callback frame", function()
		with_managed_session({}, function(manager, d)
			admit(d); local b = d.bindings.context; local inside, after_resume, quiescent
			b.life.run(function()
				inside = manager.suspend(); d.settle_native(); after_resume = manager.resume()
				quiescent = manager.quiescent()
			end)
			helpers.assert_eq(inside, true); helpers.assert_eq(after_resume, true)
			helpers.assert_eq(quiescent, false); helpers.assert_eq(#d.leases, 1)
			flush(d); helpers.assert_eq(#d.leases, 2); finish(manager, d)
		end)
	end)
	helpers.it("retains refused actual rotation timer cleanup and uses only its settlement event", function()
		with_managed_session({}, function(manager, d)
			admit(d); local index = running_timer(d, 600)
			d.refuse_timer_stop(index, true)
			helpers.assert_eq(manager.suspend(), true); helpers.assert_eq(manager.resume(), true)
			d.settle_native(); flush(d)
			helpers.assert_eq(#d.leases, 1); helpers.assert_eq(manager.quiescent(), false)
			helpers.assert_eq(d.timers[index].running_value, true)
			local timers = #d.timers; flush(d); helpers.assert_eq(#d.timers, timers)
			d.refuse_timer_stop(index, false); d.fire(index); flush(d)
			helpers.assert_eq(#d.leases, 2); finish(manager, d)
		end)
	end)
	helpers.it("preserves a reserved retry and its delay across a held interval", function()
		with_managed_session({}, function(manager, d)
			admit(d); d.loss("overflow"); d.settle_native(); flush(d)
			helpers.assert_eq(type(running_timer(d, 1)), "number")
			helpers.assert_eq(manager.suspend(), true)
			helpers.assert_eq(running_timer(d, 1), nil); helpers.assert_eq(manager.quiescent(), true)
			helpers.assert_eq(manager.status().retries_used, 1)
			helpers.assert_eq(manager.resume(), true)
			helpers.assert_eq(type(running_timer(d, 1)), "number")
			helpers.assert_eq(#d.leases, 1)
			d.fire(running_timer(d, 1)); helpers.assert_eq(#d.leases, 2)
			finish(manager, d)
		end)
	end)
	helpers.it("preserves lifetime retries one two four through successful off and on cycles", function()
		with_managed_session({}, function(manager, d)
			admit(d)
			for ordinal, delay in ipairs({ 1, 2, 4 }) do
				d.loss("interrupted")
				helpers.assert_eq(manager.suspend(), true); helpers.assert_eq(manager.resume(), true)
				d.settle_native(); flush(d)
				helpers.assert_eq(manager.status().retries_used, ordinal)
				helpers.assert_eq(type(running_timer(d, delay)), "number")
				d.fire(running_timer(d, delay)); d.verify(); d.clock(); d.baseline()
			end
			d.loss("overflow"); d.settle_native(); flush(d)
			helpers.assert_eq(manager.retired(), true); helpers.assert_eq(#d.leases, 4)
			helpers.assert_eq(manager.status().retries_used, 3)
			helpers.assert_eq(manager.resume(), false)
		end)
	end)
	helpers.it("preserves rotation six hundred without charging a retry after resume", function()
		with_managed_session({}, function(manager, d)
			admit(d); d.fire(running_timer(d, 600))
			helpers.assert_eq(manager.suspend(), true); helpers.assert_eq(manager.resume(), true)
			d.settle_native(); flush(d); helpers.assert_eq(#d.leases, 2)
			d.verify(); d.clock(); d.baseline()
			helpers.assert_eq(type(running_timer(d, 600)), "number")
			helpers.assert_eq(running_timer(d, 1), nil)
			helpers.assert_eq(manager.status().retries_used, 0); finish(manager, d)
		end)
	end)
	helpers.it("lets a later suspension replace an unfulfilled resume intent", function()
		with_managed_session({}, function(manager, d)
			admit(d); helpers.assert_eq(manager.suspend(), true); helpers.assert_eq(manager.resume(), true)
			helpers.assert_eq(manager.suspend(), true)
			d.settle_native(); flush(d)
			helpers.assert_eq(manager.quiescent(), true); helpers.assert_eq(#d.leases, 1)
			helpers.assert_eq(manager.resume(), true); helpers.assert_eq(#d.leases, 2)
			finish(manager, d)
		end)
	end)
	helpers.it("keeps terminal shutdown dominant over both intents and genuinely releases selection", function()
		with_managed_session({}, function(manager, d)
			admit(d); helpers.assert_eq(manager.suspend(), true); helpers.assert_eq(manager.resume(), true)
			local inside, calls = nil, 0
			helpers.assert_eq(manager.stop(function(value) calls = calls + 1; inside = { value, manager.retired(), manager.resume() } end), true)
			helpers.assert_eq(manager.suspend(), false); helpers.assert_eq(manager.resume(), false)
			d.settle_native(); flush(d)
			helpers.assert_eq(calls, 1); helpers.assert_eq(inside[1], true)
			helpers.assert_eq(inside[2], false); helpers.assert_eq(inside[3], false)
			helpers.assert_eq(manager.retired(), true); helpers.assert_eq(#d.leases, 1)
			helpers.assert_eq(d.mode.credit_source(), "legacy")
		end)
	end)
	helpers.it("keeps no-op resume from changing original admitted behavior", function()
		with_managed_session({}, function(manager, d)
			admit(d); local timers = #d.timers
			helpers.assert_eq(manager.resume(), true); helpers.assert_eq(manager.resume(), true)
			helpers.assert_eq(manager.status().state, "admitted"); helpers.assert_eq(#d.timers, timers)
			helpers.assert_eq(manager.quiescent(), false); helpers.assert_eq(#d.leases, 1)
			finish(manager, d)
		end)
	end)
end)

--- Additional production-callsite obligations frozen after the first draft, before refinement.
helpers.describe("managed suspension during actual acquisition and accounting debt", function()
	helpers.it("resumes a stopped opening lease only after actual candidate settlement", function()
		with_managed_session({}, function(manager, d)
			helpers.assert_eq(d.start(), true); helpers.assert_eq(#d.observed.spawns, 1)
			helpers.assert_eq(manager.suspend(), true); helpers.assert_eq(manager.resume(), true)
			helpers.assert_eq(manager.quiescent(), false); helpers.assert_eq(#d.leases, 1)
			d.settle_native(); flush(d)
			helpers.assert_eq(#d.leases, 2); helpers.assert_eq(manager.status().state, "starting")
			helpers.assert_eq(manager.status().retries_used, 0); helpers.assert_eq(d.mode.credit_source(), "gap")
			finish(manager, d)
		end)
	end)
	helpers.it("retains real refused accounting interruption after actual native settlement", function()
		with_managed_session({}, function(manager, d)
			local permit = true
			helpers.assert_eq(d.mode.bind_settlement({}, function() return permit end), true)
			admit(d); permit = false
			helpers.assert_eq(manager.suspend(), true); helpers.assert_eq(manager.resume(), true)
			d.settle_native(); flush(d)
			helpers.assert_eq(manager.quiescent(), false); helpers.assert_eq(manager.retired(), false)
			helpers.assert_eq(#d.leases, 1); helpers.assert_eq(d.mode.legacy_credits(), false)
			helpers.assert_eq(d.ports.context("1").allowed, false)
			permit = true; helpers.assert_eq(manager.resume(), true); flush(d)
			helpers.assert_eq(#d.leases, 2); helpers.assert_eq(d.mode.credit_source(), "gap")
			finish(manager, d)
		end)
	end)
end)

local function policy_fixture()
	local owner, native, control = {}, {}, { retired = false, calls = 0 }
	local p = require("keylogger.physical_lease_policy").new(owner, {
		current = function() control.calls = control.calls + 1; if control.hook then control.hook() end; return true end,
		lease_identity = function() return native end,
		retired = function() control.retire_calls = (control.retire_calls or 0) + 1; return control.retired end,
	})
	local function begin()
		local request = p.begin(owner); helpers.assert_eq(type(request), "table")
		helpers.assert_eq(p.captured(owner, request, native), true)
		return request
	end
	return p, owner, native, control, begin
end
helpers.describe("shared held lease policy boundaries", function()
	helpers.it("holds prepared state without querying nonexistent lease retirement", function()
		local p, owner, _, c = policy_fixture()
		helpers.assert_eq(p.suspend(owner).action, "hold"); helpers.assert_eq(p.status().state, "suspended")
		helpers.assert_eq(p.resume(owner).action, "ready"); helpers.assert_eq(p.status().state, "prepared")
		helpers.assert_eq(c.retire_calls, nil)
	end)
	helpers.it("refuses foreign owners without querying source ports", function()
		local p, _, _, c = policy_fixture()
		helpers.assert_eq(p.suspend({}), nil); helpers.assert_eq(p.resume({}), nil)
		helpers.assert_eq(c.calls, 0); helpers.assert_eq(p.status().state, "prepared")
	end)
	helpers.it("retains resume intent until a literal genuine old request retirement", function()
		local p, owner, _, c, begin = policy_fixture(); local request = begin()
		helpers.assert_eq(p.suspend(owner).action, "retire"); helpers.assert_eq(p.resume(owner).action, "hold")
		local action, reason = p.continue(owner, request)
		helpers.assert_eq(action, nil); helpers.assert_eq(reason, "policy_retirement_pending")
		c.retired = "true"; helpers.assert_eq(p.continue(owner, request), nil)
		c.retired = true; helpers.assert_eq(p.continue(owner, request).action, "start")
		helpers.assert_eq(p.status().state, "prepared"); helpers.assert_eq(p.status().retries, 0)
	end)
	helpers.it("keeps a held lease parked after genuine retirement without resume", function()
		local p, owner, _, c, begin = policy_fixture(); local request = begin()
		p.suspend(owner); c.retired = true
		helpers.assert_eq(p.continue(owner, request).action, "hold")
		helpers.assert_eq(p.status().state, "suspended")
		helpers.assert_eq(p.begin(owner), nil); helpers.assert_eq(p.resume(owner).action, "start")
	end)
	helpers.it("keeps the same pending backoff and total retries through repeated parking", function()
		local p, owner, native, c, begin = policy_fixture(); c.retired = true
		for ordinal, delay in ipairs({ 1, 2, 4 }) do
			local request = begin(); p.admitted(owner, request, native)
			p.verdict(owner, request, { state = "lost", reason = "overflow", retryable = true, lease_token = native })
			p.suspend(owner); p.continue(owner, request)
			helpers.assert_eq(p.status().retries, ordinal)
			local retry = p.resume(owner); helpers.assert_eq(retry.action, "retry"); helpers.assert_eq(retry.delay, delay)
			p.suspend(owner); p.continue(owner, request)
			helpers.assert_eq(p.resume(owner).delay, delay); p.retry_ready(owner, request)
		end
		local request = begin()
		p.verdict(owner, request, { state = "lost", reason = "overflow", retryable = true, lease_token = native })
		p.suspend(owner); p.continue(owner, request)
		helpers.assert_eq(p.resume(owner).action, "deny"); helpers.assert_eq(p.status().retries, 3)
	end)
	helpers.it("lets suspension cancel resume intent without reopening a request", function()
		local p, owner, _, c, begin = policy_fixture(); local request = begin()
		p.suspend(owner); p.resume(owner); p.suspend(owner); c.retired = true
		helpers.assert_eq(p.continue(owner, request).action, "hold")
		helpers.assert_eq(p.status().state, "suspended")
	end)
	helpers.it("keeps terminal stop permanent after an accepted resume", function()
		local p, owner, _, c, begin = policy_fixture(); local request = begin()
		p.suspend(owner); p.resume(owner); p.stop(owner); c.retired = true
		helpers.assert_eq(p.resume(owner), nil); helpers.assert_eq(p.suspend(owner), nil)
		helpers.assert_eq(p.continue(owner, request), nil); helpers.assert_eq(p.status().state, "stopped")
	end)
	helpers.it("refuses reentrant suspension source validation without reviving authority", function()
		local p, owner, _, c = policy_fixture()
		c.hook = function() p.stop(owner) end
		helpers.assert_eq(p.suspend(owner), nil); helpers.assert_eq(p.resume(owner), nil)
		helpers.assert_eq(p.begin(owner), nil)
	end)
	helpers.it("rejects stale continuation requests with zero retirement calls", function()
		local p, owner, _, c, begin = policy_fixture(); begin(); p.suspend(owner)
		helpers.assert_eq(p.continue(owner, {}), nil); helpers.assert_eq(c.retire_calls, nil)
	end)
end)
