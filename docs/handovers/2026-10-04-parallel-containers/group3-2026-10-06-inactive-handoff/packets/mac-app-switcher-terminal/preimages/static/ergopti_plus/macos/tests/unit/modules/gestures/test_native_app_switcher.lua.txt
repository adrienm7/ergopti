--- tests/unit/modules/gestures/test_native_app_switcher.lua

--- Actual facade with controlled native-owner dependencies; no physical claim.
local helpers = require("tests.helpers")
local eq = helpers.assert_eq
local METHODS = {
	"system_switcher_available", "prepare_system_switcher", "post_system_switcher_edge",
	"system_switcher_observation_current", "system_switcher_release_current",
	"cancel_system_switcher", "retire_system_switcher",
}

local function with_facade(callback, configure)
	local names = { "modules.gestures.native_app_switcher", "adapters.synthetic_input",
		"adapters.timer_scheduler", "adapters.window_manager" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local f = { front = 100, time = 10, source = true, release = true,
		input_ack = true, timer_ack = true, posts = {}, retired = 0, timer = {}, captures = 0 }
	local input = {
		system_switcher_available = function() return true end,
		prepare_system_switcher = function(cap, observed, admission)
			f.captures = f.captures + 1
			f.cap, f.observed, f.admission = cap, observed, admission
			if f.prepare_hook then f.prepare_hook() end
			return true
		end,
		post_system_switcher_edge = function(cap, ordinal)
			f.posts[#f.posts + 1] = ordinal
			f.observed(cap, ordinal)
			return true
		end,
		system_switcher_observation_current = function() return true end,
		system_switcher_release_current = function() return f.release end,
		cancel_system_switcher = function() return true end,
		retire_system_switcher = function() f.retired = f.retired + 1; return f.input_ack end,
		keyStroke = function() error("no paired-stroke fallback") end,
	}
	local scheduler = {
		every = function(interval, fn) eq(interval, 0.05); f.tick = fn; return f.timer, true end,
		cancel = function(cap) eq(rawequal(cap, f.timer), true); return f.timer_ack end,
		awake_time = function() return f.time end,
	}
	local windows = {
		frontmost_pid = function() return f.front end,
		focus_window = function() error("no window-activation fallback") end,
	}
	f.input, f.scheduler, f.windows = input, scheduler, windows
	f.publication = { current = function() return f.source end, cached = function() return f.source end }
	if configure then configure(f) end
	package.loaded["adapters.synthetic_input"] = input
	package.loaded["adapters.timer_scheduler"] = f.scheduler
	package.loaded["adapters.window_manager"] = windows
	local ok, failure = xpcall(function()
		f.facade = require("modules.gestures.native_app_switcher")
		callback(f)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(failure, 0) end
end

helpers.describe("macOS product native switcher facade", function()
	helpers.it("remains unavailable without the actual complete native input contract", function()
		for _, method in ipairs(METHODS) do
			with_facade(function(f)
				eq(f.facade.init({ deadline_sec = 2, poll_sec = 0.05 }), false)
				eq(f.facade.available(), false)
				eq(f.facade.request(f.publication), nil)
				eq(f.captures, 0); eq(#f.posts, 0)
			end, function(f) f.input[method] = nil end)
		end
	end)

	helpers.it("rejects duplicate initialization and unowned timing defaults", function()
		with_facade(function(f)
			eq(f.facade.init(nil), false)
			eq(f.facade.init({ deadline_sec = 2, poll_sec = 0.05 }), true)
			eq(f.facade.init({ deadline_sec = 2, poll_sec = 0.05 }), false)
			eq(f.facade.available(), true); eq(f.captures, 0)
		end)
	end)

	helpers.it("calls the exact native edge owner and publishes after strict retirement", function()
		with_facade(function(f)
			eq(f.facade.init({ deadline_sec = 2, poll_sec = 0.05 }), true)
			local complete = 0
			local cap, admitted = f.facade.request(f.publication, function(receipt, status)
				eq(rawequal(receipt, f.cap), true); eq(status, "switched")
				eq(f.facade.has_pending(), false); complete = complete + 1
			end)
			eq(admitted, true); eq(f.facade.status(cap), nil)
			for _ = 1, 4 do f.tick() end
			f.front = 101
			eq(f.tick(), true); eq(f.facade.status(cap), "switched")
			eq(table.concat(f.posts, ","), "1,2,3,4"); eq(complete, 1)
		end)
	end)

	helpers.it("pauses before acquisition callbacks can emit and cannot revive an old source", function()
		with_facade(function(f)
			eq(f.facade.init({ deadline_sec = 2, poll_sec = 0.05 }), true)
			f.prepare_hook = function() eq(f.facade.pause(), false) end
			local cap, admitted = f.facade.request(f.publication)
			eq(admitted, false); eq(f.facade.status(cap), "cancelled")
			eq(#f.posts, 0); eq(f.tick, nil); eq(f.facade.available(), false)
			eq(f.facade.resume(), true); eq(f.admission(), false)
		end)
	end)

	helpers.it("retains native input debt through pause and refuses resume until exact ACK", function()
		with_facade(function(f)
			eq(f.facade.init({ deadline_sec = 2, poll_sec = 0.05 }), true)
			local cap = f.facade.request(f.publication)
			f.input_ack = false
			eq(f.facade.pause(), false); eq(f.facade.has_pending(), true)
			eq(f.facade.resume(), false); eq(f.facade.request(f.publication), nil)
			f.input_ack = true
			eq(f.facade.stop(), true); eq(f.facade.status(cap), "cancelled")
			eq(f.facade.resume(), true)
		end)
	end)

	helpers.it("retains timer debt and does not advertise readiness from input-only cleanup", function()
		with_facade(function(f)
			eq(f.facade.init({ deadline_sec = 2, poll_sec = 0.05 }), true)
			local cap = f.facade.request(f.publication)
			f.timer_ack = false
			eq(f.facade.stop(), false); eq(f.facade.status(cap), nil)
			eq(f.facade.available(), false); eq(f.facade.resume(), false)
			f.timer_ack = true
			eq(f.facade.stop(), true); eq(f.facade.status(cap), "cancelled")
		end)
	end)

	helpers.it("compensates with captured native ports after an owner-function replacement", function()
		with_facade(function(f)
			eq(f.facade.init({ deadline_sec = 2, poll_sec = 0.05 }), true)
			local cap = f.facade.request(f.publication)
			local foreign = 0
			f.input.retire_system_switcher = function() foreign = foreign + 1; return true end
			f.tick()
			eq(f.facade.status(cap), "refused"); eq(f.retired, 1); eq(foreign, 0)
			eq(f.facade.available(), false)
		end)
	end)

	helpers.it("source callback refusal does not invoke direct activation or paired key strokes", function()
		with_facade(function(f)
			eq(f.facade.init({ deadline_sec = 2, poll_sec = 0.05 }), true)
			f.source = false
			local cap, admitted = f.facade.request(f.publication)
			eq(admitted, false); eq(f.facade.status(cap), "refused")
			eq(f.captures, 0); eq(#f.posts, 0)
		end)
	end)
	local function with_real_scheduler(callback, options)
		helpers.with_stub_scope({ "adapters.timer_scheduler", "infra.logger" }, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			with_facade(callback, function(f)
				local native = { running_state = false, stop_calls = 0 }
				function native:running() return self.running_state end
				function native:start()
					self.running_state = true
					if options.early then self.callback() end
					if options.start_throw then error("controlled startup failure") end
					return self
				end
				function native:stop()
					self.stop_calls = self.stop_calls + 1
					if not f.timer_ack then return false end
					self.running_state = false
					return self
				end
				f.native_timer = native
				f.timer_ack = options.stop_ack
				f.scheduler = helpers.load_with_stubs("adapters.timer_scheduler", { timer = {
					new = function(_, fn) native.callback = fn; return native end,
					absoluteTime = function() return f.time * 1e9 end,
				} })
			end)
		end)
	end

	helpers.it("uses the actual scheduler's retained uncommitted handle after startup throws", function()
		with_real_scheduler(function(f)
			eq(f.facade.init({ deadline_sec = 2, poll_sec = 0.05 }), true)
			local cap, admitted = f.facade.request(f.publication)
			eq(admitted, false); eq(f.facade.has_pending(), true)
			eq(f.native_timer:running(), true); eq(#f.posts, 0)
			eq(f.native_timer.stop_calls >= 2, true)
			f.timer_ack = true
			eq(f.facade.stop(), true); eq(f.facade.status(cap), "refused")
			eq(f.native_timer:running(), false)
		end, { start_throw = true, stop_ack = false })
	end)

	helpers.it("actual scheduler rejects synchronous precommit delivery without emitting an edge", function()
		with_real_scheduler(function(f)
			eq(f.facade.init({ deadline_sec = 2, poll_sec = 0.05 }), true)
			local cap, admitted = f.facade.request(f.publication)
			eq(admitted, false); eq(f.facade.has_pending(), false)
			eq(f.native_timer:running(), false); eq(#f.posts, 0)
			eq(f.facade.status(cap), "refused")
		end, { early = true, stop_ack = true })
	end)

end)

return helpers
