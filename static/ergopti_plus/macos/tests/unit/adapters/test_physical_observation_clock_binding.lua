--- tests/unit/adapters/test_physical_observation_clock_binding.lua

--- Tests API binding retirement without claiming host clock-domain qualification.
local helpers = require("tests.helpers")

local function with_clock(callback, configure)
	helpers.with_fresh_modules({ "adapters.physical_observation_clock" }, function()
		local previous = hs
		local calls, native = 0, { timer = {} }
		local controls = { native = native }
		local getter = function() calls = calls + 1; return 9007199254740993 end
		native.timer.absoluteTime = function() return getter() end
		function controls.getter(operation) getter = operation end
		function controls.calls() return calls end
		function controls.replace_root(value) hs = value end
		if configure then configure(native) end
		hs = native
		local ok, reason = pcall(function()
			callback(require("adapters.physical_observation_clock"), controls)
		end)
		hs = previous
		if not ok then error(reason, 0) end
	end)
end

local function bind(clock, owner)
	local capability = clock.bind_history_scope(owner)
	helpers.assert_eq(type(capability), "table")
	local token = capability.identity(owner)
	helpers.assert_eq(type(token), "table")
	return capability, token
end

local function failure(callback, expected)
	local ok, reason = pcall(callback)
	helpers.assert_eq(ok, false)
	helpers.assert_true(tostring(reason):find(expected, 1, true) ~= nil)
end

