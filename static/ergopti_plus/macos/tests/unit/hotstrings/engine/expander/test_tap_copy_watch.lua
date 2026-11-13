--- tests/unit/hotstrings/engine/expander/test_tap_copy_watch.lua

--- ==============================================================================
--- MODULE: Tap-Hold Copy Watch (macOS)
--- DESCRIPTION:
--- Replays what the keymap taps see of a Left Shift tapped for Cmd+C, on a
--- fake event clock and a fake pasteboard counter: the copy Karabiner posted
--- is attributed to the tap, checked against the counter read before the
--- application received it, sent again once when the counter did not move,
--- and the user is warned when it never did. A tap Karabiner did not take is
--- logged with its press duration against the threshold.
--- ==============================================================================

local helpers = require("tests.helpers")
local TapCopy = require("hotstrings.engine.expander.tap_copy")
local CopyCheck = require("tap_hold.engine.copy_check")

local LEFT_SHIFT, COMMAND, OPTION = 56, 55, 58

--- Builds a watch over fakes. Stamps are milliseconds, so a duration is a
--- difference; deferred work runs when the test calls w.flush().
--- @param options table|nil { tap = string, threshold_ms = number, copies = { [n] = true } }
--- @return table world
local function world(options)
	options = options or {}
	local w = { counter = 7, counter_reads = 0, sends = 0, warnings = 0, logs = {}, deferred = {}, timers = {}, now = 0,
		focus = "field-a" }
	local function log(level, fmt, ...) w.logs[#w.logs + 1] = { level = level, text = string.format(fmt, ...) } end
	local checker = CopyCheck.new({
		verify_ms = 300,
		read_counter = function() return w.counter end,
		send_copy = function()
			w.sends = w.sends + 1
			if options.copies and options.copies[w.sends] then w.counter = w.counter + 1 end
			return true
		end,
		after = function(delay_ms, callback)
			local timer = { at = w.now + delay_ms, callback = callback }
			w.timers[#w.timers + 1] = timer
			return timer
		end,
		report = CopyCheck.reporter(log, function() w.warnings = w.warnings + 1 end),
	})
	w.watch = TapCopy.new({
		change_count = function() w.counter_reads = w.counter_reads + 1; return w.counter end,
		capture_destination = function() return w.focus end,
		destination_current = function(target)
			if w.reenter then w.watch:activity() end
			return target == w.focus
		end,
		duration_ms = function(earlier, later) return later - earlier end,
		defer = function(_, fn) w.deferred[#w.deferred + 1] = fn; return true end,
		event_flags = function(event) return event.flags end,
		event_chars = function(event) return event.chars end,
		key_config = function(key_id)
			if key_id == "left_shift" then return options.tap or "copy", options.threshold_ms or 200 end
			return "none", 200
		end,
		log = log,
		checker = checker,
	})
	function w.flush()
		local queued = w.deferred
		w.deferred = {}
		for _, fn in ipairs(queued) do fn() end
	end
	function w.advance(ms)
		w.now = w.now + ms
		local pending = w.timers
		w.timers = {}
		for _, timer in ipairs(pending) do
			if timer.at <= w.now then timer.callback() else w.timers[#w.timers + 1] = timer end
		end
	end
	--- Karabiner's Left Shift: Shift down, Shift up, then for a tap its Cmd+C.
	function w.shift(down_at, up_at)
		w.watch:modifier_edge(LEFT_SHIFT, { shift = true }, down_at)
		w.watch:modifier_edge(LEFT_SHIFT, {}, up_at)
	end
	function w.cmd_c(at)
		w.watch:modifier_edge(COMMAND, { cmd = true }, at)
		w.watch:key_down({ flags = { cmd = true }, chars = "c" }, at + 1, 3)
		w.watch:modifier_edge(COMMAND, {}, at + 2)
	end
	function w.log_matching(pattern)
		for _, entry in ipairs(w.logs) do
			if entry.text:find(pattern) then return entry end
		end
		return nil
	end
	return w
end

helpers.describe("tap-hold copy watch (tap-copy-verified)", function()
	helpers.it("does not retry after focus or physical input changes (tap-copy-context)", function()
		for _, change in ipairs({
			function(w) w.focus = "field-b" end,
			function(w) w.watch:activity() end,
			function(w) w.reenter = true end,
			function(w) w.watch:key_down({ flags = {}, chars = "x" }, 95, 0) end,
		}) do
			local w = world()
			w.shift(0, 90)
			w.cmd_c(91)
			w.flush()
			change(w)
			w.advance(300)
			helpers.assert_eq(w.sends, 0)
			helpers.assert_eq(w.warnings, 0)
			helpers.assert_true(w.log_matching("original context is no longer proven") ~= nil)
		end
		local missing = world()
		missing.focus = nil
		missing.shift(0, 90)
		missing.cmd_c(91)
		missing.flush()
		missing.advance(300)
		helpers.assert_eq(missing.sends, 0)
		helpers.assert_eq(missing.warnings, 0)
	end)
	helpers.it("reads the counter before the app has the Cmd+C and verifies the copy (tap-copy-verified)", function()
		local w = world()
		w.shift(1000, 1120)
		w.cmd_c(1121)
		helpers.assert_eq(w.counter_reads, 1, "the baseline is read in the tap, at the Cmd+C key-down")
		w.counter = w.counter + 1 -- the application copies
		w.flush()
		local attributed = w.log_matching("^Tap%-hold copy: left_shift held 120 ms %(threshold 200 ms%); Cmd%+C 2 ms")
		helpers.assert_true(attributed ~= nil, "one line names the decision, the press time and the Cmd+C delay")
		helpers.assert_true(attributed.text:find("changeCount 7", 1, true) ~= nil, "the line carries the baseline")
		w.advance(300)
		helpers.assert_true(w.log_matching("verified") ~= nil)
		helpers.assert_eq(w.sends, 0)
		helpers.assert_eq(w.warnings, 0)
		local stats = w.watch:statistics()
		helpers.assert_eq(stats.sent, 1, "the field run counts the copy (tap-copy-field-check)")
		helpers.assert_eq(stats.held_ms, { 120 })
	end)

	helpers.it("sends Cmd+C again when the clipboard did not move, and says so (tap-copy-verified)", function()
		local w = world({ copies = { [1] = true } })
		w.shift(0, 90)
		w.cmd_c(91)
		w.flush()
		w.advance(300)
		helpers.assert_eq(w.sends, 1, "an unchanged counter sends the copy once more")
		w.advance(300)
		local line = w.log_matching("only when sent again")
		helpers.assert_true(line ~= nil and line.level == "warn", "a copy lost once is visible in the log")
		helpers.assert_eq(w.warnings, 0, "a copy that landed on the retry is no failure for the user")
	end)

	helpers.it("warns the user when the copy never reached the clipboard (tap-copy-verified)", function()
		local w = world()
		w.shift(0, 90)
		w.cmd_c(91)
		w.flush()
		w.advance(300)
		w.advance(300)
		helpers.assert_eq(w.sends, 1)
		helpers.assert_eq(w.warnings, 1, "the localized notice is shown once")
		local line = w.log_matching("never reached the clipboard")
		helpers.assert_true(line ~= nil and line.level == "warn")
	end)

	helpers.it("logs a tap held past the threshold, which Karabiner took as a hold (tap-copy-verified)", function()
		local w = world({ threshold_ms = 200 })
		w.shift(0, 230)
		-- Nothing followed; the next press settles the previous one.
		w.shift(2000, 2080)
		w.flush()
		local line = w.log_matching("held 230 ms %(threshold 200 ms%) sent no Cmd%+C %(held past the threshold")
		helpers.assert_true(line ~= nil, "the field log says why there was no copy")
		helpers.assert_eq(w.counter_reads, 0, "no copy, no check")
		local stats = w.watch:statistics()
		helpers.assert_eq(stats.missing_past, 1, "the field run counts it (tap-copy-field-check)")
		helpers.assert_eq(stats.missing_held_ms, { 230 })
		helpers.assert_eq(stats.sent, 0)
	end)

	helpers.it("a Shift used for a capital or a chord is no tap (tap-copy-verified)", function()
		local w = world()
		w.watch:modifier_edge(LEFT_SHIFT, { shift = true }, 0)
		w.watch:key_down({ flags = { shift = true }, chars = "a" }, 30, 0)
		w.watch:modifier_edge(LEFT_SHIFT, {}, 80)
		helpers.assert_eq(w.watch:watching(), false)
		w.watch:modifier_edge(LEFT_SHIFT, { shift = true }, 100)
		w.watch:modifier_edge(OPTION, { shift = true, alt = true }, 120)
		w.watch:modifier_edge(OPTION, { shift = true }, 130)
		w.watch:modifier_edge(LEFT_SHIFT, {}, 150)
		helpers.assert_eq(w.watch:watching(), false, "Shift+Option is a chord")
		w.watch:modifier_edge(LEFT_SHIFT, { shift = true }, 200)
		w.watch:activity()
		w.watch:modifier_edge(LEFT_SHIFT, {}, 260)
		helpers.assert_eq(w.watch:watching(), false, "a Shift+click is no tap")
		w.flush()
		helpers.assert_eq(#w.logs, 0)
	end)

	helpers.it("a Cmd+C typed by hand later is not the tap's (tap-copy-verified)", function()
		local w = world()
		w.shift(0, 100)
		w.cmd_c(700)
		w.flush()
		helpers.assert_eq(w.counter_reads, 0, "only the tap's own Cmd+C is checked")
		helpers.assert_true(w.log_matching("timing did not match") ~= nil)
	end)

	helpers.it("does not attribute a copy stamped before the release (tap-copy-reversed-stamps)", function()
		local w = world()
		w.shift(0, 100)
		w.cmd_c(80)
		w.flush()
		helpers.assert_eq(w.counter_reads, 0, "a copy before the release cannot belong to the tap")
		helpers.assert_true(w.log_matching("timing did not match") ~= nil)
	end)

	helpers.it("does not restart a deferred copy check after stop (tap-copy-stop-fence)", function()
		local w = world()
		w.shift(0, 90)
		w.cmd_c(91)
		w.watch:stop()
		w.flush()
		w.advance(300)
		helpers.assert_eq(w.sends, 0, "a stopped watch must not send a late retry")
		helpers.assert_eq(w.watch:statistics().sent, 0)
	end)

	helpers.it("does not attribute a copy after an intervening click or modifier (tap-copy-intervening-input)", function()
		for _, interrupt in ipairs({
			function(w) w.watch:activity() end,
			function(w) w.watch:modifier_edge(57, { capslock = true }, 92) end,
		}) do
			local w = world()
			w.shift(0, 90)
			interrupt(w)
			w.cmd_c(93)
			w.flush()
			helpers.assert_eq(w.counter_reads, 0, "intervening input breaks attribution")
			helpers.assert_eq(w.watch:statistics().sent, 0)
		end
	end)

	helpers.it("a key whose tap is not copy is never logged or checked (tap-copy-verified)", function()
		local w = world({ tap = "none" })
		w.shift(0, 100)
		w.cmd_c(101)
		w.flush()
		helpers.assert_eq(#w.logs, 0)
		w.advance(1000)
		helpers.assert_eq(w.sends, 0)
	end)
end)
