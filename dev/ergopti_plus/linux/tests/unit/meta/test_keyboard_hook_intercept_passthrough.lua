--- tests/unit/meta/test_keyboard_hook_intercept_passthrough.lua

--- ==============================================================================
--- MODULE: Intercept-Mode Raw Pass-Through Harness (Linux)
--- DESCRIPTION:
--- Deterministic harness for the one thing that makes EVIOCGRAB survivable: when
--- the daemon grabs the keyboard, it becomes the only path to the application and
--- must put every consumed event back, in order and without loss.
---
--- ROOT CAUSE ENCODED:
--- The daemon used to run in observe mode, so physical keys reached the
--- application while an expansion was erasing and retyping — the "abcd"→"acd"
--- corruption. The cure is to grab, and the reason grabbing was never viable is
--- that the pump forwarded nothing at all: it early-returned on releases,
--- swallowed modifiers and control keys, and its semantic parser dropped the
--- autorepeat value and any KEY_* name containing a second underscore. Grabbing
--- on top of that would have made normal typing vanish.
---
--- HOW THIS TEST IS GENUINE (not a delivery-only tautology):
--- The events are encoded into real struct input_event bytes and fed through the
--- REAL reader over a recorded syscall backend, so the assertion is on the exact
--- ordered sequence of (code, value) pairs that reach the uinput channel — every
--- case in it is a class the old code lost. It is RED before the pass-through
--- exists (nothing is emitted at all), and section 3 closes the loop on the real
--- injector so the recorder cannot drift away from what is actually written.
--- ==============================================================================

local helpers = require("tests.helpers")

local EV_KEY = 1
local EV_MSC = 4
local EV_SYN = 0

--- One kernel event, as the reader will decode it.
--- @param ev_type integer
--- @param code integer
--- @param value integer
--- @return table
local function ev(ev_type, code, value)
	return { type = ev_type, code = code, value = value }
end

-- A mixed stream, deliberately: a held modifier, a press/repeat/release triad, a
-- control key, a keycode above 255 that the old name pattern could not match,
-- and the two non-EV_KEY reports that must NOT be forwarded.
local GRABBED_STREAM = {
	ev(EV_KEY, 42, 1),    -- KEY_LEFTSHIFT down
	ev(EV_MSC, 4, 458756),-- MSC_SCAN, duplicate metadata
	ev(EV_KEY, 30, 1),    -- KEY_A press
	ev(EV_KEY, 30, 2),    -- KEY_A autorepeat
	ev(EV_KEY, 30, 0),    -- KEY_A release
	ev(EV_KEY, 42, 0),    -- KEY_LEFTSHIFT up
	ev(EV_KEY, 28, 1),    -- KEY_ENTER
	ev(EV_KEY, 243, 1),   -- KEY_BRIGHTNESS_CYCLE
	ev(EV_SYN, 0, 0),     -- SYN_REPORT
}

-- The same device read without a grab: the kernel already delivered each event
-- to the application.
local OBSERVED_STREAM = {
	ev(EV_KEY, 30, 1),
	ev(EV_KEY, 30, 0),
	ev(EV_KEY, 28, 1),
}

