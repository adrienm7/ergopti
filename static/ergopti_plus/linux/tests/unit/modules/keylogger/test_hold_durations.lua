--- tests/unit/modules/keylogger/test_hold_durations.lua

--- ==============================================================================
--- MODULE: How Long A Key Was Held
--- DESCRIPTION:
--- The per-key hold statistics, and the layout figures recorded beside them.
---
--- WHAT WAS MISSING, AND THE REASON IT WAS BELIEVED UNREACHABLE:
--- agg_app_day_kc_hold was written off as out of reach because "the capture loop
--- throws releases away". It does — for the TEXT path, where a release carries
--- no meaning. It was never true for the metrics: the release passes through the
--- hook before that early return, and measuring it there is four lines.
---
--- On a keyboard whose whole design is dual-role keys, how long a key was held
--- is the difference between the two things it can mean. The table that answers
--- that was empty.
---
--- WHY THE TAP/HOLD SPLIT CAN DECLINE TO ANSWER:
--- The threshold is read from the tap-hold configuration the tap-hold engine
--- actually runs, so this driver calls something a hold exactly when the
--- engine does. When the keys disagree, or nothing can be read, there IS no single
--- answer — and the split is skipped rather than made on a number nobody chose.
--- The duration, the count and the maximum need no threshold and are recorded
--- either way.
--- ==============================================================================

local helpers = require("tests.helpers")
local it = require("tests.support.metrics_preferences_fixture").it

local Fakes = helpers.load_module("tests.fakes")

--- Runs a body against a fresh keylogger over the shared writer double.
--- @param body function Receives the keylogger.
--- @return table The double.
local function with_writer(body)
	local writer_name = "modules.keylogger.sqlite_writer"
	local logger_name = "modules.keylogger.keylogger"
	local previous_writer = package.loaded[writer_name]
	local previous_logger = package.loaded[logger_name]

	local writer = Fakes.sqlite_writer()
	package.loaded[writer_name] = writer
	package.loaded[logger_name] = nil

	local ok, err = pcall(function()
		local keylogger = require(logger_name)
		keylogger.init({ sqlite_path = "/tmp/ergopti_hold_probe.sqlite" })
		require("tests.support.metrics_consent_fixture").enable(keylogger)
		keylogger.reset_session()
		body(keylogger)
	end)

	package.loaded[writer_name] = previous_writer
	package.loaded[logger_name] = previous_logger
	helpers.assert_true(ok, "the flush must complete: " .. tostring(err))
	return writer
end

--- The rows written for one evdev code.
--- @param writer table
--- @param code number
--- @return table|nil
local function row_for(writer, code)
	local total = nil
	for _, entry in ipairs(writer.kc_hold) do
		if entry.row.keycode == code then
			total = total or { sum_ms = 0, count = 0, max_ms = 0, tap_count = 0, hold_count = 0 }
			total.sum_ms = total.sum_ms + entry.row.sum_ms
			total.count = total.count + entry.row.count
			total.max_ms = math.max(total.max_ms, entry.row.max_ms)
			total.tap_count = total.tap_count + entry.row.tap_count
			total.hold_count = total.hold_count + entry.row.hold_count
		end
	end
	return total
end




-- =================================================================
-- =================================================================
-- ======= 1/ The durations ========================================
-- =================================================================
-- =================================================================