helpers.describe("physical observation clock binding lifetime", function()
	helpers.it("keeps unbound integer samples exact without reading during module load", function()
		with_clock(function(clock, controls)
			helpers.assert_eq(controls.calls(), 0)
			helpers.assert_eq(clock.now(), 9007199254740993)
			helpers.assert_eq(controls.calls(), 1)
			controls.getter(function() return math.maxinteger end)
			helpers.assert_eq(clock.now(), math.maxinteger)
		end)
	end)

	helpers.it("retains strict unbound missing and invalid representation failures", function()
		with_clock(function(clock, controls)
			for _, row in ipairs({ { value = 1.0 }, { value = -1 }, { value = "1" },
				{ value = false }, { value = {} }, {} }) do
				controls.getter(function() return row.value end)
				failure(clock.now, "Invalid native observation clock representation")
			end
			controls.native.timer = nil
			failure(clock.now, "Missing native observation clock")
		end)
	end)

	helpers.it("retains the exact unbound native error object", function()
		with_clock(function(clock, controls)
			local original = {}
			controls.getter(function() error(original, 0) end)
			local ok, reason = pcall(clock.now)
			helpers.assert_eq(ok, false)
			helpers.assert_true(rawequal(reason, original))
		end)
	end)

	helpers.it("requires a table owner before acquisition and never queries the getter", function()
		with_clock(function(clock, controls)
			for _, row in ipairs({ {}, { value = false }, { value = 1 }, { value = "owner" } }) do
				failure(function() clock.bind_history_scope(row.value) end, "Invalid observation clock owner")
			end
			helpers.assert_eq(controls.calls(), 0)
			local cap, token = bind(clock, {})
			helpers.assert_eq(type(cap.current), "function")
			helpers.assert_eq(type(cap.read), "function")
			helpers.assert_eq(type(cap.detach), "function")
			helpers.assert_eq(type(cap.retired), "function")
			helpers.assert_eq(type(token), "table")
			helpers.assert_eq(controls.calls(), 0)
		end)
	end)

	helpers.it("refuses missing or metamethod-only native bindings without foreign calls", function()
		with_clock(function(clock, controls)
			local capability, reason = clock.bind_history_scope({})
			helpers.assert_eq(capability, nil)
			helpers.assert_eq(reason, "clock_binding_unavailable")
			helpers.assert_eq(controls.calls(), 0)
		end, function(native) native.timer = nil end)
		local foreign = 0
		with_clock(function(clock)
			local capability, reason = clock.bind_history_scope({})
			helpers.assert_eq(capability, nil)
			helpers.assert_eq(reason, "clock_binding_unavailable")
			helpers.assert_eq(foreign, 0)
		end, function(native)
			native.timer = setmetatable({}, { __index = function()
				foreign = foreign + 1; return function() return 1 end
			end })
		end)
	end)

	helpers.it("uses exact owner and token identities without equality hooks or native reads", function()
		with_clock(function(clock, controls)
			local comparisons = 0
			local meta = { __eq = function() comparisons = comparisons + 1; return true end }
			local owner, foreign = setmetatable({}, meta), setmetatable({}, meta)
			local cap, token = bind(clock, owner)
			helpers.assert_eq(cap.identity(foreign), nil)
			helpers.assert_eq(cap.current(foreign, token), false)
			helpers.assert_eq(cap.current(owner, {}), false)
			local value, reason = cap.read(foreign, token)
			helpers.assert_eq(value, nil); helpers.assert_eq(reason, "clock_identity_refused")
			helpers.assert_eq(cap.detach(foreign, token), false)
			helpers.assert_eq(cap.retired(foreign, token), false)
			helpers.assert_true(cap.current(owner, token))
			helpers.assert_eq(comparisons, 0); helpers.assert_eq(controls.calls(), 0)
		end)
	end)

	helpers.it("refuses duplicate acquisition while preserving the exact original owner", function()
		with_clock(function(clock, controls)
			local owner = {}; local cap, token = bind(clock, owner)
			local next_cap, reason = clock.bind_history_scope({})
			helpers.assert_eq(next_cap, nil); helpers.assert_eq(reason, "clock_subscription_busy")
			helpers.assert_true(cap.current(owner, token)); helpers.assert_eq(controls.calls(), 0)
		end)
	end)

	helpers.it("uses the captured actual integer getter for bound ports and strict M.now", function()
		with_clock(function(clock, controls)
			local owner = {}; local cap, token = bind(clock, owner)
			helpers.assert_eq(cap.read(owner, token), 9007199254740993)
			helpers.assert_eq(clock.now(), 9007199254740993)
			helpers.assert_eq(controls.calls(), 2)
			helpers.assert_true(cap.current(owner, token)); helpers.assert_eq(cap.retired(owner, token), false)
		end)
	end)

	helpers.it("revokes a replaced timer table before a bound getter can run", function()
		with_clock(function(clock, controls)
			local owner = {}; local cap, token = bind(clock, owner)
			local replacement = 0
			controls.native.timer = { absoluteTime = function() replacement = replacement + 1; return 1 end }
			helpers.assert_eq(cap.current(owner, token), false)
			local value, reason = cap.read(owner, token)
			helpers.assert_eq(value, nil); helpers.assert_eq(reason, "clock_subscription_revoked")
			failure(clock.now, "clock_subscription_revoked")
			helpers.assert_eq(replacement, 0); helpers.assert_eq(controls.calls(), 0)
			helpers.assert_eq(clock.bind_history_scope({}), nil)
			helpers.assert_eq(cap.retired(owner, token), false)
			helpers.assert_true(cap.detach(owner, token)); helpers.assert_true(cap.retired(owner, token))
		end)
	end)

	helpers.it("fences a replaced actualTime function before reads and never invokes its successor", function()
		with_clock(function(clock, controls)
			local owner = {}; local cap, token = bind(clock, owner)
			local replacement = 0
			controls.native.timer.absoluteTime = function() replacement = replacement + 1; return 1 end
			local value, reason = cap.read(owner, token)
			helpers.assert_eq(value, nil); helpers.assert_eq(reason, "clock_binding_changed")
			helpers.assert_eq(cap.current(owner, token), false)
			helpers.assert_eq(replacement, 0); helpers.assert_eq(controls.calls(), 0)
		end)
	end)

	helpers.it("fences the actual global Hammerspoon root before bound M.now", function()
		with_clock(function(clock, controls)
			local owner = {}; local cap, token = bind(clock, owner)
			local replacement = 0
			controls.replace_root({ timer = { absoluteTime = function() replacement = replacement + 1; return 1 end } })
			failure(clock.now, "clock_binding_changed")
			helpers.assert_eq(cap.current(owner, token), false)
			helpers.assert_eq(replacement, 0); helpers.assert_eq(controls.calls(), 0)
		end)
	end)

	helpers.it("fences a timer replacement that happens inside the actual getter", function()
		with_clock(function(clock, controls)
			local owner = {}; local cap, token = bind(clock, owner)
			local getters = 0
			controls.getter(function()
				getters = getters + 1; controls.native.timer = { absoluteTime = function() return 2 end }; return 1
			end)
			local value, reason = cap.read(owner, token)
			helpers.assert_eq(value, nil); helpers.assert_eq(reason, "clock_binding_changed")
			helpers.assert_eq(getters, 1); helpers.assert_eq(cap.current(owner, token), false)
			helpers.assert_eq(cap.retired(owner, token), false)
			helpers.assert_true(cap.detach(owner, token)); helpers.assert_true(cap.retired(owner, token))
		end)
	end)

	helpers.it("fences a function replacement inside bound M.now without returning its old sample", function()
		with_clock(function(clock, controls)
			local owner = {}; local cap, token = bind(clock, owner)
			controls.getter(function() controls.native.timer.absoluteTime = function() return 2 end; return 1 end)
			failure(clock.now, "clock_binding_changed")
			helpers.assert_eq(cap.current(owner, token), false)
			helpers.assert_eq(cap.retired(owner, token), false)
		end)
	end)

	helpers.it("revokes on a thrown native error while preserving its exact object", function()
		with_clock(function(clock, controls)
			local owner = {}; local cap, token = bind(clock, owner)
			local original = {}; controls.getter(function() error(original, 0) end)
			local ok, reason = pcall(function() return cap.read(owner, token) end)
			helpers.assert_eq(ok, false); helpers.assert_true(rawequal(reason, original))
			helpers.assert_eq(cap.current(owner, token), false)
			helpers.assert_eq(cap.retired(owner, token), false)
			helpers.assert_true(cap.detach(owner, token)); helpers.assert_true(cap.retired(owner, token))
		end)
	end)

	helpers.it("revokes rather than coercing invalid bound native representations", function()
		for _, row in ipairs({ { value = 1.0 }, { value = -1 }, { value = "1" },
			{ value = false }, { value = {} }, {} }) do
			with_clock(function(clock, controls)
				local owner = {}; local cap, token = bind(clock, owner)
				local reads = 0; controls.getter(function() reads = reads + 1; return row.value end)
				failure(function() cap.read(owner, token) end, "Invalid native observation clock representation")
				helpers.assert_eq(reads, 1); helpers.assert_eq(cap.current(owner, token), false)
				helpers.assert_eq(cap.retired(owner, token), false)
				helpers.assert_true(cap.detach(owner, token)); helpers.assert_true(cap.retired(owner, token))
			end)
		end
	end)

	helpers.it("revokes reentrant bound reads before a second getter and retains exact detach debt", function()
		with_clock(function(clock, controls)
			local owner = {}; local cap, token = bind(clock, owner)
			local reads = 0
			controls.getter(function()
				reads = reads + 1
				local value, reason = cap.read(owner, token)
				helpers.assert_eq(value, nil); helpers.assert_eq(reason, "clock_reentrant_read")
				helpers.assert_eq(cap.current(owner, token), false)
				helpers.assert_true(cap.detach(owner, token))
				helpers.assert_eq(cap.retired(owner, token), false)
				helpers.assert_eq(clock.bind_history_scope({}), nil)
				return 1
			end)
			local value, reason = cap.read(owner, token)
			helpers.assert_eq(value, nil); helpers.assert_eq(reason, "clock_subscription_detached")
			helpers.assert_eq(reads, 1); helpers.assert_true(cap.retired(owner, token))
		end)
	end)

	helpers.it("turns reentrant M.now refusal into a strict error and rejects the outer sample", function()
		with_clock(function(clock, controls)
			local owner = {}; local cap, token = bind(clock, owner)
			local reads = 0
			controls.getter(function()
				reads = reads + 1; failure(clock.now, "clock_reentrant_read"); return 1
			end)
			failure(clock.now, "clock_subscription_revoked")
			helpers.assert_eq(reads, 1); helpers.assert_eq(cap.current(owner, token), false)
			helpers.assert_true(cap.detach(owner, token)); helpers.assert_true(cap.retired(owner, token))
		end)
	end)

	helpers.it("requires exact detach and all getter frames to unwind before successor acquisition", function()
		with_clock(function(clock, controls)
			local owner = {}; local cap, token = bind(clock, owner)
			controls.getter(function()
				helpers.assert_true(cap.detach(owner, token))
				helpers.assert_eq(cap.retired(owner, token), false)
				local successor, reason = clock.bind_history_scope({})
				helpers.assert_eq(successor, nil)
				helpers.assert_eq(reason, "clock_getter_inflight")
				return 1
			end)
			local value, reason = cap.read(owner, token)
			helpers.assert_eq(value, nil); helpers.assert_eq(reason, "clock_subscription_detached")
			helpers.assert_true(cap.retired(owner, token))
			controls.getter(function() return 7 end)
			local next_owner = {}; local next_cap, next_token = bind(clock, next_owner)
			helpers.assert_eq(next_cap.read(next_owner, next_token), 7)
			helpers.assert_true(rawequal(cap.identity(owner), token))
			helpers.assert_eq(cap.identity(next_owner), nil)
			helpers.assert_eq(cap.current(owner, token), false)
			helpers.assert_true(cap.detach(owner, token))
			helpers.assert_true(next_cap.current(next_owner, next_token))
		end)
	end)

	helpers.it("fences acquisition during actual unbound getter execution without dropping its sample", function()
		with_clock(function(clock, controls)
			local reads = 0
			controls.getter(function()
				reads = reads + 1
				local capability, reason = clock.bind_history_scope({})
				helpers.assert_eq(capability, nil); helpers.assert_eq(reason, "clock_getter_inflight")
				return 9
			end)
			helpers.assert_eq(clock.now(), 9); helpers.assert_eq(reads, 1)
			local cap, token = bind(clock, {})
			helpers.assert_eq(type(token), "table"); helpers.assert_eq(type(cap.read), "function")
		end)
	end)

	helpers.it("retains a yielded actual getter frame after detach until coroutine unwind", function()
		with_clock(function(clock, controls)
			local owner = {}; local cap, token = bind(clock, owner)
			local reads = 0
			controls.getter(function() reads = reads + 1; coroutine.yield("actual getter held"); return 11 end)
			local running = coroutine.create(function() return cap.read(owner, token) end)
			local ok, message = coroutine.resume(running)
			helpers.assert_true(ok); helpers.assert_eq(message, "actual getter held")
			helpers.assert_true(cap.detach(owner, token)); helpers.assert_eq(cap.retired(owner, token), false)
			helpers.assert_eq(clock.bind_history_scope({}), nil)
			local completed, value, reason = coroutine.resume(running)
			helpers.assert_true(completed); helpers.assert_eq(value, nil)
			helpers.assert_eq(reason, "clock_subscription_detached")
			helpers.assert_eq(coroutine.status(running), "dead"); helpers.assert_eq(reads, 1)
			helpers.assert_true(cap.retired(owner, token))
		end)
	end)

	helpers.it("does not let a foreign detach revoke or retire an actual getter", function()
		with_clock(function(clock, controls)
			local owner = {}; local cap, token = bind(clock, owner)
			controls.getter(function()
				helpers.assert_eq(cap.detach({}, token), false)
				helpers.assert_eq(cap.detach(owner, {}), false)
				helpers.assert_true(cap.current(owner, token))
				helpers.assert_eq(cap.retired(owner, token), false)
				return 13
			end)
			helpers.assert_eq(cap.read(owner, token), 13)
			helpers.assert_true(cap.current(owner, token))
		end)
	end)

	helpers.it("never stops the borrowed native clock and restores strict unbound reads after retirement", function()
		with_clock(function(clock, controls)
			local owner = {}; local cap, token = bind(clock, owner)
			local stopped = 0; controls.native.timer.stop = function() stopped = stopped + 1 end
			helpers.assert_true(cap.detach(owner, token)); helpers.assert_true(cap.retired(owner, token))
			helpers.assert_eq(clock.now(), 9007199254740993)
			helpers.assert_eq(controls.calls(), 1); helpers.assert_eq(stopped, 0)
			local value, reason = cap.read(owner, token)
			helpers.assert_eq(value, nil); helpers.assert_eq(reason, "clock_subscription_detached")
			helpers.assert_eq(controls.calls(), 1)
		end)
	end)

	helpers.it("retains the actual private read port when a caller replaces its exported copy", function()
		with_clock(function(clock, controls)
			local owner = {}; local cap, token = bind(clock, owner)
			cap.read = function() return 17 end
			helpers.assert_eq(clock.now(), 9007199254740993)
			helpers.assert_eq(controls.calls(), 1)
			helpers.assert_true(cap.current(owner, token))
		end)
	end)

	helpers.it("retains private retirement accounting when a caller replaces its exported copy", function()
		with_clock(function(clock, controls)
			local owner = {}; local cap, token = bind(clock, owner)
			cap.retired = function() return true end
			local successor, reason = clock.bind_history_scope({})
			helpers.assert_eq(successor, nil); helpers.assert_eq(reason, "clock_subscription_busy")
			helpers.assert_eq(clock.now(), 9007199254740993)
			helpers.assert_eq(controls.calls(), 1)
			helpers.assert_true(cap.current(owner, token))
			helpers.assert_true(cap.detach(owner, token))
		end)
	end)
end)
