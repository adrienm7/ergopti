--- tests/unit/adapters/test_physical_history_context.lua

--- Portable controls: real History/Capture callsites and modeled native ports.
--- C os.time/date exercise binding shape, not Hammerspoon/Mach qualification.
local helpers = require("tests.helpers")
local History = require("keylogger.physical_permission_history")
local Accepted = require("keylogger.physical_accepted_context")
local Fixture = require("tests.support.physical_capture_fixture")

local function policy(capture_token, clock_token, current)
	local f = { revisions = {}, observers = {}, retirement = {}, refusals = {} }
	for _, name in ipairs({ "configuration", "context", "lifecycle", "pause", "capture" }) do
		f.observers[name], f.revisions[name] = {}, 0
	end
	for _, name in ipairs({ "configuration", "context", "lifecycle", "pause", "capture", "clock" }) do
		f.retirement[name] = { token = {}, settled = function() return false end }
	end
	f.history = History.new(64, { capture = capture_token, clock = clock_token, observers = f.observers,
		retirement = f.retirement, current = current or function() return true end,
		receive = function() return true end, on_refused = function(reason) f.refusals[#f.refusals + 1] = reason end })
	function f.observe(lane, at, record)
		f.revisions[lane] = f.revisions[lane] + 1
		record.kind, record.at, record.revision = "physical_" .. lane, at, f.revisions[lane]
		return f.history.observe(capture_token, clock_token, lane, f.observers[lane], record)
	end
	f.observe("configuration", 1, { private_filter_enabled = true, secure_field_filter_enabled = true,
		system_auth_filter_enabled = true, disabled_apps = {} })
	f.observe("context", 2, { source = "activation", stage = "boundary", complete = false, allowed = false })
	f.observe("context", 3, { source = "activation", stage = "complete", complete = true, fields_complete = true,
		correlated = true, allowed = true, private = false, secure = false,
		app = { name = "Original", bundle_id = "test.original", path = "/Original.app", pid = 42 } })
	for index, lane in ipairs({ "lifecycle", "pause", "capture" }) do
		f.observe(lane, 3 + index, { complete = true, allowed = true })
	end
	return f
end

local function with_projection(callback)
	local capture_token, clock_token, owner = {}, {}, {}
	local f = policy(capture_token, clock_token)
	f.calendars, f.notifications = 0, {}
	f.date, f.current = "2026-10-04 23:59:59.500", true
	local ports = { current = function() if f.on_current then f.on_current() end; return f.current end, convert = function(ticks) return tonumber(ticks) end,
		resolve_interval = function(first, last) return f.history.resolve_interval(capture_token, clock_token, first, last) end,
		revision = f.history.retained_count,
		calendar = function()
			f.calendars = f.calendars + 1
			if f.on_calendar then return f.on_calendar() end
			return f.date
		end,
		on_refused = function(reason) f.notifications[#f.notifications + 1] = reason; f.history.stop(capture_token) end }
	f.projection = Accepted.new(owner, ports)
	f.subscription = f.projection.subscription(); f.owner = owner; f.token = f.subscription.identity(owner)
	callback(f)
end

local function with_native(callback, options)
	options = options or {}
	helpers.with_fresh_modules({ "adapters.physical_observation_clock", "adapters.physical_history_context" }, function()
		local previous = hs
		hs = { timer = { absoluteTime = os.time, secondsSinceEpoch = os.time } }
		local ok, reason = pcall(function()
			Fixture.run(function(capture, observed, controls)
				local owner = {}
				local clock = require("adapters.physical_observation_clock").bind_history_scope(owner)
				local clock_token = clock.identity(owner)
				local f = { capture = capture, controls = controls, observed = observed, owner = owner, clock = clock }
				controls.dependencies.context = function(ticks)
					return f.projection and f.projection.context(ticks) or { allowed = false }
				end
				controls.dependencies.context_interval = function(first, last)
					return f.projection and f.projection.context_interval(first, last) or { allowed = false }
				end
				controls.dependencies.clock_ready = function(info)
					local accepted, scope = capture.bind_history_scope(owner)
					f.bound, f.scope = accepted, scope
					if not accepted then return false end
					f.policy = policy(scope.identity(), clock_token, function()
						return scope.current(scope.identity()) and clock.current(owner, clock_token)
					end)
					if options.before_constructor then options.before_constructor(f, info) end
					f.projection, f.reason = require("adapters.physical_history_context").new(owner, f.policy.history,
						{ capture = scope, clock = clock }, info)
					if options.on_ready then options.on_ready(f) end
					return f.projection ~= nil
				end
				function f.begin() capture.init(controls.dependencies); return capture.start(controls.options) end
				function f.ready() f.begin(); controls.verified(); controls.open() end
				function f.deliver(records)
					controls.frames.accepted_batch = { version = 1, kind = "batch", coverage = "complete",
						incarnation = controls.frames.opened.incarnation, lease = controls.frames.opened.lease, records = records }
					observed.tasks[3].chunk(nil, "accepted_batch\n")
				end
				function f.native_calls(operation)
					local calls = 0
					debug.sethook(function(event)
						if event == "call" and rawequal(debug.getinfo(2, "f").func, os.time) then calls = calls + 1 end
					end, "c")
					local ran, result = pcall(operation)
					debug.sethook()
					if not ran then error(result, 0) end
					return calls, result
				end
				callback(f)
				clock.detach(owner, clock_token)
			end)
		end)
		hs = previous
		debug.sethook()
		if not ok then error(reason, 0) end
	end)
end

local function row(sequence, ticks, down)
	return { sequence = tostring(sequence), timestamp = tostring(ticks), value = down and "1" or "0",
		device = "41", has_page = true, has_usage = true, page = 7, usage = 44, has_cookie = true, cookie = 44 }
end

helpers.describe("accepted physical History context", function()
	helpers.it("samples the acceptance calendar only after original History permission", function()
		with_projection(function(f)
			helpers.assert_eq(f.projection.context("20"), { allowed = true, app = "Original", timestamp = f.date })
			f.observe("pause", 30, { complete = true, allowed = false })
			helpers.assert_eq(f.projection.context("40"), { allowed = false })
			helpers.assert_eq(f.projection.context("0"), { allowed = false })
			helpers.assert_eq(f.calendars, 1)
		end)
	end)
	helpers.it("cancels an entire crossed original hold without a release calendar", function()
		with_projection(function(f)
			f.observe("pause", 30, { complete = true, allowed = false })
			f.observe("pause", 40, { complete = true, allowed = true })
			helpers.assert_eq(f.projection.context_interval("20", "50"), { allowed = false })
			helpers.assert_eq(f.projection.context_interval("40", "50"), { allowed = true })
			helpers.assert_eq(f.calendars, 0)
		end)
	end)
	helpers.it("retains real foreign frame debt through exact detach", function()
		with_projection(function(f)
			local inner
			f.on_calendar = function()
				local detached = f.subscription.detach(f.owner, f.token)
				inner = { detached = detached, retired = f.subscription.retired(f.owner, f.token) }
				return f.date
			end
			helpers.assert_eq(f.projection.context("20"), { allowed = false })
			helpers.assert_eq(inner, { detached = true, retired = false })
			helpers.assert_eq(f.subscription.retired(f.owner, f.token), true)
		end)
	end)
	helpers.it("keeps a caught reentry denied and retains the original raised object", function()
		with_projection(function(f)
			local inner
			f.on_calendar = function() inner = f.projection.context("20"); return f.date end
			helpers.assert_eq(f.projection.context("20"), { allowed = false })
			helpers.assert_eq(inner, { allowed = false }); helpers.assert_eq(#f.notifications, 1)
		end)
		with_projection(function(f)
			local marker = {}; f.on_calendar = function() error(marker, 0) end
			local ok, reason = pcall(f.projection.context, "20")
			helpers.assert_eq(ok, false); helpers.assert_true(rawequal(reason, marker))
			helpers.assert_eq(f.projection.context("20"), { allowed = false })
		end)
	end)
	helpers.it("rejects history mutation during acceptance and foreign detach identities", function()
		with_projection(function(f)
			local foreign = setmetatable({}, { __eq = function() error("Must use raw identity") end })
			helpers.assert_eq(f.subscription.detach(foreign, f.token), false)
			helpers.assert_eq(f.subscription.retired(f.owner, foreign), false)
			f.on_calendar = function() f.observe("pause", 50, { complete = true, allowed = false }); return f.date end
			helpers.assert_eq(f.projection.context("20"), { allowed = false })
		end)
	end)
	helpers.it("acquires context during actual clock ACK without unpublished clock pulls", function()
		local pulls, early
		with_native(function(f)
			f.ready()
			helpers.assert_eq(f.bound, true); helpers.assert_eq(pulls, 0); helpers.assert_eq(early, { allowed = false })
			helpers.assert_eq(f.projection.context("3").app, "Original")
		end, { before_constructor = function(f)
			local original = f.scope.clock; pulls = 0
			f.scope.clock = function(...) pulls = pulls + 1; return original(...) end
		end, on_ready = function(f) early = f.projection.context("3") end })
	end)
	helpers.it("feeds actual Capture ports and freezes the initial accepted date for release", function()
		with_native(function(f)
			f.ready()
			local calls = f.native_calls(function() f.deliver({ row(1, 24000000, true) }) end)
			helpers.assert_eq(calls, 3); helpers.assert_eq(#f.observed.credits, 1)
			local accepted = f.observed.credits[1].timestamp
			helpers.assert_true(accepted:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%.000$") ~= nil)
			f.observed.credits[1].app, f.observed.credits[1].timestamp = "Changed", "changed"
			local release_calls = f.native_calls(function() f.deliver({ row(2, 30120000, false) }) end)
			helpers.assert_eq(release_calls, 0)
			helpers.assert_eq(f.observed.releases, { { capture = "production-fixture/7", device = "41", keycode = 49,
				app = "Original", timestamp = accepted, hold_ms = 255 } })
		end)
	end)
	helpers.it("denies incomplete baseline and denied History without native calendar reads", function()
		with_native(function(f)
			f.begin(); f.controls.verified(); f.controls.clocked()
			f.observed.tasks[3].chunk(nil, "opened\n")
			local calls, result = f.native_calls(function() return f.projection.context("3") end)
			helpers.assert_eq(calls, 0); helpers.assert_eq(result, { allowed = false })
			f.observed.tasks[3].chunk(nil, "page\nready\n")
			f.policy.observe("pause", 10, { complete = true, allowed = false })
			calls, result = f.native_calls(function() return f.projection.context("3") end)
			helpers.assert_eq(calls, 0); helpers.assert_eq(result, { allowed = false })
		end)
	end)
	helpers.it("refuses mismatched native scale and permanently refuses restored wall bindings", function()
		with_native(function(f)
			f.ready(); helpers.assert_eq(f.projection.context("3"), { allowed = false })
		end, { before_constructor = function(_, info) info.numer = 1 end })
		with_native(function(f)
			f.ready(); local original = hs.timer.secondsSinceEpoch
			hs.timer.secondsSinceEpoch = os.clock
			helpers.assert_eq(f.projection.context("3"), { allowed = false })
			hs.timer.secondsSinceEpoch = original
			helpers.assert_eq(f.projection.context("3"), { allowed = false })
		end)
	end)
	helpers.it("refuses missing C wall/date bindings without a fallback or new acquisition", function()
		with_native(function(f)
			f.begin(); f.controls.verified(); f.controls.clocked()
			helpers.assert_eq(f.projection, nil); helpers.assert_eq(f.reason, "accepted_native_calendar_unavailable")
			helpers.assert_eq(f.capture.status().state, "unavailable"); helpers.assert_eq(f.observed.credits, {})
		end, { before_constructor = function() hs.timer.secondsSinceEpoch = function() return 0 end end })
	end)
	helpers.it("retains the accepted initial calendar across later calendar changes", function()
		with_projection(function(f)
			local Frames = require("tests.support.physical_stream_frames")
			local Delivery = require("modules.keylogger.physical_delivery")
			local presses, releases = {}, {}
			local frames = Frames.new("accepted-calendar", "8", { "41" })
			local receiver = Delivery.new({ batch_limit = 4, admit = function() return "accepted-calendar/8" end,
				context = f.projection.context, keycode = Frames.keycode,
				emit = function(press) presses[#presses + 1] = press; return true end,
				holds = { convert = tonumber, context = f.projection.context_interval,
					emit = function(release) releases[#releases + 1] = release; return true end } })
			Frames.start(receiver, frames)
			local function batch(record) return { version = 1, kind = "batch", incarnation = "accepted-calendar",
				lease = "8", coverage = frames.opened.coverage, records = { record } } end
			receiver.deliver(batch(row(1, 1000000000, true)))
			f.date = "2026-10-05 00:00:00.500"
			receiver.deliver(batch(row(2, 1255000000, false)))
			helpers.assert_eq(presses[1].timestamp, "2026-10-04 23:59:59.500")
			helpers.assert_eq(releases[1].timestamp, presses[1].timestamp)
			helpers.assert_eq(releases[1].app, "Original"); helpers.assert_eq(releases[1].hold_ms, 255)
			helpers.assert_eq(f.calendars, 1)
		end)
	end)
	helpers.it("gates actual synchronous opening and input before Capture.start returns", function()
		with_native(function(f)
			local starting, seen_before_return = true, false
			local original_emit = f.controls.dependencies.emit
			f.controls.dependencies.emit = function(press)
				seen_before_return = starting
				return original_emit(press)
			end
			f.controls.on_spawn = function(task)
				local command = task.arguments[1]
				task.start = function()
					task.started, task.state = true, "running"
					if command == "--verify" then task.done(0); task.settle()
					elseif command == "--hs274-clock" then task.done(0, "clock\n", ""); task.settle()
					else
						f.controls.frames.accepted_batch = { version = 1, kind = "batch", coverage = "complete",
							incarnation = f.controls.frames.opened.incarnation, lease = f.controls.frames.opened.lease,
							records = { row(1, 24000000, true) } }
						task.chunk(nil, "opened\npage\nready\naccepted_batch\n")
					end
					return true
				end
			end
			local accepted = f.begin(); starting = false
			helpers.assert_eq(accepted, true); helpers.assert_eq(f.bound, true)
			helpers.assert_eq(seen_before_return, true); helpers.assert_eq(#f.observed.credits, 1)
			helpers.assert_eq(f.observed.credits[1].app, "Original")
		end)
	end)
	helpers.it("fences revoked capture after the first native read before any wall read", function()
		with_native(function(f)
			f.ready()
			local calls, debt = 0, nil
			local subscription = f.projection.subscription(); local token = subscription.identity(f.owner)
			debug.sethook(function(event)
				if event == "call" and rawequal(debug.getinfo(2, "f").func, os.time) then
					calls = calls + 1
					if calls == 1 then
						f.capture.stop()
						local detached = subscription.detach(f.owner, token)
						debt = { detached = detached, retired = subscription.retired(f.owner, token) }
					end
				end
			end, "c")
			local ok = pcall(f.projection.context, "3")
			debug.sethook()
			helpers.assert_eq(ok, false); helpers.assert_eq(calls, 1)
			helpers.assert_eq(debt, { detached = true, retired = false })
			helpers.assert_eq(subscription.retired(f.owner, token), true)
			helpers.assert_eq(f.scope.settled(f.scope.identity()), false)
			helpers.assert_eq(f.observed.tasks[3].stops, 1)
		end)
	end)

	helpers.it("selects the historical original app despite a later allowed current app", function()
		with_native(function(f)
			f.ready()
			f.policy.observe("context", 200, { source = "activation", stage = "boundary", complete = false, allowed = false })
			f.policy.observe("context", 201, { source = "activation", stage = "complete", complete = true, fields_complete = true,
				correlated = true, allowed = true, private = false, secure = false,
				app = { name = "Later", bundle_id = "test.later", path = "/Later.app", pid = 43 } })
			helpers.assert_eq(f.projection.context("3").app, "Original")
			helpers.assert_eq(f.projection.context("6").app, "Later")
		end)
	end)

	helpers.it("rechecks history after the final foreign current observation", function()
		with_projection(function(f)
			local reads = 0
			f.on_current = function()
				reads = reads + 1
				if reads == 5 then f.observe("pause", 20, { complete = true, allowed = false }) end
			end
			helpers.assert_eq(f.projection.context("20"), { allowed = false })
			helpers.assert_eq(f.calendars, 1)
		end)
	end)

end)

helpers.describe("Accepted context private authority", function()
	helpers.it("cannot revive a stopped projection by replacing public capability observations", function()
		with_projection(function(f)
			f.subscription.current = function() return true end
			f.subscription.retired = function() return true end
			f.projection.stop()
			helpers.assert_eq(f.projection.context("20"), { allowed = false })
			helpers.assert_eq(f.projection.context_interval("20", "25"), { allowed = false })
			helpers.assert_eq(f.calendars, 0)
		end)
	end)

	helpers.it("keeps in-flight stop denied despite a replaced public current method", function()
		with_projection(function(f)
			local original_retired = f.subscription.retired
			local detached, retired_inside
			f.on_calendar = function()
				f.projection.stop()
				f.subscription.current = function() return true end
				detached = f.subscription.detach(f.owner, f.token)
				retired_inside = original_retired(f.owner, f.token)
				return f.date
			end
			local decision = f.projection.context("20")
			helpers.assert_eq(decision, { allowed = false })
			helpers.assert_eq(detached, true)
			helpers.assert_eq(retired_inside, false)
			helpers.assert_eq(original_retired(f.owner, f.token), true)
			helpers.assert_eq(f.calendars, 1)
		end)
	end)
end)

helpers.describe("Accepted context generic source fences", function()
local Subject = Accepted
local check = helpers.it
local function fixture()
    local owner, trace = {}, {}
    local state = { active = true, revision = 7, calendar_calls = 0, refused = 0,
        stamp = '2024-01-02 01:00:00.125', decision = true }
    local app = { name = 'Historical App A', bundle_id = 'test.history.a', path = '/private/test/A.app', pid = 17 }
    local ports = {}
    ports.current = function() trace[#trace + 1] = 'current'; return state.active end
    ports.convert = function(ticks) trace[#trace + 1] = 'convert'; return tonumber(ticks) * 1000000 end
    ports.resolve_interval = function(first, last)
        trace[#trace + 1] = 'history'; state.first, state.last = first, last
        return state.decision and { allowed = true, app = app } or { allowed = false }
    end
    ports.revision = function() trace[#trace + 1] = 'revision'; return state.revision end
    ports.calendar = function()
        trace[#trace + 1] = 'calendar'; state.calendar_calls = state.calendar_calls + 1
        return state.stamp
    end
    ports.on_refused = function(reason) state.refused = state.refused + 1; state.reason = reason end
    return owner, ports, state, app, trace
end
local function count(trace, value) local n = 0; for _, v in ipairs(trace) do if v == value then n = n + 1 end end; return n end
check('revocation in revision fences the next foreign conversion', function()
    local owner, ports, state, app, trace = fixture()
    ports.revision = function() state.active = false; return state.revision end
    local projection = Subject.new(owner, ports)
    local decision = projection.context('100')
    assert(decision.allowed == false)
    assert(count(trace, 'convert') == 0 and count(trace, 'history') == 0 and state.calendar_calls == 0)
end)
check('whole interval revocation after first conversion fences second foreign call', function()
    local owner, ports, state = fixture()
    local calls = 0
    ports.convert = function(ticks)
        calls = calls + 1; state.active = false
        return tonumber(ticks) * 1000000
    end
    local projection = Subject.new(owner, ports)
    local decision = projection.context_interval('100', '900')
    assert(decision.allowed == false and calls == 1 and state.calendar_calls == 0)
end)
check('last press revision revocation denies unchanged-count permission', function()
    local owner, ports, state = fixture()
    local reads = 0
    ports.revision = function()
        reads = reads + 1
        if reads == 3 then state.active = false end
        return state.revision
    end
    local projection = Subject.new(owner, ports)
    local decision = projection.context('100')
    assert(reads == 3 and state.active == false)
    assert(decision.allowed == false)
end)
check('last interval revision revocation denies unchanged-count permission', function()
    local owner, ports, state = fixture()
    local reads = 0
    ports.revision = function()
        reads = reads + 1
        if reads == 2 then state.active = false end
        return state.revision
    end
    local projection = Subject.new(owner, ports)
    local decision = projection.context_interval('100', '900')
    assert(reads == 2 and state.active == false and state.calendar_calls == 0)
    assert(decision.allowed == false)
end)
end)
