--- tests/unit/modules/shortcuts/test_pause_transaction.lua

--- ==============================================================================
--- MODULE: Script-Control Pause Transaction Regression Tests
--- DESCRIPTION:
--- Drives the public pause/resume API across the script-control and Karabiner
--- boundary. Pause commits after PAUSED; resume commits only after the remap
--- layer reports RESUMED, publication, READY and input startup complete. Failed
--- or duplicated callbacks must never create a half-resumed driver.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================
-- ===========================================
-- ======= 1/ Transaction Test Harness =======
-- ===========================================
-- ===========================================

--- Loads a fresh script-control module over observable subsystem doubles.
--- @param options table|nil Failure injection options.
--- @return table script_control
--- @return table ctx
local function load_context(options)
	options = options or {}
	local ctx = {
		calls = {},
		call_order = {},
		notifications = {},
		errors = {},
		warnings = {},
		pause_callback = nil,
		pause_callbacks = {},
		resume_callback = nil,
		pause_listener = {},
		resume_failure = options.resume_failure,
	}

	local function record(name)
		return function()
			ctx.calls[name] = (ctx.calls[name] or 0) + 1
			ctx.call_order[#ctx.call_order + 1] = name
			local failure = ctx.resume_failure
			if failure and failure.step == name then
				if failure.mode == "throw" then error(name .. " exploded") end
				if failure.mode == "false" then return false, name .. " refused" end
			end
			return true
		end
	end

	local logger = helpers.make_logger_stub()
	logger.error = function(_module, format_string, ...)
		ctx.errors[#ctx.errors + 1] = string.format(format_string, ...)
	end
	logger.warn = function(_module, format_string, ...)
		ctx.warnings[#ctx.warnings + 1] = string.format(format_string, ...)
	end
	package.loaded["infra.logger"] = logger
	package.loaded["infra.notifications"] = {
		notify = function(title, body, kind)
			ctx.notifications[#ctx.notifications + 1] = {
				title = title,
				body = body,
				kind = kind,
			}
		end,
	}
	package.loaded["infra.keycodes"] = {
		F13_KARABINER_RETURN = 0x6A,
		F14_KARABINER_BACKSPACE = 0x6B,
		F15_KARABINER_ESCAPE = 0x6C,
		BACKSPACE = 0x33,
		RETURN = 0x24,
		ESCAPE = 0x35,
	}
	package.loaded["modules.gestures.engine"] = {}
	package.loaded["modules.gestures.actions"] = {
		get_label = function(name) return name end,
		execute_single = function() return true end,
		SG_NAMES = { "none", "script_pause_toggle" },
		AX_NAMES = {},
	}
	package.loaded["adapters.key_state"] = {
		is_right_altgr_held = function() return false end,
		describe_held_modifiers = function() return "(none)" end,
	}
	package.loaded["modules.llm.warmup_controller"] = {
		stop = record("warmup_stop"),
		schedule_warmup_with_retry = record("warmup_resume"),
	}
	package.loaded["modules.llm.api_mlx"] = {
		stop_warmup = record("mlx_stop"),
		resume_warmup = record("mlx_resume"),
	}
	package.loaded["modules.llm.api_ollama"] = {
		stop_warmup = record("ollama_stop"),
	}
	package.loaded["ui.tooltip"] = { hide_forced = record("tooltip_hide") }
	package.loaded["modules.keylogger"] = {
		resync_context = record("keylogger_resync"),
		log_shortcut = function() end,
	}

	local script_control = helpers.load_with_stubs("modules.shortcuts.script_control")
	local keymap = {
		pause_processing = record("keymap_pause"),
		resume_processing = record("keymap_resume"),
		reset_predictions = record("keymap_reset"),
	}
	local shortcuts = {
		pause_bindings = record("shortcuts_pause"),
		resume_bindings = record("shortcuts_resume"),
		is_bindings_started = function() return true end,
	}
	local gestures = {
		suspend = record("gestures_pause"),
		resume = record("gestures_resume"),
		is_enabled = function() return true end,
	}
	local karabiner = {
		get_enabled = function() return true end,
		pause = function(callback)
			ctx.calls.karabiner_pause = (ctx.calls.karabiner_pause or 0) + 1
			ctx.pause_callback = callback
			ctx.pause_callbacks[#ctx.pause_callbacks + 1] = callback
			return true
		end,
		resume = function(callback)
			ctx.calls.karabiner_resume = (ctx.calls.karabiner_resume or 0) + 1
			ctx.resume_callback = callback
			return true
		end,
	}

	script_control.start(keymap, shortcuts, gestures, karabiner)
	script_control.set_on_pause_change(function(value)
		ctx.pause_listener[#ctx.pause_listener + 1] = value
	end)

	--- Fires only live one-shot zero-delay work, never the recurring tap watchdog.
	function ctx.fire_deferred()
		for _, timer in ipairs(hs.timer.__timers) do
			if timer.delay == 0 and timer.recurring ~= true and timer.running then timer:fire() end
		end
	end

	return script_control, ctx
end

local function count_notifications(ctx, title, kind)
	local count = 0
	for _, item in ipairs(ctx.notifications) do
		if item.title == title and item.kind == kind then count = count + 1 end
	end
	return count
end

local function has_error_containing(ctx, needle)
	for _, message in ipairs(ctx.errors) do
		if message:find(needle, 1, true) then return true end
	end
	return false
end

local function has_warning_containing(ctx, needle)
	for _, message in ipairs(ctx.warnings) do
		if message:find(needle, 1, true) then return true end
	end
	return false
end





-- ===========================================
-- ===========================================
-- ======= 2/ ACK-Ordered Pause Commit =======
-- ===========================================
-- ===========================================

helpers.describe("script-control pause transaction waits for exact lease ACK", function()
	helpers.it("does not publish or quiesce pause before PAUSED, then commits once", function()
		local script_control, ctx = load_context()

		script_control.pause_all()
		helpers.assert_eq(script_control.is_paused(), false,
			"requesting pause must not publish a committed state")
		helpers.assert_eq(ctx.calls.karabiner_pause, nil,
			"the native transition request must be deferred off the caller/eventtap")
		helpers.assert_eq(ctx.calls.keymap_pause, nil,
			"Hammerspoon submodules must remain in their settled state before PAUSED")
		helpers.assert_eq(#ctx.pause_listener, 0, "listeners must wait for the exact ACK")
		helpers.assert_eq(#ctx.notifications, 0, "success notification must wait for the exact ACK")

		ctx.fire_deferred()
		helpers.assert_eq(ctx.calls.karabiner_pause, 1)
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_eq(ctx.calls.keymap_pause, nil)

		ctx.pause_callback(true, "paused")
		helpers.assert_eq(script_control.is_paused(), true)
		helpers.assert_eq(ctx.calls.keymap_pause, 1)
		helpers.assert_eq(ctx.calls.shortcuts_pause, 1)
		helpers.assert_eq(ctx.calls.gestures_pause, 1)
		helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))
		helpers.assert_eq(count_notifications(ctx, "script_control.paused", "warning"), 1)

		ctx.pause_callback(true, "duplicate-paused")
		helpers.assert_eq(ctx.calls.keymap_pause, 1,
			"a duplicated native callback must not commit the pause twice")
		helpers.assert_eq(count_notifications(ctx, "script_control.paused", "warning"), 1)
		script_control.stop()
	end)
end)




-- ============================================
-- ============================================
-- ======= 3/ Resume Failure Is Atomic ========
-- ============================================
-- ============================================

helpers.describe("script-control resume transaction is atomic", function()
	helpers.it("keeps pause and resumes zero Hammerspoon modules when RESUMED fails", function()
		local script_control, ctx = load_context()
		script_control.pause_all()
		ctx.fire_deferred()
		ctx.pause_callback(true, "paused")

		script_control.resume_all()
		ctx.fire_deferred()
		helpers.assert_eq(ctx.calls.karabiner_resume, 1)
		helpers.assert_eq(script_control.is_paused(), true,
			"resume request must keep the last ACKed pause state")
		helpers.assert_eq(ctx.calls.keymap_resume, nil)
		helpers.assert_eq(ctx.calls.shortcuts_resume, nil)
		helpers.assert_eq(ctx.calls.gestures_resume, nil)

		ctx.resume_callback(false, "cli-failed")
		helpers.assert_eq(script_control.is_paused(), true,
			"a failed CLI transition must leave the script fully paused")
		helpers.assert_eq(ctx.calls.keymap_resume, nil,
			"failure must resume zero Hammerspoon submodules")
		helpers.assert_eq(ctx.calls.shortcuts_resume, nil)
		helpers.assert_eq(ctx.calls.gestures_resume, nil)
		helpers.assert_true(#ctx.errors >= 1, "the failure must be logged")
		helpers.assert_eq(count_notifications(ctx, "script_control.resume_failed", "error"), 1,
			"the user must see a non-blocking failure notification")
		helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }),
			"no resume listener may fire for a failed transition")
		script_control.stop()
	end)

	helpers.it("commits a successful completed-resume callback exactly once", function()
		local script_control, ctx = load_context()
		script_control.pause_all()
		ctx.fire_deferred()
		ctx.pause_callback(true, "paused")

		script_control.resume_all()
		ctx.fire_deferred()
		ctx.resume_callback(true, "resumed")
		ctx.resume_callback(true, "duplicate-resumed")

		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_eq(ctx.calls.keymap_resume, 1)
		helpers.assert_eq(ctx.calls.shortcuts_resume, 1)
		helpers.assert_eq(ctx.calls.gestures_resume, 1)
		helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true, false }))
		helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 1)
		script_control.stop()
	end)

	helpers.it("rolls every partial local resume back before publishing any failure", function()
		local resume_steps = {
			{ step = "keymap_resume", label = "keymap.resume_processing", rollback = "keymap_pause" },
			{ step = "shortcuts_resume", label = "shortcuts.resume_bindings", rollback = "shortcuts_pause" },
			{ step = "gestures_resume", label = "gestures.resume", rollback = "gestures_pause" },
			{ step = "mlx_resume", label = "api_mlx.resume_warmup", rollback = "mlx_stop" },
			{ step = "warmup_resume", label = "warmup_controller.schedule_warmup_with_retry", rollback = "warmup_stop" },
		}
		local failure_modes = { "throw", "false" }

		for _, mode in ipairs(failure_modes) do
			for failed_index, failed_step in ipairs(resume_steps) do
				local script_control, ctx = load_context({
					resume_failure = { step = failed_step.step, mode = mode },
				})
				script_control.pause_all()
				ctx.fire_deferred()
				ctx.pause_callbacks[1](true, "paused")

				script_control.resume_all()
				ctx.fire_deferred()
				local resume_order_start = #ctx.call_order + 1
				ctx.resume_callback(true, "resumed")

				helpers.assert_eq(script_control.is_paused(), true,
					mode .. " from " .. failed_step.step .. " must preserve the committed pause state")
				helpers.assert_eq(ctx.calls.karabiner_pause, 2,
					"a partial local resume must immediately request a native re-pause")
				helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 0,
					"partial local resume must never publish success")
				helpers.assert_eq(count_notifications(ctx, "script_control.resume_failed", "error"), 0,
					"failure must remain unpublished until the native re-pause is acknowledged")
				helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }),
					"listeners must keep observing pause throughout local rollback")
				local failed_attempts = ctx.calls[failed_step.step]
				ctx.resume_callback(true, "duplicate-resumed")
				helpers.assert_eq(ctx.calls[failed_step.step], failed_attempts,
					"a duplicate RESUMED callback must not re-enter local activation during native rollback")
				helpers.assert_eq(ctx.calls.karabiner_pause, 2,
					"a duplicate RESUMED callback must not request a second rollback")

				for step_index, step in ipairs(resume_steps) do
					if step.rollback then
						local expected = step_index <= failed_index and 2 or 1
						helpers.assert_eq(ctx.calls[step.rollback], expected,
							step.rollback .. " must be the exact inverse for " .. failed_step.step)
					end
				end
				local expected_order = {}
				for step_index = 1, failed_index do
					expected_order[#expected_order + 1] = resume_steps[step_index].step
				end
				for step_index = failed_index, 1, -1 do
					expected_order[#expected_order + 1] = resume_steps[step_index].rollback
				end
				local actual_order = {}
				for index = resume_order_start, #ctx.call_order do
					actual_order[#actual_order + 1] = ctx.call_order[index]
				end
				helpers.assert_true(helpers.deep_equal(actual_order, expected_order),
					"rollback must apply exact inverses in reverse activation order")

				ctx.pause_callbacks[2](true, "re-paused")
				helpers.assert_eq(script_control.is_paused(), true)
				helpers.assert_eq(count_notifications(ctx, "script_control.resume_failed", "error"), 1,
					"failure may be published only after native PAUSED")
				helpers.assert_true(has_error_containing(ctx, failed_step.label),
					"the root failing resume step must be named in the file logger")
				helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))

				ctx.resume_failure = nil
				script_control.resume_all()
				ctx.fire_deferred()
				ctx.resume_callback(true, "retry-resumed")
				helpers.assert_eq(script_control.is_paused(), false,
					"a clean retry after rollback must remain reachable")
				helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true, false }))
				script_control.stop()
			end
		end
	end)

	helpers.it("keeps optional keylogger resync failures outside the activation transaction", function()
		for _, mode in ipairs({ "false", "throw" }) do
			local script_control, ctx = load_context({
				resume_failure = { step = "keylogger_resync", mode = mode },
			})
			script_control.pause_all()
			ctx.fire_deferred()
			ctx.pause_callbacks[1](true, "paused")

			script_control.resume_all()
			ctx.fire_deferred()
			ctx.resume_callback(true, "resumed")

			helpers.assert_eq(ctx.calls.keylogger_resync, 1,
				"resume must still attempt the optional context refresh")
			helpers.assert_eq(script_control.is_paused(), false,
				"metrics OFF/uninitialized keylogger must not block an otherwise complete resume")
			helpers.assert_eq(ctx.calls.karabiner_pause, 1,
				"a non-activating optional failure must not roll native remapping back")
			helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 1)
			helpers.assert_eq(count_notifications(ctx, "script_control.resume_failed", "error"), 0)
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true, false }))
			helpers.assert_true(has_warning_containing(ctx, "keylogger.resync_context"),
				"the optional failure must remain visible in the file logger")
			script_control.stop()
		end
	end)

	helpers.it("serializes a rapid pause then resume without overlapping native input", function()
		local script_control, ctx = load_context()
		script_control.pause_all()
		script_control.resume_all()
		ctx.fire_deferred()

		helpers.assert_eq(ctx.calls.karabiner_pause, 1)
		helpers.assert_eq(ctx.calls.karabiner_resume, nil,
			"the reversal must wait for PAUSED instead of overlapping controller input")
		ctx.pause_callback(true, "paused")
		helpers.assert_eq(script_control.is_paused(), true)

		ctx.fire_deferred()
		helpers.assert_eq(ctx.calls.karabiner_resume, 1)
		ctx.resume_callback(true, "resumed")
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_eq(ctx.calls.keymap_pause, 1)
		helpers.assert_eq(ctx.calls.keymap_resume, 1)
		helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true, false }))
		script_control.stop()
	end)
end)
