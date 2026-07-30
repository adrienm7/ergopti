--- tests/unit/meta/test_keyboard_hook_intercept_passthrough.lua

--- ==============================================================================
--- MODULE: Intercept-Mode Raw Pass-Through Harness (Linux)
--- DESCRIPTION:
--- Deterministic harness for the one thing that makes EVIOCGRAB survivable: when
--- the daemon grabs the keyboard, it becomes the only path to the application and
--- must put every consumed event back, in order and without loss.
---
--- ROOT CAUSE ENCODED:
--- The daemon runs in observe mode, so physical keys reach the application while
--- an expansion is erasing and retyping — the "abcd"→"acd" corruption. The cure
--- is to grab, and the reason grabbing was never viable is that _pump_one()
--- forwarded nothing at all: it early-returned on releases, swallowed modifiers
--- and control keys, and its semantic parser drops the autorepeat value and any
--- KEY_* name containing a second underscore. Grabbing on top of that would have
--- made normal typing vanish.
---
--- HOW THIS TEST IS GENUINE (not a delivery-only tautology):
--- The evdev source is a scripted list of real evtest lines and the injector is
--- replaced by a recorder, so the assertion is on the exact ordered sequence of
--- (code, value) pairs that reach the uinput channel — every case in it is a
--- class the old code lost. It is RED before the pass-through exists (nothing is
--- emitted at all), and section 3 closes the loop by driving the REAL injector so
--- the recorder cannot drift away from the command actually run.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Real evtest output, in the exact shape the daemon reads from `evtest --grab`.
-- The mixed stream is deliberate: a held modifier, a press/repeat/release triad,
-- a control key, a key whose name the semantic parser cannot resolve, and the
-- two non-EV_KEY reports that must NOT be forwarded.
local EVTEST_STREAM = {
	"Event: time 1700000000.100001, type 1 (EV_KEY), code 42 (KEY_LEFTSHIFT), value 1",
	"Event: time 1700000000.100002, type 4 (EV_MSC), code 4 (MSC_SCAN), value 458756",
	"Event: time 1700000000.100003, type 1 (EV_KEY), code 30 (KEY_A), value 1",
	"Event: time 1700000000.200000, type 1 (EV_KEY), code 30 (KEY_A), value 2",
	"Event: time 1700000000.300000, type 1 (EV_KEY), code 30 (KEY_A), value 0",
	"Event: time 1700000000.300001, type 1 (EV_KEY), code 42 (KEY_LEFTSHIFT), value 0",
	"Event: time 1700000000.400000, type 1 (EV_KEY), code 28 (KEY_ENTER), value 1",
	"Event: time 1700000000.500000, type 1 (EV_KEY), code 243 (KEY_BRIGHTNESS_CYCLE), value 1",
	"Event: time 1700000000.500001, -------------- SYN_REPORT ------------",
}

-- libinput debug-events output — the observe-mode format, where the kernel has
-- already delivered the event to the application.
local LIBINPUT_STREAM = {
	"event3  KEYBOARD_KEY  +1.234s  KEY_A (30) pressed",
	"event3  KEYBOARD_KEY  +1.456s  KEY_A (30) released",
	"event3  KEYBOARD_KEY  +1.678s  KEY_ENTER (28) pressed",
}