--- Drives a scripted event stream through a freshly loaded hook.
--- @param events    table   Decoded events in arrival order.
--- @param intercept boolean Whether the device was grabbed.
--- @return table emitted Ordered "code:value" strings sent to the uinput channel.
--- @return table chars   Characters delivered to on_char.
--- @return table keys    Control-key names delivered to on_key.
local function drive(events, intercept)
	local kh      = helpers.load_module("adapters.keyboard_hook")
	local emitted = {}
	local chars   = {}
	local keys    = {}

	kh._test_drive(events, {
		onChar     = function(ch) chars[#chars + 1] = ch end,
		onKey      = function(name) keys[#keys + 1] = name end,
		onEmitRaw  = function(code, value)
			emitted[#emitted + 1] = string.format("%d:%d", code, value)
		end,
	}, intercept)

	return emitted, chars, keys
end





-- =========================================
-- =========================================
-- ======= 1/ Raw Event Pass-Through =======
-- =========================================
-- =========================================

helpers.describe("keyboard_hook: intercept mode re-emits every consumed event", function()

	helpers.it("forwards modifiers, autorepeat and releases in arrival order", function()
		local emitted = drive(GRABBED_STREAM, true)
		-- Every class the pre-fix pump destroyed, in one sequence: the modifier
		-- down/up pair, the autorepeat (value 2, which the semantic parser mapped
		-- to nil and dropped), the release, and KEY_BRIGHTNESS_CYCLE whose second
		-- underscore the name pattern could not match. Under a grab, each one of
		-- these is a keystroke the user made and the application never sees.
		helpers.assert_eq(
			table.concat(emitted, " "),
			"42:1 30:1 30:2 30:0 42:0 28:1 243:1",
			"the grabbed stream must be re-emitted losslessly and in order"
		)
	end)

	helpers.it("forwards only EV_KEY reports", function()
		local emitted = drive(GRABBED_STREAM, true)
		-- MSC_SCAN (type 4) is duplicate scancode metadata and SYN_REPORT is the
		-- frame terminator the uinput channel writes itself after every key.
		-- Replaying either would put a second, contradictory report on the wire
		-- for the same keystroke.
		for _, pair in ipairs(emitted) do
			helpers.assert_true(pair ~= "4:458756",
				"MSC_SCAN must not be replayed as a key event")
		end
		helpers.assert_eq(#emitted, 7, "exactly the seven EV_KEY reports are forwarded")
	end)

	helpers.it("still dispatches the domain callbacks it forwards", function()
		local _, chars, keys = drive(GRABBED_STREAM, true)
		-- Pass-through runs before the semantic dispatch, so it must not consume
		-- anything: the hotstring engine still has to see the typed character.
		--
		-- TWO characters, not one. The autorepeat is re-emitted, so the
		-- application inserts a second "A" — and a buffer that counted one while
		-- the screen showed two would erase the wrong number of characters on the
		-- next expansion. Ignoring value 2 here was a divergence the grab turned
		-- into corruption.
		helpers.assert_eq(chars, { "A", "A" },
			"the press and the autorepeat each produce a character, because each one "
				.. "produces a character in the application; the release does not")
		helpers.assert_eq(keys, { "enter" }, "the control key must still reach on_key")
	end)

	helpers.it("counts a held key as one physical press", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local physical = {}
		kh._test_drive({ ev(EV_KEY, 30, 1), ev(EV_KEY, 30, 2), ev(EV_KEY, 30, 2) }, {
			onPhysical = function(code) physical[#physical + 1] = code end,
			onEmitRaw  = function() end,
		}, true)
		-- The opposite rule to on_char above, and deliberately so: the heatmap
		-- measures keys the user pressed, and a held key is one press however long
		-- it is held. Counting repeats would make a stuck key the most-used key on
		-- the board.
		helpers.assert_eq(#physical, 1,
			"autorepeat produces characters but not keystrokes; got " .. #physical)
	end)

	helpers.it("emits nothing in observe mode", function()
		local emitted, chars = drive(OBSERVED_STREAM, false)
		-- Without a grab the kernel never took the event away, so re-emitting it
		-- would type every keystroke twice. This is the assertion that keeps the
		-- forward inside the intercept branch.
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

	--- Reads the daemon entry point's source once for the wiring assertions below.
	--- @return string The file contents.
	local function daemon_source()
		local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local src = fh:read("*a")
		fh:close()
		return src
	end

	helpers.it("the daemon supplies the channel the grab needs", function()
		-- Without onEmitRaw, can_capture refuses at start() and the daemon exits.
		-- Pins the wiring, not the spelling of a flag.
		helpers.assert_true(daemon_source():find("onEmitRaw", 1, true) ~= nil,
			"ergopti_hotstrings.lua must pass onEmitRaw to keyboard_hook.start")
	end)

	helpers.it("the daemon opens the non-forking channel, and opens it before grabbing", function()
		-- The grab was enabled on the strength of a comment claiming re-emission no
		-- longer forks. It did fork: open_fast_channel() had no caller outside its
		-- own test, so `_uinput` was always nil and emit_key fell through to
		-- `ydotool key` — one subprocess per physical keystroke, under a grab that
		-- was already on by default. The justification for the default was true of
		-- the code that existed and false of the code that ran.
		--
		-- Order is the assertion, not presence. Between taking the grab and opening
		-- the channel the daemon owns the keyboard and can only hand keys back one
		-- fork at a time, which is precisely the state the grab was held back for.
		local src = daemon_source()
		local open_at  = src:find("injector%.open_fast_channel%(%)")
		local start_at = src:find("keyboard_hook%.start%(")
		helpers.assert_true(open_at ~= nil,
			"the daemon must call injector.open_fast_channel() — without it the FFI "
				.. "uinput writer is unreachable and every re-emit is a subprocess")
		helpers.assert_true(start_at ~= nil, "and it must still start the keyboard hook")
		helpers.assert_true(open_at < start_at,
			"open_fast_channel() must come BEFORE keyboard_hook.start(): opening after "
				.. "the grab leaves a window in which the daemon owns the keyboard and "
				.. "forks once per key to give it back")
	end)

	helpers.it("the daemon closes the channel on both exit paths", function()
		-- UI_DEV_DESTROY never ran either: close_fast_channel() had no caller. A
		-- daemon killed with SIGTERM left its uinput device behind, and the next
		-- start enumerated two of them.
		local src = daemon_source()
		local closes = 0
		for _ in src:gmatch("injector%.close_fast_channel%(%)") do closes = closes + 1 end
		helpers.assert_true(closes >= 2,
			"close_fast_channel() must run on the signal path AND on the normal exit "
				.. "path; a daemon that only tidies up when asked politely leaks the "
				.. "device on every SIGTERM, and found " .. closes .. " call site(s)")
	end)

	helpers.it("the daemon grabs the device by default", function()
		-- THE regression this whole item exists for. Observe mode lets physical
		-- keystrokes reach the application while an expansion is being typed, so
		-- the user's next keys interleave with the synthetic backspaces and the
		-- text is scrambled non-deterministically — "abcd" becoming "acd". The
		-- daemon shipped in observe mode for its whole life because `intercept`
		-- was simply never passed, and nothing said so: an absent option reads as
		-- a default, not as a bug.
		local src = daemon_source()
		helpers.assert_true(src:find("intercept%s*=%s*opts%.grab") ~= nil,
			"keyboard_hook.start must be given intercept = opts.grab — a daemon that "
				.. "omits the option silently reverts to the corrupting observe mode")
		helpers.assert_true(src:find("grab%s*=%s*true") ~= nil,
			"opts.grab must DEFAULT to true; --no-grab is the escape hatch, and a "
				.. "default of false makes the escape hatch the norm again")
	end)

	helpers.it("--no-grab still exists as the way out", function()
		-- The grab has never run on real hardware. The two daemons now agree on
		-- which device is whose, but agreement in the config is not the same as
		-- agreement on a machine we have never booted, so there has to be a way
		-- back that does not need a rebuild.
		local src = daemon_source()
		helpers.assert_true(src:find('"%-%-no%-grab"') ~= nil,
			"the --no-grab flag must remain parseable — it is the only recovery path "
				.. "if the grab picks the wrong device")
	end)

end)





-- =========================================
-- =========================================
-- ======= 3/ Injector Emit Contract =======
-- =========================================
-- =========================================

helpers.describe("injector: emit_key puts a raw event back on the wire", function()

	--- Records what the uinput channel is asked to emit.
	--- @return table channel, table emitted
	local function recorder()
		local emitted = {}
		return {
			is_open = function() return true end,
			emit = function(code, value)
				emitted[#emitted + 1] = string.format("%d:%d", code, value)
				return true
			end,
		}, emitted
	end

	helpers.it("hands the channel the keycode and direction unchanged", function()
		local injector = helpers.load_module("modules.hotstrings.injector")
		local channel, emitted = recorder()
		injector._set_uinput(channel)
		injector.emit_key(30, 1)
		injector.emit_key(30, 0)
		injector._set_uinput(nil)
		helpers.assert_eq(emitted, { "30:1", "30:0" },
			"a forwarded event must reach the wire as its own keycode and direction")
	end)

	helpers.it("re-emits an autorepeat as an autorepeat", function()
		local injector = helpers.load_module("modules.hotstrings.injector")
		local channel, emitted = recorder()
		injector._set_uinput(channel)
		injector.emit_key(30, 2)
		injector._set_uinput(nil)
		-- uinput carries value 2 natively. Collapsing it into a press was a
		-- ydotool limitation, and a pass-through that rewrites what it passes is
		-- not a pass-through.
		helpers.assert_eq(emitted, { "30:2" },
			"evdev value 2 must be forwarded as itself, never rewritten or dropped")
	end)

	helpers.it("emits nothing for a non-numeric event", function()
		local injector = helpers.load_module("modules.hotstrings.injector")
		local channel, emitted = recorder()
		injector._set_uinput(channel)
		injector.emit_key("30", nil)
		injector._set_uinput(nil)
		helpers.assert_eq(#emitted, 0,
			"a malformed event must be rejected before it reaches the device")
	end)

end)
