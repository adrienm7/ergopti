--- diagnostics/engine/field_check/log_signals.lua

--- ==============================================================================
--- MODULE: Field Check, Named Log Signals
--- DESCRIPTION:
--- The field run's count of the day-log lines several Mac checks are read from
--- (TODO, To confirm on the Mac): the gesture timing error a reload must not
--- bring back (L46), the window toggles that must log no error, the starts a
--- hotstring reload rolled back, a keystats day rotation that stalled, a model
--- blob whose digest did not match, the three-finger candidates a gate rejected,
--- the synthetic text moved off a held key (`asa` typed fast) and the pending
--- predictions a user activity cancelled (a window switch counted apart), the
--- window toggles that opened or raised a page, the hotstring expansions and
--- the completed boots of the day, and the API entries restored without their
--- key and given one again. A person reading the report then
--- knows which of those happened today without opening the log.
---
--- FEATURES & RATIONALE:
--- 1. One POSIX awk pass over today's log prints counts and enumerated names
---    only (a gate, an activity kind): no logged text reaches the report, and a
---    task's output is read when it exits, so the lines never reach the pipe.
--- 2. An error signal fails its step by name when it appeared at all; an
---    activity signal is information, with its most frequent name.
--- 3. The activity lines are DEBUG lines: the field run asks for Debug > Log
---    level > DEBUG, and a count of 0 at a higher level says nothing.
--- ==============================================================================

local Report = require("diagnostics.engine.field_check.report")

local M = {}

local PASS, FAIL, INFO = Report.STATE_PASS, Report.STATE_FAIL, Report.STATE_INFO

local AWK = "/usr/bin/awk"
-- One pass over one day log.
local TOOL_SECONDS = 10





-- ==============================
-- ==============================
-- ======= 1/ The signals =======
-- ==============================
-- ==============================

--- The error signals, each failing its step when the day log holds one. The
--- patterns are the canonical Logger lines "TS [LEVEL] [module] message".
--- @type table { { step, name } } in report order
M.ERROR_SIGNALS = {
	-- modules/gestures/init.lua: a touch frame without the trackpad's stamp.
	{ step = "log_capture_stamp_errors", name = "capture_stamp" },
	-- core/ui/ui/window_toggle.lua: a window-toggle action that could not act.
	{ step = "log_window_toggle_errors", name = "window_toggle" },
	-- modules/dynamic_hotstrings: a personal or dynamic start rolled back.
	{ step = "log_start_rollbacks", name = "start_rollback" },
	-- modules/keystats: a day rollover that skipped or stalled its rotation.
	{ step = "log_keystats_rotation_warnings", name = "rotation_warning" },
	-- ai/ui/menu/models/manager_ollama.lua: a pull that failed its digest check.
	{ step = "log_digest_mismatches", name = "digest_mismatch" },
}

--- The activity counts, each information the guided steps watch rise
--- (diagnostics/engine/field_run/guided.lua) and the TODO summary bounds.
--- @type table { { step, name } } in report order
M.COUNT_SIGNALS = {
	-- ai/engine/bridge.lua: a prediction a window or application switch
	-- cancelled; its reason holds spaces, which the generic count refuses.
	{ step = "log_prediction_switch_cancels", name = "switch_cancel" },
	-- core/ui/ui/window_toggle.lua: a toggle that opened its page, or raised a covered or
	-- minimised one.
	{ step = "log_window_toggle_opens", name = "toggle_open" },
	{ step = "log_window_toggle_raises", name = "toggle_raise" },
	-- modules/keymap/expander.lua: an auto or terminator expansion (DEBUG).
	{ step = "log_hotstring_expansions", name = "expansion" },
	-- core/logger/engine/boot_profiler.lua: one completed boot.
	{ step = "log_boot_completions", name = "boot" },
	-- ai/engine: an API entry restored without its Keychain key, then given one.
	{ step = "log_api_key_absent", name = "api_key_absent" },
	{ step = "log_api_key_reentered", name = "api_key_reentered" },
	-- modules/gestures/engine.lua: a three-finger swipe slot that dispatched its action.
	{ step = "log_gesture_swipe_dispatches", name = "swipe_dispatch" },
	-- menu/ui/init.lua and the shared global composition: a committed restore or clear.
	{ step = "log_scope_commits", name = "scope_commit" },
	-- modules/keymap/init.lua: Karabiner's tap-hold command marker that reset the word.
	{ step = "log_tap_hold_word_resets", name = "tap_hold_reset" },
	-- modules/keymap/layout_emulation.lua: an emulated layout turned on.
	{ step = "log_layout_emulations_on", name = "emulation_on" },
	-- modules/keymap/number_row_live.lua: number-row options applied live.
	{ step = "log_number_row_applies", name = "number_row_apply" },
	-- core/ui/ui/builder.lua: a page's first load, per system appearance.
	{ step = "log_pages_dark", name = "page_dark" },
	{ step = "log_pages_light", name = "page_light" },
}