--- Drives a scripted evdev stream through a freshly loaded hook.
--- @param lines     table   Event lines in arrival order.
--- @param intercept boolean Whether the device was grabbed.
--- @return table emitted Ordered "code:value" strings sent to the uinput channel.
--- @return table chars   Characters delivered to on_char.
--- @return table keys    Control-key names delivered to on_key.
local function drive(lines, intercept)
	local kh      = helpers.load_module("adapters.keyboard_hook")
	local emitted = {}
	local chars   = {}
	local keys    = {}
	local idx     = 0
	local pipe    = { read = function() idx = idx + 1; return lines[idx] end }

	local function record_raw(code, value)
		emitted[#emitted + 1] = string.format("%d:%d", code, value)
	end

	for _ = 1, #lines do
		kh._test_inject_and_pump(
			pipe,
			function(ch) chars[#chars + 1] = ch end,
			intercept,
			nil,
			record_raw,
			function(name) keys[#keys + 1] = name end
		)
	end
	return emitted, chars, keys
end





-- =========================================
-- =========================================
-- ======= 1/ Raw Event Pass-Through =======
-- =========================================
-- =========================================

helpers.describe("keyboard_hook: intercept mode re-emits every consumed event", function()

	helpers.it("forwards modifiers, autorepeat and releases in arrival order", function()
		local emitted = drive(EVTEST_STREAM, true)
		-- Every class the pre-fix pump destroyed, in one sequence: the modifier
		-- down/up pair, the autorepeat (value 2, which the semantic parser maps to
		-- nil and drops), the release, and KEY_BRIGHTNESS_CYCLE whose second
		-- underscore the name pattern cannot match. Under a grab, each one of
		-- these is a keystroke the user made and the application never sees.
		helpers.assert_eq(
			table.concat(emitted, " "),
			"42:1 30:1 30:2 30:0 42:0 28:1 243:1",
			"the grabbed stream must be re-emitted losslessly and in order"
		)
	end)

	helpers.it("forwards only EV_KEY reports", function()
		local emitted = drive(EVTEST_STREAM, true)
		-- MSC_SCAN (type 4) is duplicate scancode metadata and SYN_REPORT is the
		-- frame terminator ydotool writes itself. Replaying either would put a
		-- second, contradictory report on the wire for the same keystroke.
		for _, pair in ipairs(emitted) do
			helpers.assert_true(pair ~= "4:458756",
				"MSC_SCAN must not be replayed as a key event")
		end
		helpers.assert_eq(#emitted, 7, "exactly the seven EV_KEY reports are forwarded")
	end)

	helpers.it("still dispatches the domain callbacks it forwards", function()
		local _, chars, keys = drive(EVTEST_STREAM, true)
		-- Pass-through runs before the semantic dispatch, so it must not consume
		-- anything: the hotstring engine still has to see the typed character.
		helpers.assert_eq(chars, { "A" },
			"the shifted letter must still reach on_char exactly once (the repeat and the release are not new characters)")
		helpers.assert_eq(keys, { "enter" }, "the control key must still reach on_key")
	end)

	helpers.it("emits nothing in observe mode", function()
		local emitted, chars = drive(LIBINPUT_STREAM, false)
		-- libinput never took the event away, so re-emitting it would type every
		-- keystroke twice. This is the assertion that keeps the forward inside the
		-- intercept branch.
		helpers.assert_eq(#emitted, 0,
			"observe mode must not re-emit — the application already received the event")
		helpers.assert_eq(chars, { "a" }, "observe-mode dispatch is unaffected")
	end)

end)





-- ================================
-- ================================
-- ======= 2/ Capture Guard =======
-- ================================
-- ================================

helpers.describe("keyboard_hook: refuses to grab without a way back", function()

	helpers.it("rejects intercept mode when no re-emit channel is supplied", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local ok, reason = kh.can_capture(true, nil)
		-- EVIOCGRAB is not reversible from the application's side: start with no
		-- emitter and the user's keyboard simply stops working.
		helpers.assert_eq(ok, false, "a grab with no pass-through channel must be refused")
		helpers.assert_type(reason, "string", "the refusal must say why")
	end)

	helpers.it("rejects a non-function re-emit channel", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		helpers.assert_eq(kh.can_capture(true, "ydotool"), false,
			"a truthy non-callable must not satisfy the guard")
	end)

	helpers.it("accepts intercept mode with a re-emit channel", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		helpers.assert_eq(kh.can_capture(true, function() end), true,
			"the guard must not block a correctly wired grab")
	end)

	helpers.it("never blocks observe mode", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		helpers.assert_eq(kh.can_capture(false, nil), true,
			"observe mode consumes nothing, so it needs no emitter")
	end)

	helpers.it("the daemon supplies the channel it would need to grab", function()
		-- The flip to intercept must stay a one-word change. If the daemon ever
		-- stops wiring onEmitRaw, can_capture would refuse at start() and the
		-- daemon would exit — so this pins the wiring, not the spelling of a flag.
		local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local src = fh:read("*a"); fh:close()
		helpers.assert_true(src:find("onEmitRaw", 1, true) ~= nil,
			"ergopti_hotstrings.lua must pass onEmitRaw to keyboard_hook.start")
	end)

end)





-- =========================================
-- =========================================
-- ======= 3/ Injector Emit Contract =======
-- =========================================
-- =========================================

helpers.describe("injector: emit_key puts a raw event back on the wire", function()

	--- Captures the commands the real injector would run.
	--- @param fn function Body executed with the capturing runner installed.
	--- @return table Commands in emission order.
	local function capture(fn)
		local injector = helpers.load_module("modules.hotstrings.injector")
		local cmds = {}
		injector._set_runner(function(cmd)
			cmds[#cmds + 1] = cmd
			return true
		end)
		local ok, err = pcall(fn, injector)
		injector._reset_runner()
		if not ok then error(err, 0) end
		return cmds
	end

	helpers.it("emits a press and a release with the ydotool code:value form", function()
		local cmds = capture(function(injector)
			injector.emit_key(30, 1)
			injector.emit_key(30, 0)
		end)
		helpers.assert_eq(cmds, { "ydotool key 30:1", "ydotool key 30:0" },
			"a forwarded event must reach ydotool as its own keycode and direction")
	end)

	helpers.it("re-emits an autorepeat as a press", function()
		local cmds = capture(function(injector) injector.emit_key(30, 2) end)
		-- ydotool's wire format has no repeat encoding. Dropping the event instead
		-- would make a held key stop repeating the moment the daemon grabs it.
		helpers.assert_eq(cmds, { "ydotool key 30:1" },
			"evdev value 2 must be forwarded as a press, never dropped")
	end)

	helpers.it("emits nothing for a non-numeric event", function()
		local cmds = capture(function(injector) injector.emit_key("30", nil) end)
		helpers.assert_eq(#cmds, 0,
			"a malformed event must be rejected before it reaches the shell")
	end)

end)
