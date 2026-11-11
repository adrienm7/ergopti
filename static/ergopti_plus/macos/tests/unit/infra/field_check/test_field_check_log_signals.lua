--- tests/unit/infra/field_check/test_field_check_log_signals.lua

--- ==============================================================================
--- MODULE: Field Check, Named Log Signals
--- DESCRIPTION:
--- The field run's `field_log_signals` step reads the day-log lines several
--- Mac checks close on (TODO, To confirm on the Mac). These cases run the real
--- awk program over lines in the canonical Logger shape, so a renamed message or
--- a pattern the awk cannot read fails here rather than reporting 0 on the Mac,
--- and they pin how the counts become pass, fail and information steps.
--- ==============================================================================

local helpers = require("tests.helpers")
local Report = require("field_check_report")
local Signals = require("infra.field_check_log_signals")

local function steps_of(report)
	local steps = {}
	for _, step in ipairs(report.result().steps) do steps[step.id] = step end
	return steps
end

--- Runs the check over a canned awk answer.
--- @param code integer|nil
--- @param output string|nil
--- @return table steps
local function run(code, output)
	local report = Report.new_report("log_signals")
	local finished = 0
	Signals.log_signals({
		today_log_path = function() return "/logs/today.log" end,
		exec = function(executable, args, _, callback)
			helpers.assert_eq(executable, "/usr/bin/awk")
			helpers.assert_eq(args[1], Signals.LOG_SIGNALS_AWK)
			helpers.assert_eq(args[2], "/logs/today.log")
			callback(code, output)
		end,
	}, report, function() finished = finished + 1 end)
	helpers.assert_eq(finished, 1, "the check finishes exactly once")
	return steps_of(report)
end

local COUNTS = "switch_cancel 0\ntoggle_open 0\ntoggle_raise 0\nexpansion 0\nboot 0\n"
local QUIET = "capture_stamp 0\nwindow_toggle 0\nstart_rollback 0\nrotation_warning 0\ndigest_mismatch 0\n"
	.. "rejections 0 none\nheld_key 0\ncancels 0 none\n" .. COUNTS





