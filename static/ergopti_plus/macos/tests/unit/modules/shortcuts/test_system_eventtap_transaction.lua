--- tests/unit/modules/shortcuts/test_system_eventtap_transaction.lua

--- ==============================================================================
--- MODULE: System Shortcut Eventtap Transaction Regression
--- DESCRIPTION:
--- Drives the real system-action eventtap factories through native false/throw
--- activation and teardown results. A factory may publish a handle only after an
--- enabled probe commits it; failed cleanup remains callback-inert and retryable.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Copies a native API table while replacing selected fields.
--- @param base table Base contract.
--- @param overrides table Replacement fields.
--- @return table merged Contract-preserving copy.
local function extend_contract(base, overrides)
	local merged = {}
	for key, value in pairs(base) do merged[key] = value end
	for key, value in pairs(overrides or {}) do merged[key] = value end
	return merged
end


--- Loads the real system-actions module with programmable eventtap lifecycles.
--- @param plans table[] Per-created-tap start/stop behavior.
--- @param timer_plans table[]|nil Per-created-timer start/stop behavior.
--- @return table fixture Loaded module and native tap observations.
local function load_fixture(plans, timer_plans)
	package.loaded["modules.shortcuts.actions.system"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["infra.keycodes"] = nil

	package.loaded["tests.stubs.hs"] = nil
	local hs_contract = require("tests.stubs.hs")
	hs_contract.__reset()
	local taps = {}
	local created = 0
	local factory_mode = false
	local timers = {}
	local timer_created = 0
	local eventtap = extend_contract(hs_contract.eventtap, {
		new = function(types, callback)
			created = created + 1
			local plan = factory_mode and (plans[created] or {}) or {}
			if plan.construct_throw then error(plan.construct_throw, 0) end
			if plan.construct_result ~= nil then return plan.construct_result end
			local tap = {
				types = types,
				callback = callback,
				enabled = false,
				start_calls = 0,
				stop_calls = 0,
			}
			function tap:start()
				self.start_calls = self.start_calls + 1
				self.enabled = plan.enable_on_start ~= false
				if plan.start_throw then error(plan.start_throw, 0) end
				if plan.start_result ~= nil then return plan.start_result end
				return self
			end
			function tap:stop()
				self.stop_calls = self.stop_calls + 1
				local throw_now = plan.stop_throw_count and self.stop_calls <= plan.stop_throw_count
				if not throw_now and plan.disable_on_stop ~= false then self.enabled = false end
				if throw_now then error("STOP_THROW_" .. tostring(created), 0) end
				if plan.stop_result ~= nil then return plan.stop_result end
				return self
			end
			function tap:isEnabled()
				if plan.probe_throw then error("PROBE_THROW_" .. tostring(created), 0) end
				return self.enabled
			end
			taps[#taps + 1] = tap
			return tap
		end,
	})
	local timer = extend_contract(hs_contract.timer, {
		new = function(delay, callback)
			timer_created = timer_created + 1
			local plan = (timer_plans or {})[timer_created] or {}
			local native = {
				delay = delay,
				callback = callback,
				running = false,
				start_calls = 0,
				stop_calls = 0,
			}
			function native:start()
				self.start_calls = self.start_calls + 1
				self.running = plan.enable_on_start ~= false
				if plan.start_throw then error(plan.start_throw, 0) end
				if plan.start_result ~= nil then return plan.start_result end
				return self
			end
			function native:stop()
				self.stop_calls = self.stop_calls + 1
				local throw_now = plan.stop_throw_count and self.stop_calls <= plan.stop_throw_count
				if not throw_now and plan.disable_on_stop ~= false then self.running = false end
				if throw_now then error("TIMER_STOP_THROW_" .. tostring(timer_created), 0) end
				if plan.stop_result ~= nil then return plan.stop_result end
				return self
			end
			function native:fire()
				if self.running then self.callback() end
			end
			timers[#timers + 1] = native
			hs_contract.timer.__timers[#hs_contract.timer.__timers + 1] = native
			return native
		end,
	})
	package.loaded["adapters.event_provenance"] = {
		STATUS_UNREADABLE = "unreadable",
		STATUS_FOREIGN = "foreign",
		classify_with_fence = function() return nil, "foreign", nil end,
	}
	package.loaded["adapters.synthetic_input"] = {
		begin = function() return {} end,
		emit_key_stroke = function() return true end,
		seal = function() return true end,
		cancel = function() return true end,
		defer_after_callback = function(_label, callback, ...)
			local args = table.pack(...)
			_G.hs.timer.doAfter(0, function()
				callback(table.unpack(args, 1, args.n))
			end)
			return true
		end,
	}

	local system = helpers.load_with_stubs("modules.shortcuts.actions.system", {
		eventtap = eventtap,
		timer = timer,
	})
	-- Some transitive adapter setup may own its own tap. The cases below control
	-- only taps constructed by the public factories after the module is loaded.
	for index = #taps, 1, -1 do taps[index] = nil end
	created = 0
	factory_mode = true
	_G.hs.mouse.getCurrentScreen = function() return nil end
	_G.hs.caffeinate = _G.hs.caffeinate or { declareUserActivity = function() return true end }
	return {
		system = system,
		hs = _G.hs,
		taps = taps,
		timers = timers,
		created = function() return created end,
		timer_created = function() return timer_created end,
	}
end





-- ==================================================
-- ==================================================
-- ======= 1/ Single-Tap Factory Transactions =======
-- ==================================================
-- ==================================================

helpers.describe("system shortcut eventtap factories are transactional", function()
	helpers.it("rejects every single-tap factory when native start returns false", function()
		local factories = {
			function(system) return system.bind_instant_screenshot() end,
			function(system) return system.bind_cmd_star() end,
			function(system) return system.bind_wrap_text_if_selected() end,
		}
		for index, factory in ipairs(factories) do
			local fixture = load_fixture({{
				start_result = false,
				enable_on_start = true,
			}})
			local call_ok, owner = pcall(factory, fixture.system)
			helpers.assert_true(call_ok,
				"factory " .. index .. " must contain a native start refusal")
			helpers.assert_nil(owner,
				"factory " .. index .. " must not publish a tap whose start returned false")
			helpers.assert_eq(fixture.taps[1].stop_calls, 1,
				"an activate-then-false tap must be rolled back exactly once")
			helpers.assert_true(not fixture.taps[1].enabled,
				"failed acquisition must leave no live native tap")
		end
	end)

	helpers.it("contains constructor false and throw without inventing cleanup debt", function()
		for _, failed_plan in ipairs({
			{ construct_result = false },
			{ construct_throw = "CONSTRUCT_THROW" },
		}) do
			local fixture = load_fixture({ failed_plan, {} })
			local call_ok, owner = pcall(fixture.system.bind_instant_screenshot)
			helpers.assert_true(call_ok, "constructor refusal must not escape the factory")
			helpers.assert_nil(owner, "a false or throwing constructor cannot publish an owner")

			local replacement = fixture.system.bind_cmd_star()
			helpers.assert_not_nil(replacement,
				"a non-resource constructor result must not block the next acquisition")
			helpers.assert_eq(fixture.created(), 2)
			helpers.assert_eq(#fixture.taps, 1,
				"only the successful successor may create a native owner")
		end
	end)

	helpers.it("contains activate-then-throw and settles retained cleanup before a successor", function()
		local fixture = load_fixture({
			{
				start_throw = "START_THROW",
				enable_on_start = true,
				stop_throw_count = 1,
			},
			{},
		})
		local call_ok, owner = pcall(fixture.system.bind_instant_screenshot)
		helpers.assert_true(call_ok, "native start exceptions must not escape a user binding factory")
		helpers.assert_nil(owner, "a thrown start cannot publish an eventtap owner")
		helpers.assert_true(fixture.taps[1].enabled,
			"the fixture must prove native activation survived the first failed rollback")

		local replacement = fixture.system.bind_cmd_star()
		helpers.assert_not_nil(replacement,
			"a later acquisition may proceed after the exact retained tap is settled")
		helpers.assert_eq(fixture.taps[1].stop_calls, 2,
			"the second acquisition must retry cleanup on the original exact handle")
		helpers.assert_true(not fixture.taps[1].enabled)
		helpers.assert_eq(fixture.created(), 2,
			"no successor may be constructed before retained cleanup succeeds")
	end)

	helpers.it("keeps a refused delete retryable and makes its callback inert immediately", function()
		local fixture = load_fixture({{
			stop_result = false,
			disable_on_stop = false,
		}})
		local owner = fixture.system.bind_instant_screenshot()
		helpers.assert_not_nil(owner)
		local native = fixture.taps[1]

		helpers.assert_eq(owner:delete(), false,
			"returned false teardown must not be reported as released")
		helpers.assert_true(native.enabled,
			"the fixture must leave the refused native tap live")
		local consume, returned = native.callback({})
		helpers.assert_true(not consume,
			"a retained native callback must become inert before teardown is attempted")
		helpers.assert_nil(returned)

		-- Let the exact same handle settle on retry.
		local plan = { stop_result = true }
		-- The closure reads its original plan, so replace only the method while
		-- preserving the observed handle identity.
		native.stop = function(self)
			self.stop_calls = self.stop_calls + 1
			self.enabled = false
			return plan.stop_result and self or false
		end
		helpers.assert_eq(owner:delete(), true)
		helpers.assert_eq(native.stop_calls, 2)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 2/ Dual-Tap Atomic Acquisition =======
-- ==============================================
-- ==============================================

helpers.describe("layer-scroll dual eventtap acquisition is atomic", function()
	helpers.it("rolls both native taps back when the second start returns false", function()
		local fixture = load_fixture({
			{},
			{ start_result = false, enable_on_start = true },
		})
		local call_ok, owner = pcall(fixture.system.bind_layer_scroll)
		helpers.assert_true(call_ok)
		helpers.assert_nil(owner,
			"the pair cannot publish when only the key tap committed")
		helpers.assert_eq(#fixture.taps, 2)
		helpers.assert_true(not fixture.taps[1].enabled,
			"the first committed tap must be rolled back with the failed pair")
		helpers.assert_true(not fixture.taps[2].enabled,
			"the activate-then-false second tap must be rolled back")
		helpers.assert_eq(fixture.taps[1].stop_calls, 1)
		helpers.assert_eq(fixture.taps[2].stop_calls, 1)
	end)
end)





-- ============================================
-- ============================================
-- ======= 3/ Keep-Awake Tap Commitment =======
-- ============================================
-- ============================================

helpers.describe("keep-awake requires its input watcher to commit", function()
	helpers.it("reports false and starts no jiggler when watcher activation is refused", function()
		local fixture = load_fixture({{
			start_result = false,
			enable_on_start = true,
		}})
		local result = fixture.system.toggle_awake()
		helpers.assert_eq(result, false,
			"the visible keep-awake action must reject a missing input watcher")
		helpers.assert_eq(fixture.taps[1].stop_calls, 1)
		helpers.assert_true(not fixture.taps[1].enabled)
		for _, timer in ipairs(fixture.hs.timer.__timers or {}) do
			helpers.assert_true(not timer.running,
				"a rejected keep-awake activation must not leave a jiggler timer running")
		end
	end)

	helpers.it("blocks a successor while the prior keep-awake watcher refuses teardown", function()
		local fixture = load_fixture({{
			stop_result = false,
			disable_on_stop = false,
		}, {}})
		helpers.assert_eq(fixture.system.toggle_awake(), true)
		helpers.assert_eq(fixture.system.toggle_awake(), false,
			"the OFF action must report retained native cleanup")
		helpers.assert_true(fixture.taps[1].enabled)

		helpers.assert_eq(fixture.system.toggle_awake(), false,
			"a refused cleanup retry must block replacement activation")
		helpers.assert_eq(#fixture.taps, 1,
			"no successor watcher may overwrite the exact retained owner")
		helpers.assert_eq(fixture.timer_created(), 1,
			"no successor jitter timer may start behind a leaked watcher")

		fixture.taps[1].stop = function(self)
			self.stop_calls = self.stop_calls + 1
			self.enabled = false
			return self
		end
		helpers.assert_eq(fixture.system.toggle_awake(), true)
		helpers.assert_eq(#fixture.taps, 2)
	end)
end)





-- ====================================================
-- ====================================================
-- ======= 4/ Keep-Awake Return Timer Ownership =======
-- ====================================================
-- ====================================================

--- Arms the real keep-awake cursor-return timer and returns its exact handle.
--- @param fixture table Active system-action fixture.
--- @return table return_timer Pending cursor-return timer.
local function arm_cursor_return(fixture)
	local timers = fixture.hs.timer.__timers
	local tick
	for index = #timers, 1, -1 do
		if timers[index].running and timers[index].delay ~= 0 then
			tick = timers[index]
			break
		end
	end
	helpers.assert_not_nil(tick, "keep-awake must own a scheduled jitter tick")
	local before = #timers
	tick:fire()
	local return_timer = timers[before + 1]
	helpers.assert_not_nil(return_timer,
		"the jitter tick must retain its first newly created cursor-return timer")
	return return_timer
end


helpers.describe("keep-awake owns every pending cursor return", function()
	helpers.it("stop_awake cancels the pending return before it can move the cursor", function()
		local fixture = load_fixture({{}})
		local moves = {}
		fixture.hs.mouse.absolutePosition = function(position)
			if position then moves[#moves + 1] = { x = position.x, y = position.y } end
			return { x = 100, y = 200 }
		end
		helpers.assert_eq(fixture.system.toggle_awake(), true)
		local return_timer = arm_cursor_return(fixture)
		helpers.assert_true(return_timer.running)

		fixture.system.stop_awake()
		helpers.assert_true(not return_timer.running,
			"shutdown must cancel the exact pending cursor-return handle")
		local before = #moves
		return_timer:fire()
		helpers.assert_eq(#moves, before,
			"a stale timer must never teleport the pointer after shutdown")
	end)

	helpers.it("auto-disable cancels the pending return before publishing OFF", function()
		local fixture = load_fixture({{}})
		local now = 1000
		fixture.hs.timer.secondsSinceEpoch = function() return now end
		fixture.hs.mouse.absolutePosition = function(position)
			return position or { x = 100, y = 200 }
		end
		helpers.assert_eq(fixture.system.toggle_awake(), true)
		local return_timer = arm_cursor_return(fixture)
		now = now + 10

		local watcher = fixture.taps[1]
		watcher.callback({
			getProperty = function() return 0 end,
			getType = function() return 4242 end,
		})
		for _, timer in ipairs(fixture.hs.timer.__timers or {}) do
			if timer.running and timer.delay == 0 then timer:fire() end
		end
		helpers.assert_true(not return_timer.running,
			"physical-input auto-disable must cancel the exact pending return handle")
	end)
end)





-- ================================================
-- ================================================
-- ======= 5/ Keep-Awake Timer Transactions =======
-- ================================================
-- ================================================

helpers.describe("keep-awake timer acquisition is transactional", function()
	helpers.it("rolls the watcher back and stays OFF when the first jitter timer returns false", function()
		local fixture = load_fixture({{}, {}}, {
			{ start_result = false, enable_on_start = true },
			{},
		})
		helpers.assert_eq(fixture.system.toggle_awake(), false)
		helpers.assert_eq(fixture.taps[1].stop_calls, 1,
			"the committed input watcher belongs to the rejected aggregate activation")
		helpers.assert_true(not fixture.timers[1].running,
			"activate-then-false timer acquisition must roll its exact candidate back")

		helpers.assert_eq(fixture.system.toggle_awake(), true,
			"the first false must leave state OFF, so the next toggle retries activation")
		helpers.assert_eq(#fixture.taps, 2)
		helpers.assert_eq(fixture.timer_created(), 2)
	end)

	helpers.it("contains start throw and blocks every successor while exact cleanup refuses", function()
		local fixture = load_fixture({{}, {}}, {
			{
				start_throw = "TIMER_START_THROW",
				enable_on_start = true,
				stop_throw_count = 2,
			},
			{},
		})
		local first_ok, first_result = pcall(fixture.system.toggle_awake)
		helpers.assert_true(first_ok,
			"timer start exceptions must not escape the user action")
		helpers.assert_eq(first_result, false)
		helpers.assert_true(fixture.timers[1].running,
			"the fixture must prove exact native cleanup debt survives rollback")

		helpers.assert_eq(fixture.system.toggle_awake(), false,
			"a refused cleanup retry must block replacement acquisition")
		helpers.assert_eq(#fixture.taps, 1,
			"the second attempt may not construct a successor watcher")
		helpers.assert_eq(fixture.timer_created(), 1,
			"the second attempt may not construct a successor timer")

		helpers.assert_eq(fixture.system.toggle_awake(), true,
			"once the exact debt settles, a clean activation is permitted")
		helpers.assert_eq(#fixture.taps, 2)
		helpers.assert_eq(fixture.timer_created(), 2)
	end)

	helpers.it("contains false and throw from the cursor-return timer and still schedules the next tick", function()
		for _, failed_plan in ipairs({
			{ start_result = false, enable_on_start = true },
			{ start_throw = "RETURN_START_THROW", enable_on_start = true },
		}) do
			local fixture = load_fixture({{}}, {
				{},
				failed_plan,
				{},
			})
			local moves = {}
			fixture.hs.mouse.absolutePosition = function(position)
				if position then moves[#moves + 1] = { x = position.x, y = position.y } end
				return { x = 100, y = 200 }
			end
			helpers.assert_eq(fixture.system.toggle_awake(), true)
			local tick = fixture.timers[1]
			local fire_ok, timer_count_or_err = pcall(function()
				tick:fire()
				return fixture.timer_created()
			end)
			helpers.assert_true(fire_ok,
				"a nested timer acquisition failure must not abort its async callback: "
					.. tostring(timer_count_or_err))
			helpers.assert_eq(timer_count_or_err, 3,
				"the contained tick must reach both the failed return timer and successor heartbeat")
			helpers.assert_true(not fixture.timers[2].running,
				"the rejected cursor-return candidate must be fenced and rolled back")
			helpers.assert_true(#moves >= 3,
				"failure must restore the jittered pointer immediately")
			helpers.assert_true(fixture.timers[3] and fixture.timers[3].running,
				"heartbeat and successor scheduling must survive the nested refusal")
		end
	end)
end)

return true