helpers.describe("hold durations: what is recorded", function()

	it("accumulates the time a key spent down", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("code", 1000)
			keylogger.record_hold("code", 30, 120)
			keylogger.record_hold("code", 30, 80)
			keylogger.flush()
		end)

		local row = row_for(writer, 30)
		helpers.assert_not_nil(row,
			"this table was written off as unreachable because the capture loop "
				.. "throws releases away — true for the text path, never true for the "
				.. "metrics, where the release passes through the hook first")
		helpers.assert_eq(row.sum_ms, 200)
		helpers.assert_eq(row.count, 2)
	end)

	it("keeps the longest hold as a record", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("code", 1000)
			keylogger.record_hold("code", 30, 400)
			keylogger.record_hold("code", 30, 90)
			keylogger.flush()
		end)
		helpers.assert_eq(row_for(writer, 30).max_ms, 400,
			"the longest hold of the day does not get shorter because a quick tap "
				.. "followed it")
	end)

	it("keeps two keys apart", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("code", 1000)
			keylogger.record_hold("code", 30, 100)
			keylogger.record_hold("code", 31, 500)
			keylogger.flush()
		end)
		helpers.assert_eq(row_for(writer, 30).sum_ms, 100)
		helpers.assert_eq(row_for(writer, 31).sum_ms, 500,
			"the table is per key because the question is which keys are being "
				.. "held, and one average over the board answers nothing")
	end)

	it("writes only the increment on a second flush", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("code", 1000)
			keylogger.record_hold("code", 30, 100)
			keylogger.flush()
			keylogger.record_hold("code", 30, 100)
			keylogger.flush()
		end)
		helpers.assert_eq(row_for(writer, 30).count, 2,
			"the row sums on conflict, so writing the cumulative total again would "
				.. "count every earlier press once more per flush")
	end)

	it("records nothing while metrics are switched off", function()
		local writer = with_writer(function(keylogger)
			keylogger.set_enabled(false)
			keylogger.on_app_focus("code", 1000)
			keylogger.record_hold("code", 30, 100)
			keylogger.flush()
			keylogger.set_enabled(true)
		end)
		helpers.assert_eq(#writer.kc_hold, 0,
			"a hold is a keystroke seen from the other side, and it passes the same "
				.. "filters")
	end)

	it("ignores a negative or absent duration", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("code", 1000)
			keylogger.record_hold("code", 30, -5)
			keylogger.record_hold("code", 30, nil)
			keylogger.flush()
		end)
		helpers.assert_eq(#writer.kc_hold, 0,
			"a clock that went backwards across a suspend would otherwise put a "
				.. "negative number into an average nobody could then explain")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ The threshold ========================================
-- =================================================================
-- =================================================================

helpers.describe("hold durations: tap or hold", function()

	--- Runs `body(threshold)` with the tap-hold manager on keys that all agree
	--- on one threshold, or on the shared defaults (which disagree) when `seconds`
	--- is nil.
	local function with_tap_holds(seconds, body)
		local TapHold = helpers.load_module("platform.remap.tap_hold_manager")
		local user_path = os.tmpname()
		local fh = assert(io.open(user_path, "w"))
		if seconds then
			fh:write('[tap_hold]\ninherit_defaults = false\n[tap_hold.keys.caps_lock]\n'
				.. 'tap_action = "enter"\nhold_modifier = "ctrl"\ntime_activation_seconds = ' .. seconds .. '\n')
		end
		fh:close()
		TapHold.init({
			keyboard_hook = { set_remapper = function() end, key_text = function() return nil end,
				held_modifiers = function() return {} end,
				held_text_modifier_codes = function() return {} end,
				held_shortcut_modifier_codes = function() return {} end },
			execute_action = function() end,
			on_text_injected = function() end,
			action_names = function() return {} end,
			defaults_path = require("infra.paths").shared("tap_hold/defaults.toml"),
			user_path = user_path,
		})
		local ok, err = pcall(body, TapHold.threshold_ms())
		TapHold._reset_for_test()
		os.remove(user_path)
		if not ok then error(err, 0) end
	end

	it("declines the split when the configured keys disagree", function()
		with_tap_holds(nil, function(threshold)
			helpers.assert_nil(threshold, "the shared defaults mix 0.35 s and 0.2 s")
		end)
	end)

	it("splits on the threshold the tap-hold engine runs", function()
		with_tap_holds(0.25, function(threshold)
			helpers.assert_eq(threshold, 250)
			local writer = with_writer(function(keylogger)
				keylogger.on_app_focus("code", 1000)
				keylogger.record_hold("code", 30, threshold + 50)
				keylogger.record_hold("code", 30, threshold - 50)
				keylogger.flush()
			end)
			local row = row_for(writer, 30)
			helpers.assert_eq(row.hold_count, 1,
				"reading the threshold from what the engine runs is what stops the "
					.. "dashboard calling something a tap that the keyboard treated as a hold")
			helpers.assert_eq(row.tap_count, 1)
		end)
	end)

end)


