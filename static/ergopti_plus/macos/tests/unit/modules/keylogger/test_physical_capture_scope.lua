--- tests/unit/modules/keylogger/test_physical_capture_scope.lua

--- Independent exact-session controls; native hardware admission is not claimed.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.physical_capture_fixture")
local Delivery = require("modules.keylogger.physical_delivery")
local Frames = require("tests.support.physical_stream_frames")

local function begin(capture, controls)
	helpers.assert_eq(capture.init(controls.dependencies), true)
	helpers.assert_eq(capture.start(controls.options), true)
end
local function scope_for(capture)
	local owner = {}
	local accepted, scope = capture.bind_history_scope(owner)
	helpers.assert_eq(accepted, true); helpers.assert_eq(type(scope), "table")
	return scope, scope.identity(), owner
end
local function rejects(callback) local ok = pcall(callback); helpers.assert_eq(ok, false) end

helpers.describe("exact physical capture history scope", function()
	helpers.it("requires an actual session and acquires no native work", function()
		Fixture.run(function(capture, observed, controls)
			helpers.assert_eq(capture.bind_history_scope({}), false)
			capture.init(controls.dependencies)
			helpers.assert_eq(capture.bind_history_scope({}), false)
			helpers.assert_eq(observed.tasks, {}); helpers.assert_eq(controls.mode.credit_source(), "legacy")
		end)
	end)
	helpers.it("claims exactly one current scope without granting baseline admission", function()
		Fixture.run(function(capture, observed, controls)
			begin(capture, controls); local scope, token = scope_for(capture)
			helpers.assert_eq(scope.current(token), true); helpers.assert_eq(scope.admitted(token), nil)
			helpers.assert_eq(scope.clock(token), nil); helpers.assert_eq(scope.settled(token), false)
			helpers.assert_eq(capture.bind_history_scope({}), false); helpers.assert_eq(#observed.tasks, 1)
		end)
	end)
	helpers.it("uses exact raw owner and token identity without clearing foreign debt", function()
		Fixture.run(function(capture, _, controls)
			begin(capture, controls); local scope, token, owner = scope_for(capture)
			local forged = setmetatable({}, { __eq = function() error("Equality hooks must not run") end })
			helpers.assert_eq(scope.current(forged), false); helpers.assert_eq(scope.admitted(forged), nil)
			helpers.assert_eq(scope.clock(forged), nil); helpers.assert_eq(scope.settled(forged), false)
			helpers.assert_eq(scope.release(forged, token), false); helpers.assert_eq(scope.release(owner, forged), false)
			helpers.assert_eq(scope.current(token), true)
		end)
	end)
	helpers.it("requires successful clock completion and exact worker settlement", function()
		Fixture.run(function(capture, observed, controls)
			begin(capture, controls); local scope, token = scope_for(capture); controls.verified()
			observed.tasks[2].done(0, "clock\n", ""); helpers.assert_eq(scope.clock(token), nil)
			observed.tasks[2].settle(); local information, convert = scope.clock(token)
			helpers.assert_eq(information, { version = 1, domain = "mach_absolute_time", numer = 125, denom = 3 })
			helpers.assert_eq(convert("3"), 125); helpers.assert_eq(scope.admitted(token), nil)
		end)
	end)
	helpers.it("never uses capturing diagnostic state for completed baseline readiness", function()
		Fixture.run(function(capture, observed, controls)
			begin(capture, controls); local scope, token = scope_for(capture)
			controls.verified(); controls.clocked(); observed.tasks[3].chunk(nil, "opened\n")
			helpers.assert_eq(capture.status().state, "capturing"); helpers.assert_eq(scope.admitted(token), nil)
			observed.tasks[3].chunk(nil, "page\n"); helpers.assert_eq(scope.admitted(token), nil)
			observed.tasks[3].chunk(nil, "ready\n"); helpers.assert_eq(scope.admitted(token), "production-fixture/7")
		end)
	end)
	helpers.it("copies verified timebase before receiver mutation and owns converter identity", function()
		Fixture.run(function(capture, observed, controls)
			controls.dependencies.clock_ready = function(information)
				information.version, information.domain, information.numer, information.denom = 999, "foreign", 1, 1
				return true
			end
			begin(capture, controls); local scope, token = scope_for(capture)
			controls.verified(); controls.clocked(); local information, convert = scope.clock(token)
			helpers.assert_eq(information, { version = 1, domain = "mach_absolute_time", numer = 125, denom = 3 })
			information.numer, information.denom = 3, 125
			controls.frames.clock.numer, controls.frames.clock.denom = 1, 1
			local second, same_convert = scope.clock(token)
			helpers.assert_eq(second.numer, 125); helpers.assert_eq(second.denom, 3)
			helpers.assert_true(rawequal(convert, same_convert)); helpers.assert_eq(convert("3"), 125)
			helpers.assert_eq(#observed.tasks, 3)
		end)
	end)
	helpers.it("keeps malformed and refused clock publication unavailable", function()
		for _, source in ipairs({ "refused", "malformed" }) do
			Fixture.run(function(capture, _, controls)
				if source == "refused" then controls.dependencies.clock_ready = function() return false end
				else controls.frames.clock.domain = "wall_clock" end
				begin(capture, controls); local scope, token = scope_for(capture)
				controls.verified(); controls.clocked()
				helpers.assert_eq(scope.clock(token), nil); helpers.assert_eq(scope.admitted(token), nil)
				helpers.assert_eq(scope.current(token), false)
			end)
		end
	end)
	helpers.it("revokes current and borrowed converter before native stop settlement", function()
		Fixture.run(function(capture, observed, controls)
			begin(capture, controls); local scope, token, owner = scope_for(capture)
			controls.verified(); controls.open(); local _, convert = scope.clock(token)
			helpers.assert_eq(scope.admitted(token), "production-fixture/7"); helpers.assert_eq(capture.stop(), false)
			helpers.assert_eq(scope.current(token), false); helpers.assert_eq(scope.admitted(token), nil)
			helpers.assert_eq(scope.clock(token), nil); helpers.assert_eq(scope.settled(token), false)
			helpers.assert_eq(scope.release(owner, token), false); rejects(function() convert("3") end)
			observed.tasks[3].done(0); observed.tasks[3].settle(); helpers.assert_eq(scope.settled(token), true)
		end)
	end)
	helpers.it("holds successor startup until exact scope release after retirement", function()
		Fixture.run(function(capture, observed, controls)
			begin(capture, controls); local scope, token, owner = scope_for(capture)
			controls.verified(); controls.open(); capture.stop(); observed.tasks[3].done(0); observed.tasks[3].settle()
			helpers.assert_eq(scope.settled(token), true); helpers.assert_eq(capture.start(controls.options), false)
			helpers.assert_eq(scope.release(owner, token), true); helpers.assert_eq(scope.release(owner, token), false)
			helpers.assert_eq(scope.current(token), false); helpers.assert_eq(scope.settled(token), false)
			helpers.assert_eq(capture.start(controls.options), true)
			local next_scope, next_token = scope_for(capture)
			helpers.assert_true(not rawequal(token, next_token)); helpers.assert_eq(next_scope.current(next_token), true)
			helpers.assert_eq(scope.current(token), false)
		end)
	end)
	helpers.it("does not confuse diagnostic settled with stop and accounting release", function()
		Fixture.run(function(capture, observed, controls)
			begin(capture, controls); local scope, token, owner = scope_for(capture)
			observed.tasks[1].done(1); observed.tasks[1].settle(); helpers.assert_eq(capture.status().settled, true)
			helpers.assert_eq(scope.settled(token), false); helpers.assert_eq(scope.release(owner, token), false)
			helpers.assert_eq(capture.stop(), true); helpers.assert_eq(scope.settled(token), true)
		end)
	end)
	helpers.it("retains native debt when accounting release is refused", function()
		Fixture.run(function(capture, observed, controls)
			local original, refuse = controls.mode.release, true
			controls.mode.release = function(...) if refuse then return false end; return original(...) end
			begin(capture, controls); local scope, token, owner = scope_for(capture)
			capture.stop(); observed.tasks[1].done(1); observed.tasks[1].settle()
			helpers.assert_eq(scope.settled(token), false); helpers.assert_eq(scope.release(owner, token), false)
			refuse = false; helpers.assert_eq(capture.stop(), true); helpers.assert_eq(scope.settled(token), true)
		end)
	end)
	helpers.it("closes malformed tick conversion without reusing current authority", function()
		Fixture.run(function(capture, _, controls)
			begin(capture, controls); local scope, token = scope_for(capture)
			controls.verified(); controls.clocked(); local _, convert = scope.clock(token)
			rejects(function() convert("03") end); helpers.assert_eq(scope.current(token), false)
			helpers.assert_eq(scope.clock(token), nil)
		end)
	end)
	for _, kind in ipairs({ "reentry", "stop" }) do
		helpers.it("rejects borrowed converter owner mutation " .. kind, function()
			helpers.with_stub_scope({ "modules.keylogger.physical_clock" }, function()
				local original = require("modules.keylogger.physical_clock")
				local scope, token, capture_owner, observed_permission
				package.loaded["modules.keylogger.physical_clock"] = { new = function(information)
					local native = original.new(information)
					return function(ticks)
						if kind == "stop" then capture_owner.stop() else observed_permission = scope.current(token) end
						return native(ticks)
					end
				end }
				Fixture.run(function(capture, _, controls)
					capture_owner = capture; begin(capture, controls); scope, token = scope_for(capture)
					controls.verified(); controls.clocked(); local _, convert = scope.clock(token)
					rejects(function() convert("3") end); helpers.assert_eq(scope.current(token), false)
					if kind == "reentry" then helpers.assert_eq(observed_permission, false) end
				end)
			end)
		end)
	end
end)

helpers.describe("completed physical baseline readiness", function()
	helpers.it("distinguishes active owner from completed baseline and fences stop", function()
		local frames = Frames.new("readiness", "1")
		local receiver = Delivery.new({ batch_limit = 1, admit = function() return "readiness/1" end,
			context = function() return { allowed = false } end, keycode = Frames.keycode, emit = function() return true end })
		helpers.assert_eq(receiver.ready(), false); receiver.open(frames.opened)
		helpers.assert_eq(receiver.active(), true); helpers.assert_eq(receiver.ready(), false)
		receiver.baseline(frames.page); helpers.assert_eq(receiver.ready(), false)
		receiver.baseline(frames.ready); helpers.assert_eq(receiver.ready(), true)
		receiver.stop(); helpers.assert_eq(receiver.ready(), false)
	end)
end)

helpers.describe("native history scope sibling boundaries", function()
	helpers.it("refuses scope acquisition during the actual unfinished accounting selection", function()
		Fixture.run(function(capture, _, controls)
			local original, accepted = controls.mode.select_stream, nil
			controls.mode.select_stream = function(...)
				accepted = capture.bind_history_scope({})
				return original(...)
			end
			begin(capture, controls)
			helpers.assert_eq(accepted, false)
			local scope, token = scope_for(capture)
			helpers.assert_eq(scope.current(token), true)
		end)
	end)
	helpers.it("refuses noninteger negative and nonnumeric borrowed converter output", function()
		for _, value in ipairs({ -1, 1.0, 1.5, "1", true }) do
			helpers.with_stub_scope({ "modules.keylogger.physical_clock" }, function()
				package.loaded["modules.keylogger.physical_clock"] = { new = function() return function() return value end end }
				Fixture.run(function(capture, _, controls)
					begin(capture, controls); local scope, token = scope_for(capture)
					controls.verified(); controls.clocked(); local _, convert = scope.clock(token)
					rejects(function() convert("3") end)
					helpers.assert_eq(scope.current(token), false)
				end)
			end)
		end
	end)
	helpers.it("reads completed readiness during actual delivery and revokes after callback stop", function()
		local frames = Frames.new("delivery-readiness", "1", { "41" })
		local receiver, observed
		receiver = Delivery.new({ batch_limit = 1, admit = function() return "delivery-readiness/1" end,
			context = function()
				observed = receiver.ready(); receiver.stop(); return { allowed = false }
			end, keycode = Frames.keycode, emit = function() error("No credit can escape") end })
		Frames.start(receiver, frames)
		local batch = { version = 1, kind = "batch", incarnation = "delivery-readiness", lease = "1", coverage = "fixture_only",
			records = { { sequence = "1", device = "41", timestamp = "1", has_page = true, has_usage = true,
				page = 7, usage = 41, value = "1", has_cookie = true, cookie = 41 } } }
		rejects(function() receiver.deliver(batch) end)
		helpers.assert_eq(observed, true); helpers.assert_eq(receiver.ready(), false)
	end)
end)

helpers.describe("accounting observation refusal", function()
	for _, kind in ipairs({ "error", "reentry" }) do
		helpers.it("denies accounting " .. kind .. " without losing native retirement", function()
			Fixture.run(function(capture, observed, controls)
				begin(capture, controls); local scope, token, owner = scope_for(capture)
				controls.verified(); controls.open()
				local original, nested = controls.mode.admitted_capture, nil
				controls.mode.admitted_capture = function()
					if kind == "error" then error("Refused accounting observation") end
					nested = scope.current(token); return original()
				end
				helpers.assert_eq(scope.admitted(token), nil)
				helpers.assert_eq(scope.current(token), false)
				if kind == "reentry" then helpers.assert_eq(nested, false) end
				controls.mode.admitted_capture = original
				helpers.assert_eq(capture.stop(), false)
				observed.tasks[3].done(0); observed.tasks[3].settle()
				helpers.assert_eq(scope.settled(token), true)
				helpers.assert_eq(scope.release(owner, token), true)
			end)
		end)
	end
end)
