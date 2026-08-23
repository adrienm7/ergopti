--- tests/unit/modules/llm/test_profile_warmup_pause_ownership.lua

local helpers = require("tests.helpers")

local function load_fixture()
	local fixture = {
		start_mode = "success",
		stop_mode = "success",
		timers = {},
		warmups = 0,
		paused = false,
		pending = false,
		epoch = 0,
	}
	local timer_stub = {
		secondsSinceEpoch = function() return 1 end,
		absoluteTime = function() return 1 end,
	}
	function timer_stub.doAfter(_, callback)
		callback()
		return { stop = function() return true end }
	end
	function timer_stub.new(delay, callback)
		local timer = {
			delay = delay,
			callback = callback,
			live = false,
			starts = 0,
			stops = 0,
		}
		function timer:start()
			self.starts = self.starts + 1
			self.live = true
			if fixture.start_mode == "sync" then self.callback() end
			if fixture.start_mode == "throw" then error("profile timer start mutation") end
			if fixture.start_mode == "false" then return false end
			if fixture.start_mode == "nil" then return nil end
			return self
		end
		function timer:stop()
			self.stops = self.stops + 1
			if fixture.stop_mode == "throw" then error("profile timer stop refusal") end
			if fixture.stop_mode == "false" then return false end
			if fixture.stop_mode == "nil" then return nil end
			self.live = false
			return self
		end
		function timer:running()
			local reentrant_profile = fixture.reenter_on_running
			if type(reentrant_profile) == "string" then
				fixture.reenter_on_running = nil
				fixture.reentrant_profile_result =
					fixture.core.set_active_profile(reentrant_profile)
			end
			return self.live
		end
		function timer:deliver() self.callback() end
		fixture.timers[#fixture.timers + 1] = timer
		return timer
	end

	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.shortcuts.script_control"] = {
		get_pause_epoch = function()
			local reentrant_profile = fixture.reenter_on_pause_epoch
			if type(reentrant_profile) == "string" then
				fixture.reenter_on_pause_epoch = nil
				fixture.reentrant_pause_profile_result =
					fixture.core.set_active_profile(reentrant_profile)
			end
			return fixture.epoch
		end,
		is_paused = function() return fixture.paused end,
		is_pause_transition_pending = function() return fixture.pending end,
	}
	package.loaded["modules.llm.profiles"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["modules.llm"] = nil
	fixture.core = helpers.load_with_stubs("modules.llm", { timer = timer_stub })
	fixture.baseline = #fixture.timers
	fixture.core.warmup_model = function()
		if fixture.pause_on_warmup == true then
			fixture.epoch = fixture.epoch + 1
			fixture.pending = true
			fixture.reentrant_pause_result =
				fixture.core.pause_deferred_profile_warmup()
			fixture.pending = false
		end
		fixture.warmups = fixture.warmups + 1
		return true
	end
	function fixture.arm()
		fixture.core.set_backend("ollama")
		fixture.core.set_llm_model_ollama("gemma-4-E2B-it")
		fixture.core.set_runtime_llm_enabled(true)
		fixture.core.set_active_profile("advanced")
		return fixture.timers[#fixture.timers]
	end
	function fixture.pause(mode)
		fixture.epoch = fixture.epoch + 1
		fixture.pending = true
		fixture.paused = true
		fixture.stop_mode = mode or "success"
		local result = fixture.core.pause_deferred_profile_warmup()
		fixture.pending = false
		return result
	end
	return fixture
end

helpers.describe("deferred profile warmup exact PAUSE ownership", function()
	helpers.it("dispatches only after the native one-shot has settled", function()
		local fixture = load_fixture()
		local timer = fixture.arm()
		helpers.assert_eq(#fixture.timers, fixture.baseline + 1)
		helpers.assert_eq(fixture.warmups, 0)
		timer:deliver()
		helpers.assert_eq(fixture.warmups, 1)
		timer:deliver()
		helpers.assert_eq(fixture.warmups, 1)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("fences the pre-PAUSE epoch after " .. mode .. " cancellation", function()
			local fixture = load_fixture()
			local timer = fixture.arm()
			helpers.assert_eq(fixture.pause(mode), false)
			helpers.assert_true(timer.live,
				"the exact deferred timer must remain owned after refusal")
			timer:deliver()
			helpers.assert_eq(fixture.warmups, 0,
				"late pre-PAUSE work must be inert before physical cleanup")
			fixture.stop_mode = "success"
			helpers.assert_true(fixture.core.pause_deferred_profile_warmup())
			helpers.assert_eq(timer.live, false)
			fixture.paused = false
			timer:deliver()
			timer:deliver()
			helpers.assert_eq(fixture.warmups, 0,
				"RESUME must not replay a warmup captured in the prior epoch")
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("propagates and retries runtime-disable cleanup after " .. mode, function()
			local fixture = load_fixture()
			local timer = fixture.arm()
			fixture.stop_mode = mode
			helpers.assert_eq(fixture.core.set_runtime_llm_enabled(false), false,
				"the runtime setter must expose exact native cleanup debt")
			helpers.assert_true(timer.live)
			timer:deliver()
			helpers.assert_eq(fixture.warmups, 0)

			fixture.stop_mode = "success"
			helpers.assert_true(fixture.core.set_runtime_llm_enabled(false),
				"same-value disable must retry the retained owner")
			helpers.assert_eq(timer.live, false)
			timer:deliver()
			helpers.assert_eq(fixture.warmups, 0)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("keeps the prior profile until replacement cleanup settles after " .. mode,
			function()
				local fixture = load_fixture()
				local predecessor = fixture.arm()
				fixture.stop_mode = mode
				helpers.assert_eq(fixture.core.set_active_profile("basic"), false)
				helpers.assert_eq(fixture.core.get_active_profile().id, "advanced",
					"profile publication must wait for exact predecessor settlement")
				helpers.assert_eq(#fixture.timers, fixture.baseline + 1,
					"no sibling warmup may be acquired while cleanup is pending")
				helpers.assert_true(predecessor.live)

				fixture.stop_mode = "success"
				helpers.assert_true(fixture.core.set_active_profile("basic"))
				helpers.assert_eq(fixture.core.get_active_profile().id, "basic")
				helpers.assert_eq(predecessor.live, false)
				helpers.assert_eq(#fixture.timers, fixture.baseline + 2)
				predecessor:deliver()
				helpers.assert_eq(fixture.warmups, 0)
				helpers.assert_true(fixture.core.pause_deferred_profile_warmup())
			end)
	end

	helpers.it("withholds a self-stop-refused callback until later settlement", function()
		local fixture = load_fixture()
		local timer = fixture.arm()
		fixture.stop_mode = "false"
		timer:deliver()
		helpers.assert_eq(fixture.warmups, 0)
		fixture.stop_mode = "success"
		timer:deliver()
		helpers.assert_eq(fixture.warmups, 1)
	end)

	helpers.it("keeps PAUSE pending while the warmup callback is running", function()
		local fixture = load_fixture()
		local timer = fixture.arm()
		fixture.pause_on_warmup = true
		timer:deliver()
		helpers.assert_eq(fixture.reentrant_pause_result, false,
			"the callback remains a logical capability until warmup_model returns")
		helpers.assert_eq(fixture.warmups, 1)
		helpers.assert_true(fixture.core.pause_deferred_profile_warmup(),
			"the exact owner settles immediately after callback return")
	end)

	helpers.it("does not overwrite a successor installed reentrantly during native settlement", function()
		local fixture = load_fixture()
		local predecessor = fixture.arm()
		fixture.reenter_on_running = "basic"

		helpers.assert_eq(fixture.core.set_active_profile("raw"), false,
			"the superseded outer profile transaction must refuse")
		helpers.assert_true(fixture.reentrant_profile_result,
			"the nested profile transaction must own the successor")
		helpers.assert_eq(fixture.core.get_active_profile().id, "basic")
		helpers.assert_eq(#fixture.timers, fixture.baseline + 2,
			"the outer transaction must not publish a third timer over the successor")
		helpers.assert_eq(predecessor.live, false)
		local successor = fixture.timers[#fixture.timers]
		helpers.assert_true(successor.live)

		helpers.assert_true(fixture.pause("success"))
		helpers.assert_eq(successor.live, false,
			"PAUSE must still see and settle the exact nested successor")
		predecessor:deliver()
		successor:deliver()
		helpers.assert_eq(fixture.warmups, 0)
	end)

	helpers.it("does not overwrite a successor installed by a pause-epoch probe", function()
		local fixture = load_fixture()
		local predecessor = fixture.arm()
		fixture.reenter_on_pause_epoch = "basic"

		helpers.assert_eq(fixture.core.set_active_profile("raw"), false)
		helpers.assert_true(fixture.reentrant_pause_profile_result)
		helpers.assert_eq(fixture.core.get_active_profile().id, "basic")
		helpers.assert_eq(#fixture.timers, fixture.baseline + 2,
			"only the nested successor may be published after the predecessor")
		helpers.assert_eq(predecessor.live, false)
		local successor = fixture.timers[#fixture.timers]
		helpers.assert_true(successor.live)

		helpers.assert_true(fixture.pause("success"))
		helpers.assert_eq(successor.live, false)
		predecessor:deliver()
		successor:deliver()
		helpers.assert_eq(fixture.warmups, 0)
	end)

	for _, mode in ipairs({ "false", "nil", "throw", "sync" }) do
		helpers.it("does not dispatch after a " .. mode .. " start", function()
			local fixture = load_fixture()
			fixture.start_mode = mode
			fixture.arm()
			helpers.assert_eq(fixture.warmups, 0)
			helpers.assert_true(fixture.core.pause_deferred_profile_warmup())
		end)
	end
end)
