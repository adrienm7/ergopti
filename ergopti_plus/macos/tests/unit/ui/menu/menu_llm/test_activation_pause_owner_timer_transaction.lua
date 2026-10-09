--- tests/unit/ui/menu/menu_llm/test_activation_pause_owner_timer_transaction.lua

--- Behavioral regression for the LLM activation pause owner's exact timer
--- ownership. The owner is loaded over the real TimerScheduler adapter; only
--- hs.timer and ScriptControl's public registration/state surface are faked.

local helpers = require("tests.helpers")

local MODES = { "false", "nil", "throw" }

local function mode_result(mode, message, success_value)
	if mode == "throw" then error(message) end
	if mode == "nil" then return nil end
	if mode == "false" then return false end
	return success_value
end

--- Builds observable native timers. Each candidate owns its own start/stop
--- modes so a retained failed candidate cannot be confused with a successor.
local function make_timer_backend(start_modes, stop_modes)
	local backend = { timers = {} }
	local timer_stub = {}

	function timer_stub.new(_, callback)
		local index = #backend.timers + 1
		local record = {
			callback = callback,
			running = false,
			start_calls = 0,
			stop_calls = 0,
			start_mode = start_modes[index] or "true",
			stop_mode = stop_modes[index] or "true",
			stop_receivers = {},
		}
		local native = {}

		function native:start()
			record.start_calls = record.start_calls + 1
			-- The native capability is live before an adverse return/throw.
			record.running = true
			return mode_result(record.start_mode, "native start refused", self)
		end

		function native:stop()
			record.stop_calls = record.stop_calls + 1
			record.stop_receivers[#record.stop_receivers + 1] = self
			local result = mode_result(record.stop_mode, "native stop refused", self)
			if record.stop_mode == "true" then record.running = false end
			return result
		end

		function native:running()
			return record.running
		end

		record.native = native
		backend.timers[index] = record
		return native
	end

	function timer_stub.secondsSinceEpoch()
		return 0
	end

	function backend.fire(index)
		backend.timers[index].callback()
	end

	return timer_stub, backend
end

local function make_script_control()
	local state = {
		paused = false,
		epoch = 0,
		owner = nil,
		registered_id = nil,
	}
	local script_control = {}

	function script_control.is_paused()
		return state.paused
	end

	function script_control.get_pause_epoch()
		return state.epoch
	end

	function script_control.register_pause_owner(owner_id, owner)
		if state.owner ~= nil then return false end
		state.registered_id = owner_id
		state.owner = owner
		return true
	end

	return script_control, state
end

local function find_owned_handle(TimerScheduler, native)
	for index = 1, 20 do
		local name, value = debug.getupvalue(TimerScheduler.cancelAll, index)
		if name == "_live_timers" then
			for _, handle in pairs(value) do
				if handle.timer == native then return handle end
			end
			return nil
		end
		if name == nil then break end
	end
	error("TimerScheduler live registry upvalue not found")
end

local function load_context(start_modes, stop_modes)
	local timer_stub, backend = make_timer_backend(start_modes, stop_modes)
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["ui.menu.menu_llm.activation_pause_owner"] = nil
	local TimerScheduler = helpers.load_with_stubs("adapters.timer_scheduler", {
		timer = timer_stub,
	})
	local ActivationPauseOwner = require("ui.menu.menu_llm.activation_pause_owner")
	local script_control, state = make_script_control()
	local continuation_calls = 0
	local controller = ActivationPauseOwner.new({ script_control = script_control })
	local token = controller.begin(function()
		continuation_calls = continuation_calls + 1
		return true
	end)

	helpers.assert_true(controller.is_registered())
	helpers.assert_eq(state.registered_id, "llm_activation")
	helpers.assert_not_nil(state.owner)
	helpers.assert_not_nil(token)

	return {
		backend = backend,
		controller = controller,
		continuation_calls = function() return continuation_calls end,
		owner = state.owner,
		state = state,
		timer_scheduler = TimerScheduler,
		token = token,
	}
end

local function commit_pause(ctx)
	ctx.state.epoch = ctx.state.epoch + 1
	helpers.assert_true(ctx.owner.pause())
	ctx.state.paused = true
end

local function begin_resume(ctx)
	ctx.state.epoch = ctx.state.epoch + 1
	return ctx.owner.resume()
end

helpers.describe("activation pause owner - exact TimerScheduler ownership", function()
	helpers.it("waits for the same due handle to settle after false/nil/throw stop", function()
		for _, stop_mode in ipairs(MODES) do
			local ctx = load_context({ "true" }, { stop_mode })
			local case = "due stop " .. stop_mode
			commit_pause(ctx)

			helpers.assert_true(begin_resume(ctx), case)
			helpers.assert_eq(#ctx.backend.timers, 1, case)
			local native_timer = ctx.backend.timers[1]
			local handle = find_owned_handle(ctx.timer_scheduler, native_timer.native)
			helpers.assert_not_nil(handle, case)
			ctx.state.paused = false

			ctx.backend.fire(1)
			helpers.assert_eq(ctx.continuation_calls(), 0,
				case .. " must not continue while the due native timer remains live")
			helpers.assert_true(handle.timer == native_timer.native,
				case .. " must retain the exact due timer")
			helpers.assert_eq(#handle.settlement_observers, 1,
				case .. " must observe settlement of that exact scheduler handle")
			helpers.assert_eq(#ctx.backend.timers, 1,
				case .. " must not create a sibling while cleanup is unresolved")

			native_timer.stop_mode = "true"
			ctx.backend.fire(1)
			helpers.assert_nil(handle.timer, case .. " must settle the exact handle")
			helpers.assert_eq(ctx.continuation_calls(), 1,
				case .. " must release exactly one continuation after settlement")
			helpers.assert_eq(#ctx.backend.timers, 1,
				case .. " settlement must not manufacture a successor")

			ctx.backend.fire(1)
			helpers.assert_eq(ctx.continuation_calls(), 1,
				case .. " duplicate native delivery must remain inert")
			helpers.assert_eq(native_timer.start_calls, 1, case)
			helpers.assert_eq(native_timer.stop_calls, 2, case)
			helpers.assert_true(ctx.controller.cancel(), case)
		end
	end)

	helpers.it("joins a mutate-then-refuse acquisition before any retry sibling", function()
		for _, start_mode in ipairs(MODES) do
			for _, stop_mode in ipairs(MODES) do
				local case = "start " .. start_mode .. ", rollback stop " .. stop_mode
				local ctx = load_context(
					{ start_mode, "true" },
					{ stop_mode, "true" })
				commit_pause(ctx)

				helpers.assert_eq(begin_resume(ctx), false,
					case .. " must refuse an uncommitted resume stage")
				helpers.assert_eq(#ctx.backend.timers, 1,
					case .. " must publish only the failed exact candidate")
				local failed_timer = ctx.backend.timers[1]
				local failed_handle = find_owned_handle(
					ctx.timer_scheduler, failed_timer.native)
				helpers.assert_not_nil(failed_handle, case)
				helpers.assert_true(failed_handle.timer == failed_timer.native,
					case .. " must retain the live mutate-then-refuse candidate")
				helpers.assert_eq(failed_timer.start_calls, 1, case)
				helpers.assert_eq(ctx.continuation_calls(), 0, case)

				-- ScriptControl rolls back the failed owner through pause(). A
				-- refusal must join this same capability, never arm a sibling.
				helpers.assert_eq(ctx.owner.pause(), false, case)
				helpers.assert_eq(#ctx.backend.timers, 1,
					case .. " rollback refusal must not create a sibling")
				helpers.assert_eq(ctx.owner.resume(), false,
					case .. " retry must first join unresolved rollback debt")
				helpers.assert_eq(#ctx.backend.timers, 1,
					case .. " unresolved debt must suppress a retry sibling")

				failed_timer.stop_mode = "true"
				helpers.assert_true(ctx.owner.pause(), case)
				helpers.assert_nil(failed_handle.timer,
					case .. " rollback must settle the original handle")
				helpers.assert_eq(#ctx.backend.timers, 1, case)
				helpers.assert_eq(failed_timer.stop_calls, 4,
					case .. " must retry cleanup only on the retained candidate")
				for _, receiver in ipairs(failed_timer.stop_receivers) do
					helpers.assert_true(receiver == failed_timer.native,
						case .. " cleanup crossed only the original native capability")
				end

				ctx.state.epoch = ctx.state.epoch + 1
				helpers.assert_true(ctx.owner.resume(),
					case .. " may retry only after exact settlement")
				helpers.assert_eq(#ctx.backend.timers, 2,
					case .. " must create exactly one post-settlement retry")
				helpers.assert_eq(ctx.backend.timers[2].start_calls, 1, case)
				helpers.assert_eq(ctx.continuation_calls(), 0, case)

				helpers.assert_true(ctx.owner.pause(), case)
				helpers.assert_eq(ctx.timer_scheduler.activeCount(), 0, case)
				ctx.backend.fire(1)
				ctx.backend.fire(2)
				helpers.assert_eq(ctx.continuation_calls(), 0,
					case .. " callbacks retained after rollback must be inert")
				helpers.assert_true(ctx.controller.cancel(), case)
			end
		end
	end)
end)

return true