helpers.describe("field_log_signals: the day log's named lines", function()
	helpers.it("passes a quiet day and names each count", function()
		local steps = run(0, QUIET)
		helpers.assert_eq(steps.signals_log.state, Report.STATE_PASS)
		for _, signal in ipairs(Signals.ERROR_SIGNALS) do
			helpers.assert_eq(steps[signal.step].state, Report.STATE_PASS, signal.step)
			helpers.assert_eq(steps[signal.step].value, "0", signal.step)
		end
		helpers.assert_eq(steps.log_three_finger_rejections.value, "0:none")
		helpers.assert_eq(steps.log_held_key_moves.value, "0")
		helpers.assert_eq(steps.log_prediction_activity_cancels.value, "0:none")
	end)

	helpers.it("fails each error signal by name and keeps activity as information", function()
		local steps = run(0, "capture_stamp 2\nwindow_toggle 1\nstart_rollback 0\nrotation_warning 1\n"
			.. "digest_mismatch 0\nrejections 7 tilt\nheld_key 3\ncancels 4 mouseMoved\n"
			.. "switch_cancel 2\ntoggle_open 1\ntoggle_raise 3\nexpansion 9\nboot 4\n")
		helpers.assert_eq(steps.log_capture_stamp_errors.state, Report.STATE_FAIL)
		helpers.assert_eq(steps.log_capture_stamp_errors.value, "2")
		helpers.assert_eq(steps.log_window_toggle_errors.state, Report.STATE_FAIL)
		helpers.assert_eq(steps.log_start_rollbacks.state, Report.STATE_PASS)
		helpers.assert_eq(steps.log_keystats_rotation_warnings.state, Report.STATE_FAIL)
		helpers.assert_eq(steps.log_digest_mismatches.state, Report.STATE_PASS)
		helpers.assert_eq(steps.log_three_finger_rejections.state, Report.STATE_INFO)
		helpers.assert_eq(steps.log_three_finger_rejections.value, "7:tilt")
		helpers.assert_eq(steps.log_held_key_moves.value, "3")
		helpers.assert_eq(steps.log_prediction_activity_cancels.value, "4:mouseMoved")
		for id, value in pairs({ log_prediction_switch_cancels = "2", log_window_toggle_opens = "1",
			log_window_toggle_raises = "3", log_hotstring_expansions = "9", log_boot_completions = "4" }) do
			helpers.assert_eq(steps[id].state, Report.STATE_INFO, id)
			helpers.assert_eq(steps[id].value, value, id)
		end
	end)

	helpers.it("fails on a missing log, a timeout or a summary without its totals", function()
		local report = Report.new_report("log_signals")
		Signals.log_signals({ today_log_path = function() return nil end }, report, function() end)
		helpers.assert_eq(steps_of(report).signals_log.value, "no_log")
		helpers.assert_eq(run(nil, nil).signals_log.value, "timeout")
		helpers.assert_eq(run(1, QUIET).signals_log.value, "unreadable")
		helpers.assert_eq(run(0, "capture_stamp 0\n").signals_log.value, "unreadable")
		helpers.assert_nil(Signals.parse_summary(QUIET:gsub("held_key 0\n", "")), "every total is required")
	end)

	helpers.it("the awk program reads the lines the drivers write", function()
		local dir = os.tmpname()
		os.remove(dir)
		local log, program = dir .. ".log", dir .. ".awk"
		local function write(path, text)
			local handle = assert(io.open(path, "wb"))
			handle:write(text)
			handle:close()
		end
		write(program, Signals.LOG_SIGNALS_AWK)
		-- Each line is the message its module formats, in the Logger's
		-- "TS [LEVEL] [module] message" shape.
		write(log, table.concat({
			"2026-11-10 10:00:00:001 [ERROR] [gestures] Touch frame from device=1 has no capture timestamp "
				.. "(nil); gesture timing uses delivery time.",
			"2026-11-10 10:00:01:001 [DEBUG] [gestures.engine] Three-finger candidate rejected by tilt: 31.0 deg.",
			"2026-11-10 10:00:02:001 [DEBUG] [gestures.engine] Three-finger candidate rejected by tilt: 40.0 deg.",
			"2026-11-10 10:00:03:001 [DEBUG] [gestures.engine] Three-finger candidate rejected by spread: 2.0.",
			"2026-11-10 10:00:04:001 [WARNING] [adapters.synthetic_input] Synthetic text moved off a held key "
				.. "(3 byte(s)); its first character would have been lost.",
			"2026-11-10 10:00:05:001 [DEBUG] [keymap.llm_bridge] User activity (mouseMoved) — pending prediction "
				.. "cancelled.",
			"2026-11-10 10:00:06:001 [DEBUG] [keymap.llm_bridge] User activity (mouseMoved) — pending prediction "
				.. "cancelled.",
			"2026-11-10 10:00:07:001 [DEBUG] [keymap.llm_bridge] User activity (key) — pending prediction cancelled.",
			"2026-11-10 10:00:08:001 [ERROR] [window_toggle] Page 'model_browser' has no opener.",
			"2026-11-10 10:00:09:001 [ERROR] [dynamic_hotstrings.personal_info] Personal info tracker start rolled "
				.. "back after interceptor registration.",
			"2026-11-10 10:00:10:001 [ERROR] [dynamic_hotstrings.rules_engine] Personal-data registry and "
				.. "publication transaction rolled back after a refused publish.",
			"2026-11-10 10:00:11:001 [INFO] [window_toggle] Page 'changelog' opened.",
			"2026-11-10 10:00:12:001 [INFO] [gestures] Touch frame from device=1 has no capture timestamp.",
			"2026-11-10 10:00:13:001 [WARNING] [keystats.watchers] Midnight rotation stalled — will retry on next "
				.. "maintenance tick.",
			"2026-11-10 10:00:14:001 [WARNING] [keystats.log_manager] day_rollover: today.log not fully drained — "
				.. "file preserved, rotation skipped.",
			"2026-11-10 10:00:15:001 [INFO] [keystats.watchers] Midnight rotation stalled in a quoted note.",
			"2026-11-10 10:00:16:001 [WARNING] [menu_llm.ollama] The Ollama pull of granite4:350m-h failed its digest "
				.. "check; Ollama removed the layer, so it is pulled once more.",
			"2026-11-10 10:00:17:001 [INFO] [menu_llm.ollama] The Ollama pull of granite4:350m-h finished.",
			"2026-11-10 10:00:18:001 [DEBUG] [keymap.llm_bridge] User activity (application or window switch) — "
				.. "pending prediction cancelled.",
			"2026-11-10 10:00:19:001 [DEBUG] [window_toggle] Toggle 'model_browser': closed, opening.",
			"2026-11-10 10:00:20:001 [DEBUG] [window_toggle] Toggle 'model_browser': open but not focused, "
				.. "bringing to front.",
			"2026-11-10 10:00:21:001 [DEBUG] [window_toggle] Toggle 'model_browser': focused, closing.",
			"2026-11-10 10:00:22:001 [DEBUG] [keymap.expander] Auto-expand: private mapping fired (content withheld).",
			"2026-11-10 10:00:23:001 [DEBUG] [keymap.expander] Terminator-expand: 'asa' → 'ASA'.",
			"2026-11-10 10:00:24:001 [SUCCESS] [boot_profiler] Boot complete in 2140 ms.",
		}, "\n") .. "\n")
		local pipe = assert(io.popen("/usr/bin/awk -f '" .. program .. "' '" .. log .. "'"))
		local output = pipe:read("*a")
		pipe:close()
		os.remove(log)
		os.remove(program)
		local summary = assert(Signals.parse_summary(output), "the awk summary does not parse: " .. output)
		helpers.assert_eq(summary.capture_stamp, 1, "only the ERROR line counts")
		helpers.assert_eq(summary.window_toggle, 1, "only the window_toggle ERROR line counts")
		helpers.assert_eq(summary.start_rollback, 2)
		helpers.assert_eq(summary.rotation_warning, 2, "only the WARNING rotation lines count")
		helpers.assert_eq(summary.digest_mismatch, 1, "only the failed digest check counts")
		helpers.assert_eq(summary.rejections, { count = 3, top = "tilt" })
		helpers.assert_eq(summary.held_key, 1)
		helpers.assert_eq(summary.cancels, { count = 3, top = "mouseMoved" },
			"a window switch, whose reason holds spaces, is counted apart")
		helpers.assert_eq(summary.switch_cancel, 1)
		helpers.assert_eq(summary.toggle_open, 1)
		helpers.assert_eq(summary.toggle_raise, 1, "a focused toggle closes and is neither")
		helpers.assert_eq(summary.expansion, 2)
		helpers.assert_eq(summary.boot, 1)
	end)
end)