-- POSIX awk only: macOS ships the BWK awk.
M.LOG_SIGNALS_AWK = [=[
function top(names,   name, best, best_n) {
	best = "none"; best_n = 0
	for (name in names) if (names[name] > best_n) { best_n = names[name]; best = name }
	return best
}
/\[ERROR\] \[gestures\] Touch frame from device=.* has no capture timestamp/ { capture_stamp++ }
/\[ERROR\] \[window_toggle\] / { window_toggle++ }
/\[ERROR\] \[[^]]*\] .*(start rolled back after|publication transaction rolled back)/ { start_rollback++ }
/\[WARNING\] \[[^]]*\] (Midnight rotation stalled|day_rollover: today\.log not fully drained)/ { rotation_warning++ }
/\[(ERROR|WARNING)\] \[[^]]*\] .*(failed its digest check|digest_mismatch)/ { digest_mismatch++ }
/User activity \(application or window switch\) — pending prediction cancelled/ { switch_cancel++ }
/Toggle '[^']*': closed, opening\./ { toggle_open++ }
/Toggle '[^']*': open but not focused, bringing to front\./ { toggle_raise++ }
/\] (Auto|Terminator)-expand: / { expansion++ }
/\] Boot complete in [0-9]+ ms\./ { boot++ }
/\[WARNING\] \[[^]]*\] Keychain holds no key for entry '[^']*'; it needs its key again\./ { api_key_absent++ }
/\] API entry key change staged \(entry=/ { api_key_reentered++ }
/\] Gesture dispatched: slot=swipe_3/ { swipe_dispatch++ }
/\] Scope [A-Za-z_.]+ (recommended|clear) committed/ { scope_commit++ }
/\] Tap-hold command marker received \(word reset: yes\)/ { tap_hold_reset++ }
/\] Layout emulation of '[^']*' on \(/ { emulation_on++ }
/\] Number-row options applied live / { number_row_apply++ }
/\] Webview '[^']*' rendered in the dark appearance/ { page_dark++ }
/\] Webview '[^']*' rendered in the light appearance/ { page_light++ }
match($0, /Three-finger candidate rejected by [A-Za-z_][A-Za-z0-9_]*/) {
	rejections++; gate[substr($0, RSTART + 35, RLENGTH - 35)]++
}
/Synthetic text moved off a held key/ { held_key++ }
match($0, /User activity \([A-Za-z_][A-Za-z0-9_]*\)/) {
	cancels++; reason[substr($0, RSTART + 15, RLENGTH - 16)]++
}
END {
	printf "capture_stamp %d\nwindow_toggle %d\nstart_rollback %d\n", capture_stamp, window_toggle, start_rollback
	printf "rotation_warning %d\ndigest_mismatch %d\n", rotation_warning, digest_mismatch
	printf "switch_cancel %d\ntoggle_open %d\ntoggle_raise %d\n", switch_cancel, toggle_open, toggle_raise
	printf "expansion %d\nboot %d\n", expansion, boot
	printf "api_key_absent %d\napi_key_reentered %d\n", api_key_absent, api_key_reentered
	printf "swipe_dispatch %d\nscope_commit %d\ntap_hold_reset %d\n", swipe_dispatch, scope_commit, tap_hold_reset
	printf "emulation_on %d\nnumber_row_apply %d\n", emulation_on, number_row_apply
	printf "page_dark %d\npage_light %d\n", page_dark, page_light
	printf "rejections %d %s\nheld_key %d\ncancels %d %s\n", rejections, top(gate), held_key, cancels, top(reason)
}
]=]

--- Reads the awk summary.
--- @param text any
--- @return table|nil summary { capture_stamp, window_toggle, start_rollback, held_key = number,
---   rejections = { count, top }, cancels = { count, top } }, nil when a line is missing
function M.parse_summary(text)
	local summary = {}
	for line in tostring(text or ""):gmatch("[^\n]+") do
		local name, count = line:match("^([%a_]+) (%d+)$")
		if name then summary[name] = tonumber(count) end
		local named, named_count, top = line:match("^([%a_]+) (%d+) ([%w_]+)$")
		if named then summary[named] = { count = tonumber(named_count), top = top } end
	end
	for _, list in ipairs({ M.ERROR_SIGNALS, M.COUNT_SIGNALS }) do
		for _, signal in ipairs(list) do
			if type(summary[signal.name]) ~= "number" then return nil end
		end
	end
	if type(summary.held_key) ~= "number" or type(summary.rejections) ~= "table"
		or type(summary.cancels) ~= "table" then
		return nil
	end
	return summary
end





-- ============================
-- ============================
-- ======= 2/ The check =======
-- ============================
-- ============================

--- Runs the check.
--- ports.today_log_path(), exec.
--- @param ports table
--- @param report table field_check_report report.
--- @param finish function
function M.log_signals(ports, report, finish)
	local path = ports.today_log_path()
	if type(path) ~= "string" or path == "" then
		report.step("signals_log", FAIL, "no_log")
		return finish()
	end
	ports.exec(AWK, { M.LOG_SIGNALS_AWK, path }, TOOL_SECONDS, function(code, output)
		local summary = code == 0 and M.parse_summary(output) or nil
		if summary == nil then
			report.step("signals_log", FAIL, code == nil and "timeout" or "unreadable")
			return finish()
		end
		report.step("signals_log", PASS)
		for _, signal in ipairs(M.ERROR_SIGNALS) do
			local count = summary[signal.name]
			report.step(signal.step, count == 0 and PASS or FAIL, count)
		end
		report.step("log_three_finger_rejections", INFO,
			summary.rejections.count .. ":" .. summary.rejections.top)
		report.step("log_held_key_moves", INFO, summary.held_key)
		report.step("log_prediction_activity_cancels", INFO, summary.cancels.count .. ":" .. summary.cancels.top)
		for _, signal in ipairs(M.COUNT_SIGNALS) do report.step(signal.step, INFO, summary[signal.name]) end
		finish()
	end)
end

return M