--- tests/unit/modules/keylogger/test_hold_exclusion_epoch.lua

--- ==============================================================================
--- MODULE: Physical Hold Exclusion Epochs
--- DESCRIPTION:
--- Exercises the real hook and collector over explicit evdev, clock and writer
--- ports. Main callback bodies are loaded from their genuine source; the daemon,
--- native descriptors and desktop session are not started by this fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Preferences = require("tests.support.metrics_preferences_fixture")
local Fakes = require("tests.fakes")
local root = helpers.driver_root()
local file = assert(io.open(root .. "/ergopti_hotstrings.lua", "r"))
local main = file:read("*a")
file:close()

local function source_callback(body, environment)
	setmetatable(environment, { __index = _G })
	local chunk
	if loadstring then
		chunk = assert(loadstring("return function" .. body .. "\nend"))
		setfenv(chunk, environment)
	else
		chunk = assert(load("return function" .. body .. "\nend", "main callback", "t", environment))
	end
	return chunk()
end

local function run_hold(transition, expected, options)
	options = options or {}
	local writer_name, logger_name = "modules.keylogger.sqlite_writer", "modules.keylogger.keylogger"
	local previous_writer, previous_logger = package.loaded[writer_name], package.loaded[logger_name]
	local clock = require("infra.monotonic")
	local previous_clock, now = clock.now_ms, 100
	local writer = Fakes.sqlite_writer()
	package.loaded[writer_name], package.loaded[logger_name] = writer, nil
	local ok, err = pcall(function()
		local logger = require(logger_name)
		logger.init({ sqlite_path = os.tmpname() })
		require("tests.support.metrics_consent_fixture").enable(logger)
		logger.reset_session()
		logger.on_app_focus("code", 100)
		clock.now_ms = function() return now end
		local state = { paused = false }
		local noop = function() end
		local environment = {
			keylogger = logger,
			script_actions = { is_paused = function() return state.paused end },
			MagicKeySource = { cancel_capture = noop },
			TapHold = { set_paused = noop },
			Logger = helpers.make_logger_stub(),
			engine = { reset = noop },
			secure_focus_guard = { invalidate = noop, blocks_text = function() return false end },
		}
		local block = assert(main:match("input_capture_gate = InputCaptureGate.new%({%s*on_block = function(.-)\n\t\tend,"))
		local gate = require("infra.input_capture_gate").new({ on_block = source_callback(block, environment) })
		environment.input_capture_gate = gate
		local pause_body = assert(main:match("on_pause_change = function(.-)\n\t\tend,"))
		local on_pause = source_callback(pause_body, environment)
		local reset_body = assert(main:match("ScriptActions.new%({%s*reset = function(.-)\n\t\tend,"))
		local reset = source_callback(reset_body, environment)
		state.pause_callbacks = {}
		local controller
		controller = require("modules.shortcuts.script_actions").new({
			reset = reset, reload = noop, quit = noop,
			on_pause_change = function(paused)
				state.pause_callbacks[#state.pause_callbacks + 1] = tostring(paused)
				on_pause(paused)
			end,
		})
		environment.script_actions = controller
		environment.engine.reset = function()
			if options.reenter_pause and controller.is_paused() then controller.toggle_pause() end
		end
		state.controller = controller
		state.pause = function(value) if controller.is_paused() ~= value then controller.toggle_pause() end end
		state.gate = gate
		-- Execute the genuine main physical/hold callback closure together, so the
		-- existing captured-press bookkeeping is shared exactly as in production.
		local physical = assert(main:match("(local capture_owned_scancodes = {}.-)\n\t%-%- 8.6"))
		local hold_start = main:find("local hold_token = keylogger.hold_accounting_token", 1, true)
			or assert(main:find("local function handle_hold", 1, true))
		local hold_end = assert(main:find("\n\t%-%- Retain the selected inverse publisher", hold_start))
		environment.InputEvent = require("infra.input_event")
		environment.Monotonic = clock
		environment._cached_app_id = "code"
		local startup = assert(main:match("keyboard_hook.start%(%{(.-)\n\t%}%)"))
		local binding = startup:match("onHoldAdmission%s*=%s*([%w_]+),") or "nil"
		local text = physical .. "\n" .. main:sub(hold_start, hold_end - 1)
			.. "\nreturn { physical = on_physical, hold = on_hold, admission = " .. binding .. " }"
		local chunk
		if loadstring then chunk = assert(loadstring(text)); setfenv(chunk, environment)
		else chunk = assert(load(text, "main metrics callbacks", "t", environment)) end
		local callbacks = chunk()

		if options.before then options.before(logger, state) end
		local hook = helpers.load_module("adapters.keyboard_hook")
		local forwarded = {}
		local changed = false
		local stream = {
			{ type = 1, code = 30, value = 1 },
			{ type = 1, code = 30, value = 2 },
			{ type = 1, code = 30, value = 0 },
		}
		if options.second then
			stream[#stream + 1] = { type = 1, code = 30, value = 1 }
			stream[#stream + 1] = { type = 1, code = 30, value = 0 }
		end
		local physical_index = 0
		hook._test_drive(stream, {
			onHoldAdmission = callbacks.admission,
			onPhysical = function(code, name, char, value)
				physical_index = physical_index + 1
				now = ({ 100, 400, 500, 600 })[physical_index]
				callbacks.physical(code, name, char, value)
			end,
			onHold = callbacks.hold,
			onEmitRaw = function(code, value)
				forwarded[#forwarded + 1] = code .. ":" .. value
				if value == 1 and not changed then
					changed = true
					now = 200
					transition(logger, state)
					now = 300
				end
				return true
			end,
		}, true)
		helpers.assert_eq(table.concat(forwarded, " "), options.second and "30:1 30:2 30:0 30:1 30:0"
			or "30:1 30:2 30:0", "physical delivery is unchanged")
		logger.flush()
		local total = 0
		for _, entry in ipairs(writer.kc_hold) do total = total + entry.row.sum_ms end
		helpers.assert_eq(total, expected, "excluded time must not be reconstructed by physical UP")
	end)
	clock.now_ms = previous_clock
	package.loaded[writer_name], package.loaded[logger_name] = previous_writer, previous_logger
	if not ok then error(err, 0) end
end

helpers.describe("physical hold exclusion epochs", function()
	Preferences.it("retires the whole hold across a private interval without another key", function()
		run_hold(function(logger) logger.set_private_window(true); logger.set_private_window(false) end, 0)
	end)
	Preferences.it("never starts an eligible hold inside a private interval", function()
		run_hold(function(logger) logger.set_private_window(false) end, 0,
			{ before = function(logger) logger.set_private_window(true) end })
	end)
	Preferences.it("preserves included policy updates and repeat timing", function()
		run_hold(function(logger)
			logger.set_private_window(false)
			helpers.assert_true(logger.set_private_filter_enabled(true))
		end, 300)
	end)
	Preferences.it("preserves a hold after a refused durable policy update", function()
		run_hold(function(logger)
			Preferences.with(function() helpers.assert_eq(logger.set_enabled(false), false) end, { writes_fail = true })
		end, 300)
	end)
	Preferences.it("retires the whole hold across a secure-field interval", function()
		run_hold(function(logger) logger.set_secure_field(true); logger.set_secure_field(false) end, 0)
	end)
	Preferences.it("retires the whole hold across metrics disable and reenable", function()
		run_hold(function(logger)
			helpers.assert_true(logger.set_enabled(false)); helpers.assert_true(logger.set_enabled(true))
		end, 0)
	end)
	Preferences.it("retires the whole hold across suppression and unsuppression", function()
		run_hold(function(logger) logger.suppress(); logger.unsuppress() end, 0)
	end)
	Preferences.it("retires the whole hold through the actual main pause callback", function()
		run_hold(function(_, state) state.pause(true); state.pause(false) end, 0)
	end)
	Preferences.it("retires the whole hold through the actual main capture callback", function()
		run_hold(function(_, state)
			helpers.assert_true(state.gate.acquire("fixture", 1))
			helpers.assert_true(state.gate.release("fixture", 1))
		end, 0)
	end)
	Preferences.it("retires the whole hold across authentication focus without a key", function()
		run_hold(function(logger) logger.on_app_focus("polkit", 200); logger.on_app_focus("code", 300) end, 0)
	end)
	Preferences.it("keeps a fresh allowed press after releasing a captured press", function()
		run_hold(function(_, state) helpers.assert_true(state.gate.release("fixture", 1)) end, 100, {
			before = function(_, state) helpers.assert_true(state.gate.acquire("fixture", 1)) end,
			second = true,
		})
	end)
	Preferences.it("retains observed authentication focus across a statistics reset", function()
		run_hold(function(logger)
			helpers.assert_true(logger.set_system_auth_filter_enabled(true))
			helpers.assert_true(logger.set_system_auth_filter_enabled(false))
		end, 0, { before = function(logger)
			helpers.assert_true(logger.set_system_auth_filter_enabled(false))
			logger.on_app_focus("polkit", 50)
			logger.reset_session()
		end })
	end)
	Preferences.it("counts the first ordinary press after leaving an authentication app", function()
		run_hold(function() end, 300, { before = function(logger)
			logger.on_app_focus("polkit", 25)
			logger.suppress()
			logger.on_app_focus("code", 50)
		end })
	end)
	Preferences.it("publishes the hold callback only after successful owned startup", function()
		local function admission_of(hook)
			for index = 1, 100 do
				local name, value = debug.getupvalue(hook.start, index)
				if name == nil then break end
				if name == "_on_hold_admission" then return value end
			end
			return nil
		end
		local first, replacement = function() return {} end, function() return {} end
		local checked = false
		require("tests.support.input_owner_fixture").with_session({
			before_hook = function(session)
				local original_start = session.hook.start
				session.hook.start = function(options)
					session.hook.start = original_start
					options.onHoldAdmission = first
					return original_start(options)
				end
			end,
			on_capture_reset = function()
				-- The real startup XKB reset is reentrant foreign work. Its
				-- observations must precede admission of the tentative owner.
				local hook = require("adapters.keyboard_hook")
				helpers.assert_nil(admission_of(hook))
				checked = true
				return true
			end,
		}, function(session)
			helpers.assert_true(checked)
			helpers.assert_true(rawequal(admission_of(session.hook), first))
			session.hook.stop()
			helpers.assert_eq(session.hook.start({ numberRowMode = "invalid",
				onHoldAdmission = replacement }), false)
			helpers.assert_true(rawequal(admission_of(session.hook), first), "refused start preserves the admitted callback")
		end)
	end)
	Preferences.it("retires at pause entry even when reset synchronously resumes", function()
		run_hold(function(_, state)
			state.pause(true)
			helpers.assert_eq(state.controller.is_paused(), false)
			helpers.assert_eq(table.concat(state.pause_callbacks, ","), "false,false")
		end, 0, { reenter_pause = true })
	end)
end)
