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
			return true
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
	helpers.it("emergency-ungrabs immediately when pass-through returns false", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local emitted, chars = 0, 0
		local drained = kh._test_drive({
			ev(EV_KEY, 30, 1),
			ev(EV_KEY, 48, 1),
		}, {
			onEmitRaw = function()
				emitted = emitted + 1
				return false
			end,
			onChar = function() chars = chars + 1 end,
		}, true)

		helpers.assert_eq(emitted, 1,
			"the first failed event must close the descriptor before another is drained")
		helpers.assert_eq(drained, 1, "the unread second event remains for the ungrabbed desktop")
		helpers.assert_eq(chars, 0, "logical callbacks cannot commit an undelivered physical event")
		helpers.assert_true(not kh.isRunning(), "emergency stop must release capture ownership")
	end)

	helpers.it("emergency-ungrabs immediately when pass-through raises", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local emitted, chars = 0, 0
		local drained = kh._test_drive({
			ev(EV_KEY, 30, 1),
			ev(EV_KEY, 48, 1),
		}, {
			onEmitRaw = function()
				emitted = emitted + 1
				error("uinput exception")
			end,
			onChar = function() chars = chars + 1 end,
		}, true)

		helpers.assert_eq(emitted, 1,
			"the first exception must close the descriptor before another event is drained")
		helpers.assert_eq(drained, 1, "the unread second event remains for the ungrabbed desktop")
		helpers.assert_eq(chars, 0, "logical callbacks cannot commit after an output exception")
		helpers.assert_true(not kh.isRunning(), "exception cleanup must release capture ownership")
	end)

	helpers.it("emergency-ungrabs when a domain callback raises", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local callbacks = 0
		local drained = kh._test_drive({
			ev(EV_KEY, 30, 1),
			ev(EV_KEY, 48, 1),
		}, {
			onEmitRaw = function() return true end,
			onChar = function()
				callbacks = callbacks + 1
				error("domain callback exception")
			end,
		}, true)

		helpers.assert_eq(callbacks, 1,
			"a failed domain consumer must not receive another captured event")
		helpers.assert_eq(drained, 1,
			"closing the grabbed descriptor leaves later input to the desktop")
		helpers.assert_true(not kh.isRunning(),
			"callback failure must release capture ownership")
	end)


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
		helpers.assert_eq(chars, { "A", "A", "\n" },
			"the press and the autorepeat each produce a character, because each one "
				.. "produces a character in the application; bare Enter is a textual "
				.. "terminator and the release produces nothing")
		helpers.assert_eq(keys, {}, "bare Enter must reach on_char instead of the reset-only callback")
	end)

	helpers.it("counts a held key as one physical press", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local physical = {}
		kh._test_drive({ ev(EV_KEY, 30, 1), ev(EV_KEY, 30, 2), ev(EV_KEY, 30, 2) }, {
			onPhysical = function(code) physical[#physical + 1] = code end,
			onEmitRaw = function() return true end,
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
		helpers.assert_eq(chars, { "a", "\n" },
			"observe-mode dispatch includes the same textual Enter terminator")
	end)

end)





-- ========================================
-- ========================================
-- ======= 2/ Queue-Loss Recovery =========
-- ========================================
-- ========================================

helpers.describe("keyboard_hook: evdev queue-loss recovery", function()

	helpers.it("discards the broken frame and reconciles held keys from the kernel", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local emitted = {}
		local chars = {}
		local desyncs = 0
		local drained = kh._test_drive({
			ev(EV_KEY, 42, 1),
			ev(EV_SYN, 3, 0),
			ev(EV_KEY, 42, 0),
			ev(EV_SYN, 0, 0),
			ev(EV_KEY, 30, 1),
		}, {
			onEmitRaw = function(code, value)
				emitted[#emitted + 1] = string.format("%d:%d", code, value)
				return true
			end,
			onChar = function(char) chars[#chars + 1] = char end,
			onDesync = function() desyncs = desyncs + 1 end,
		}, true)

		helpers.assert_eq(drained, 5, "the complete scripted stream must be drained")
		helpers.assert_eq(desyncs, 1, "SYN_DROPPED must invalidate derived text exactly once")
		helpers.assert_eq(table.concat(emitted, " "), "42:1 42:0 30:1",
			"the lost Shift release must be synthesized before later input is forwarded")
		helpers.assert_eq(chars, { "a" },
			"the discarded release and stale Shift state must not capitalize the next key")
	end)

	helpers.it("does not resurrect a deliberately consumed key", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local emitted = {}
		local drained = kh._test_drive({
			ev(EV_KEY, 2, 1),
			ev(EV_SYN, 3, 0),
			ev(EV_SYN, 0, 0),
			ev(EV_KEY, 2, 0),
		}, {
			onConsume = function() return true end,
			onEmitRaw = function(code, value)
				emitted[#emitted + 1] = string.format("%d:%d", code, value)
				return true
			end,
			keyState = function(count)
				return string.char(0x04) .. string.rep("\0", count - 1)
			end,
		}, true)

		helpers.assert_eq(drained, 4, "the release after resynchronisation must be observed")
		helpers.assert_eq(emitted, {},
			"a consumed selection key must stay suppressed across queue recovery")
	end)

	helpers.it("forgets a consumed key the queue loss already released", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local emitted = {}
		local consumes = 0
		local drained = kh._test_drive({
			ev(EV_KEY, 2, 1),
			ev(EV_SYN, 3, 0),
			ev(EV_SYN, 0, 0),
			ev(EV_KEY, 2, 1),
			ev(EV_KEY, 2, 0),
		}, {
			onConsume = function()
				consumes = consumes + 1
				return consumes == 1
			end,
			onEmitRaw = function(code, value)
				emitted[#emitted + 1] = string.format("%d:%d", code, value)
				return true
			end,
		}, true)

		helpers.assert_eq(drained, 5, "the fresh press after recovery must be observed")
		helpers.assert_eq(emitted, { "2:1", "2:0" },
			"a consumed mark must not survive the release the queue loss swallowed:"
				.. " the next press belongs to the application once consumption declines it")
	end)

	helpers.it("restores the CapsLock state reported by the keyboard LEDs", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local captured = {}
		kh._test_drive({
			ev(EV_SYN, 3, 0),
			ev(EV_SYN, 0, 0),
		}, {
			onEmitRaw = function() return true end,
			captureEvent = function(code, value)
				captured[#captured + 1] = string.format("%d:%d", code, value)
			end,
			ledState = function(count)
				return string.char(0x02) .. string.rep("\0", count - 1)
			end,
		}, true)

		helpers.assert_eq(table.concat(captured, " "), "58:1 58:0",
			"a set LED_CAPSL bit must rebuild the XKB lock without emitting another toggle")
	end)

	helpers.it("emergency-ungrabs when kernel state cannot be queried", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local chars = 0
		local drained = kh._test_drive({
			ev(EV_SYN, 3, 0),
			ev(EV_SYN, 0, 0),
			ev(EV_KEY, 30, 1),
		}, {
			onEmitRaw = function() return true end,
			onChar = function() chars = chars + 1 end,
			keyState = function() return nil, "query denied" end,
		}, true)

		helpers.assert_eq(drained, 2,
			"capture ownership must end before the event behind the failed recovery is read")
		helpers.assert_eq(chars, 0, "no semantic input may follow an unverified kernel state")
		helpers.assert_true(not kh.isRunning(), "failure must release capture ownership")
	end)

end)





-- ================================
-- ================================
-- ======= 3/ Capture Guard =======
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

	helpers.it("the daemon invalidates text state when evdev reports queue loss", function()
		local src = daemon_source()
		local start_at = src:find("onDesync%s*=%s*function%s*%(")
		helpers.assert_true(start_at ~= nil,
			"keyboard_hook.start must receive a queue-loss callback")
		local end_at = src:find("\n\t\tend,", start_at, true)
		helpers.assert_true(end_at ~= nil, "the queue-loss callback must be a bounded option block")
		local block = src:sub(start_at, end_at)
		helpers.assert_true(block:find("engine:reset()", 1, true) ~= nil,
			"typed trigger state derived before SYN_DROPPED must be cleared")
		helpers.assert_true(block:find("prediction_engine.cancel()", 1, true) ~= nil,
			"an LLM request derived from lost input must be cancelled")
		helpers.assert_true(block:find("tooltip_preview.hide()", 1, true) ~= nil,
			"a suggestion derived from lost input must be hidden")
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
-- ======= 4/ Injector Emit Contract =======
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




-- ================================================
-- ================================================
-- ======= 5/ A Dying Callback Still Forwards ====
-- ================================================
-- ================================================

helpers.describe("keyboard_hook: a failing callback still forwards the grabbed event", function()

	helpers.it("forward-on-fail: a raising onPhysical still delivers the press", function()
		-- Regression: _on_physical ran before _forward_raw, so a throwing
		-- metrics consumer emergency-stopped the hook AND ate the grabbed
		-- keystroke — the application never saw a key the kernel took away.
		local kh = helpers.load_module("adapters.keyboard_hook")
		local emitted = {}
		kh._test_drive({ ev(EV_KEY, 30, 1) }, {
			onPhysical = function() error("metrics consumer died") end,
			onEmitRaw = function(code, value)
				emitted[#emitted + 1] = string.format("%d:%d", code, value)
				return true
			end,
		}, true)
		helpers.assert_eq(emitted, { "30:1" },
			"the grabbed press must reach the application even as capture stops")
		helpers.assert_true(not kh.isRunning(),
			"the failure must still release capture ownership")
	end)

	helpers.it("forward-on-fail: a raising onConsume still delivers the press", function()
		-- Same shape one branch down: the consumption verdict never arrives,
		-- so the event belongs to the application by default.
		local kh = helpers.load_module("adapters.keyboard_hook")
		local emitted = {}
		kh._test_drive({ ev(EV_KEY, 30, 1) }, {
			onConsume = function() error("consumer died") end,
			onEmitRaw = function(code, value)
				emitted[#emitted + 1] = string.format("%d:%d", code, value)
				return true
			end,
		}, true)
		helpers.assert_eq(emitted, { "30:1" },
			"a missing verdict is not a suppression — the press must be forwarded")
		helpers.assert_true(not kh.isRunning(),
			"the failure must still release capture ownership")
	end)

	helpers.it("forward-on-fail: a raising onHold still delivers the release", function()
		-- The release owns the application's key state: losing it sticks the
		-- key down over there while nothing is held here.
		local kh = helpers.load_module("adapters.keyboard_hook")
		local emitted = {}
		kh._test_drive({ ev(EV_KEY, 30, 1), ev(EV_KEY, 30, 0) }, {
			onHold = function() error("hold consumer died") end,
			onEmitRaw = function(code, value)
				emitted[#emitted + 1] = string.format("%d:%d", code, value)
				return true
			end,
		}, true)
		-- The emergency stop releases what it forwarded before closing, so the
		-- release may go out twice; the kernel ignores the second.
		helpers.assert_eq(emitted[1], "30:1")
		helpers.assert_eq(emitted[2], "30:0",
			"the release must reach the application even as capture stops")
		helpers.assert_true(not kh.isRunning(),
			"the failure must still release capture ownership")
	end)

end)


helpers.describe("keyboard hook: acknowledged consumed repeats", function()
	local function observe(mode)
		local previous = package.loaded["modules.hotstrings.device_finder"]
		local state = { origins = 0, consumed = 0, repeated = 0, raw = {}, values = {} }
		package.loaded["modules.hotstrings.device_finder"] = {
			physical_sources = function(paths)
				state.origins = state.origins + 1
				return { { path = paths[1], sysfs = "/sys/probe/keyboard", name = "fixture keyboard", physical = true } }
			end,
		}
		local ok, err = pcall(function()
			local hook = helpers.load_module("adapters.keyboard_hook")
			local primed = false
			local stream = { ev(EV_KEY, 36, 1), ev(EV_KEY, 36, 2), ev(EV_KEY, 36, 2),
				ev(EV_KEY, 36, 0), ev(EV_KEY, 36, 1), ev(EV_KEY, 36, 2), ev(EV_KEY, 36, 0) }
			if mode == "independent" then
				stream = { ev(EV_KEY, 36, 1), ev(EV_KEY, 37, 1), ev(EV_KEY, 36, 2), ev(EV_KEY, 37, 2),
					ev(EV_KEY, 36, 2), ev(EV_KEY, 37, 2), ev(EV_KEY, 36, 0), ev(EV_KEY, 37, 0),
					ev(EV_KEY, 36, 1), ev(EV_KEY, 36, 2), ev(EV_KEY, 36, 0) }
			end
			hook._test_drive(stream, {
				captureEvent = function(_, value)
					if not primed then hook.physical_source_receipt(); primed = true end
					if value ~= 0 then return "j", "j" end
				end,
				onConsume = function(detail)
					state.consumed = state.consumed + 1
					state.origin = detail.origin_generation
					if mode == "boolean" then return true end
					local receipt = { consume = true, repeat_callback = function(repeat_detail)
						state.repeated = state.repeated + 1
						state.values[#state.values + 1] = repeat_detail.value
						if mode == "independent" then
							state.keys = state.keys or {}
							state.keys[#state.keys + 1] = detail.code .. ":" .. repeat_detail.code
							if detail.code == 36 and state.repeated == 1 then return false end
						end
						if mode == "refused" and state.repeated == 1 then return false end
						return true
					end }
					if mode == "malformed" then receipt.foreign = true end
					return receipt
				end,
				onEmitRaw = function(code, value)
					state.raw[#state.raw + 1] = code .. ":" .. value
					return true
				end,
			}, true)
		end)
		package.loaded["modules.hotstrings.device_finder"] = previous
		if not ok then error(err, 0) end
		return state
	end

	helpers.it("(magic-source-repeat) keeps the exact press callback through repeat and releases it at key-up", function()
		local state = observe("accepted")
		helpers.assert_eq(state.consumed, 2)
		helpers.assert_eq(state.repeated, 3)
		helpers.assert_eq(state.values, { 2, 2, 2 })
		helpers.assert_type(state.origin, "number")
		helpers.assert_true(state.origin > 0)
		helpers.assert_eq(state.origins, 1, "repeats use the existing native epoch without sysfs rescans")
		helpers.assert_eq(state.raw, {}, "a consumed down owns every repeat and its release")
	end)

	helpers.it("(magic-source-repeat) retires a refused callback until the next physical press", function()
		local state = observe("refused")
		helpers.assert_eq(state.consumed, 2)
		helpers.assert_eq(state.repeated, 2, "refusal cannot revive before key-up")
		helpers.assert_eq(state.raw, {})
	end)

	helpers.it("(magic-source-repeat) independent held keys retain their own callbacks and refusal lifetimes", function()
		local state = observe("independent")
		helpers.assert_eq(state.consumed, 3)
		helpers.assert_eq(state.repeated, 4)
		helpers.assert_eq(state.keys, { "36:36", "37:37", "37:37", "36:36" })
		helpers.assert_eq(state.raw, {})
	end)

	helpers.it("(magic-source-repeat) publishes a qualified origin before the first newly started physical press", function()
		local names = { "adapters.xkb_capture", "adapters.evdev_reader", "modules.hotstrings.device_finder" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local path = os.tmpname()
		local file = assert(io.open(path, "w"))
		file:close()
		local hook, observed = nil, { origins = 0, epochs = {}, repeated = 0, raw = {} }
		local ok, err = pcall(function()
			local Capture = helpers.load_module(names[1])
			Capture._set_backend({
				create = function() return {} end, destroy = function() end,
				source_group = function() return 0, 1 end,
				key_sym = function() return "j" end, key_utf8 = function() return "j" end,
				sym_utf8 = function(_, sym) return sym end, update_key = function() end,
				compose_feed = function() end, compose_status = function() return "nothing" end,
				compose_reset = function() end,
			})
			assert(Capture.load("fixture keymap"))
			local Reader = helpers.load_module(names[2])
			local Input = require("infra.input_event")
			local queue, at = {}, 0
			for i, value in ipairs({ 1, 2, 0 }) do queue[i] = Input.encode(1, 36, value, Input.native_size()) end
			Reader._set_backend({
				open = function() return 1 end, ioctl = function() return true end,
				read = function() at = at + 1; return queue[at] end,
				poll = function() return queue[at + 1] ~= nil end, close = function() return true end,
				read_bits = function(_, _, count) return string.rep("\0", count) end,
			})
			package.loaded[names[3]] = {
				is_key_device = function() return true end,
				physical_sources = function(paths)
					observed.origins = observed.origins + 1
					return { { path = paths[1], sysfs = "/fixture/native-keyboard",
						name = "fixture keyboard", physical = true } }
				end,
			}
			hook = helpers.load_module("adapters.keyboard_hook")
			hook.start({ device = path, pinned = true, intercept = true,
				onConsume = function(detail)
					observed.epochs[#observed.epochs + 1] = detail.origin_generation or "unavailable"
					if detail.origin_generation == nil then return true end
					return { consume = true, repeat_callback = function()
						observed.repeated = observed.repeated + 1
						return true
					end }
				end,
				onEmitRaw = function(code, value)
					observed.raw[#observed.raw + 1] = code .. ":" .. value
					return true
				end,
			})
			observed.running = hook.isRunning()
			hook.pump()
			hook.stop()
			Capture._reset_backend()
			Reader._reset_backend()
		end)
		if hook then pcall(hook.stop) end
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		os.remove(path)
		if not ok then error(err, 0) end
		helpers.assert_eq(observed.running, true, "the native reader must actually have started")
		helpers.assert_eq(#observed.epochs, 1)
		helpers.assert_type(observed.epochs[1], "number", "the first physical press already owns its qualified epoch")
		helpers.assert_true(observed.epochs[1] > 0)
		helpers.assert_eq(observed.repeated, 1)
		helpers.assert_eq(observed.origins, 2, "acquisition and completed startup publish once each; repeats do not rescan")
		helpers.assert_eq(observed.raw, {})
	end)

	helpers.it("(magic-source-repeat) ordinary boolean consumers stay nonrepeating", function()
		local state = observe("boolean")
		helpers.assert_eq(state.consumed, 2)
		helpers.assert_eq(state.repeated, 0)
		helpers.assert_eq(state.raw, {})
	end)

	helpers.it("(magic-source-repeat) an unsupported receipt never claims the physical press", function()
		local state = observe("malformed")
		helpers.assert_eq(state.repeated, 0)
		helpers.assert_eq(state.raw, { "36:1", "36:2", "36:2", "36:0", "36:1", "36:2", "36:0" })
	end)
end)


helpers.describe("keyboard hook: recovery repeat ownership", function()
	--- Reopens a real reader through the actual watchdog after an owned down.
	--- @param mode string Independent native source/lifetime scenario.
	--- @return table observed Callback epochs, cookies and raw emitted events.
	local function observe_recovery(mode)
		local names = { "adapters.xkb_capture", "adapters.evdev_reader",
			"modules.hotstrings.device_finder", "adapters.keyboard_hook" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local paths = { os.tmpname(), os.tmpname() }
		for _, path in ipairs(paths) do assert(io.open(path, "w")):close() end
		local observed = { origins = 0, epochs = {}, repeated = {}, raw = {}, opens = 0, key_queries = 0 }
		local hook, Capture, Reader
		local ok, err = pcall(function()
			Capture = helpers.load_module(names[1])
			Capture._set_backend({
				create = function() return {} end, destroy = function() end,
				source_group = function() return 0, 1 end,
				key_sym = function() return "j" end, key_utf8 = function() return "j" end,
				sym_utf8 = function(_, sym) return sym end, update_key = function() end,
				compose_feed = function() end, compose_status = function() return "nothing" end,
				compose_reset = function() end,
			})
			assert(Capture.load("fixture keymap"))
			Reader = helpers.load_module(names[2])
			local Input = require("infra.input_event")
			local phase, handles, native_held = 1, {}, {}
			local streams = { [paths[1]] = { mode == "fresh" and {} or { { 1, 1000 } } } }
			streams[paths[1]][2] = mode == "fresh" and { { 1, 2000 }, { 2, 3000 }, { 0, 4000 } }
				or { { 2, 2000 }, { 0, 3000 }, { 1, 4000 }, { 2, 5000 }, { 0, 6000 } }
			if mode == "multiple" then
				streams[paths[1]][1] = { { 1, 1000, 36 }, { 1, 1500, 37 } }
				streams[paths[1]][2] = { { 2, 2000, 36 }, { 2, 2500, 37 },
					{ 0, 3000, 36 }, { 0, 3500, 37 }, { 1, 4000, 36 }, { 2, 5000, 36 }, { 0, 6000, 36 } }
			elseif mode == "released" then
				streams[paths[1]][2] = { { 1, 2000 }, { 2, 3000 }, { 0, 4000 } }
			elseif mode == "unknown" then
				streams[paths[1]][2] = { { 1, 2000 }, { 2, 3000 }, { 0, 4000 },
					{ 1, 5000 }, { 2, 6000 }, { 0, 7000 } }
			elseif mode == "double" then
				streams[paths[1]][2] = { { 2, 2000 } }
				streams[paths[1]][3] = { { 2, 3000 }, { 0, 4000 }, { 1, 5000 }, { 2, 6000 }, { 0, 7000 } }
			elseif mode == "retired" then
				streams[paths[2]] = { {}, { { 1, 2000 }, { 2, 3000 }, { 0, 4000 } } }
			elseif mode == "added" then
				streams[paths[1]][2] = { { 2, 2000 }, { 0, 4000 } }
				streams[paths[2]] = { {}, { { 1, 3000 }, { 2, 5000 }, { 0, 6000 } } }
			end
			Reader._set_backend({
				open = function(path)
					observed.opens = observed.opens + 1
					handles[observed.opens] = { path = path, phase = phase, at = 0 }
					return observed.opens
				end,
				ioctl = function() return true end,
				read = function(fd)
					local state = handles[fd]
					if state.phase ~= phase then state.phase, state.at = phase, 0 end
					state.at = state.at + 1
					local event = streams[state.path][phase] and streams[state.path][phase][state.at]
					if not event then return nil end
					local code = event[3] or 36
					native_held[state.path] = native_held[state.path] or {}
					if event[1] == 1 then native_held[state.path][code] = true
					elseif event[1] == 0 then native_held[state.path][code] = false end
					return Input.encode(1, code, event[1], Input.native_size(), event[2])
				end,
				poll = function(fd)
					local state = handles[fd]
					return streams[state.path][phase] and streams[state.path][phase][state.at + 1] ~= nil
				end,
				close = function() return true end,
				read_bits = function(fd, request, count)
					if request % 256 == Reader.EVIOCGKEY_NR then
						observed.key_queries = observed.key_queries + 1
						if mode == "unknown" and phase > 1 then
							observed.refused_key_query = true
							return nil, "fixture native key snapshot unavailable"
						end
						local keys = native_held[handles[fd].path] or {}
						if keys[36] ~= true then observed.released_key_receipt = true end
						local bytes = {}
						for index = 1, count do bytes[index] = 0 end
						for code, held in pairs(keys) do
							if held then
								local index = math.floor(code / 8) + 1
								bytes[index] = bytes[index] + 2 ^ (code % 8)
							end
						end
						for index = 1, count do bytes[index] = string.char(bytes[index]) end
						return table.concat(bytes)
					end
					return string.rep("\0", count)
				end,
			})
			local source_set = { paths[1] }
			package.loaded[names[3]] = {
				find_devices = function() return source_set, {} end,
				is_key_device = function() return true end,
				physical_sources = function(current)
					observed.origins = observed.origins + 1
					local sources = {}
					for _, path in ipairs(current) do sources[#sources + 1] = {
						path = path, sysfs = "/fixture/native-keyboard", name = "fixture keyboard", physical = true } end
					return sources
				end,
			}
			hook = helpers.load_module(names[4])
			hook.start({ intercept = true,
				onConsume = function(detail)
					observed.epochs[#observed.epochs + 1] = detail.origin_generation or "unavailable"
					local cookie = #observed.epochs
					if mode == "boolean" or detail.origin_generation == nil then return true end
					return { consume = true, repeat_callback = function()
						observed.repeated[#observed.repeated + 1] = cookie
						return true
					end }
				end,
				onEmitRaw = function(code, value)
					observed.raw[#observed.raw + 1] = code .. ":" .. value
					return true
				end,
			})
			observed.started = hook.isRunning()
			hook.pump()
			phase = 2
			if mode == "retired" then source_set = { paths[2] }
			elseif mode == "added" then source_set = { paths[1], paths[2] }
			else
				assert(Reader.close("keyboard:" .. paths[1]))
				if mode == "released" or mode == "unknown" then native_held[paths[1]] = {} end
				hook.pump()
				observed.recovering = hook.isRecovering()
			end
			for _ = 1, hook.DEVICE_CHECK_TICKS do hook.check_device() end
			observed.reacquired = hook.isRunning()
			hook.pump()
			if mode == "double" then
				phase = 3
				assert(Reader.close("keyboard:" .. paths[1]))
				hook.pump()
				observed.recovering_again = hook.isRecovering()
				for _ = 1, hook.DEVICE_CHECK_TICKS do hook.check_device() end
				observed.reacquired_again = hook.isRunning()
				hook.pump()
			end
		end)
		if hook then pcall(hook.stop) end
		if Reader then pcall(Reader._reset_backend) end
		if Capture then pcall(Capture._reset_backend) end
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		for _, path in ipairs(paths) do os.remove(path) end
		if not ok then error(err, 0) end
		return observed
	end

	helpers.it("(magic-source-recovery) the first fresh press after acknowledged reacquisition owns its native epoch", function()
		local state = observe_recovery("fresh")
		helpers.assert_true(state.started and state.recovering and state.reacquired)
		helpers.assert_eq(#state.epochs, 1)
		helpers.assert_type(state.epochs[1], "number")
		helpers.assert_true(state.epochs[1] > 0)
		helpers.assert_eq(state.repeated, { 1 })
		helpers.assert_eq(state.raw, {})
		helpers.assert_eq(state.opens, 2)
		helpers.assert_eq(state.key_queries, 0, "sources with no consumed debt require no release query")
		helpers.assert_eq(state.origins, 5, "startup and completed recovery publish at lifecycle boundaries, never per repeat")
	end)

	for _, mode in ipairs({ "held", "double", "boolean" }) do
		helpers.it("(magic-source-recovery) retains " .. mode .. " suppression debt until actual release", function()
			local state = observe_recovery(mode)
			helpers.assert_true(state.started and state.recovering and state.reacquired)
			helpers.assert_eq(#state.epochs, 2, "a suppressed old repeat never creates a new consumption decision")
			helpers.assert_type(state.epochs[1], "number")
			helpers.assert_type(state.epochs[2], "number")
			helpers.assert_true(state.epochs[2] > state.epochs[1])
			helpers.assert_eq(state.repeated, mode == "boolean" and {} or { 2 }, "the retired old callback must never run")
			helpers.assert_eq(state.raw, {}, "an old consumed down cannot become a raw repeat/release")
			helpers.assert_eq(state.opens, mode == "double" and 3 or 2)
			helpers.assert_eq(state.key_queries, mode == "double" and 2 or 1, "each indebted source is queried once per reopening")
			helpers.assert_eq(state.origins, mode == "double" and 8 or 5)
			if mode == "double" then helpers.assert_true(state.recovering_again and state.reacquired_again) end
		end)
	end

	helpers.it("(magic-source-recovery) one native snapshot preserves two independent consumed keys until release", function()
		local state = observe_recovery("multiple")
		helpers.assert_true(state.started and state.recovering and state.reacquired)
		helpers.assert_eq(#state.epochs, 3)
		for _, epoch in ipairs(state.epochs) do helpers.assert_type(epoch, "number") end
		helpers.assert_eq(state.epochs[1], state.epochs[2], "the two original keys share their actual source epoch")
		helpers.assert_true(state.epochs[3] > state.epochs[2])
		helpers.assert_eq(state.repeated, { 3 }, "neither retired key callback may repeat before its own release")
		helpers.assert_eq(state.raw, {})
		helpers.assert_eq(state.key_queries, 1, "native release evidence is acquired once per indebted source, not per key or repeat")
		helpers.assert_eq(state.origins, 5)
	end)

	helpers.it("(magic-source-recovery) acknowledges a native release while closed before accepting the next fresh down", function()
		local state = observe_recovery("released")
		helpers.assert_true(state.started and state.recovering and state.reacquired)
		helpers.assert_eq(#state.epochs, 2, "a release confirmed by the native owner must not swallow the new press")
		helpers.assert_type(state.epochs[1], "number")
		helpers.assert_type(state.epochs[2], "number")
		helpers.assert_true(state.epochs[2] > state.epochs[1])
		helpers.assert_eq(state.repeated, { 2 })
		helpers.assert_eq(state.raw, {})
		helpers.assert_eq(state.key_queries, 1)
		helpers.assert_eq(state.released_key_receipt, true, "the real bitset reader must acknowledge physical release")
		helpers.assert_eq(state.origins, 5)
	end)

	helpers.it("(magic-source-recovery) an unavailable native release query keeps debt until an actual key-up", function()
		local state = observe_recovery("unknown")
		helpers.assert_true(state.started and state.recovering and state.reacquired)
		helpers.assert_eq(state.refused_key_query, true, "the real bitset reader must observe the native refusal")
		helpers.assert_eq(#state.epochs, 2, "unknown release cannot acknowledge the first reopened press")
		helpers.assert_type(state.epochs[1], "number")
		helpers.assert_type(state.epochs[2], "number")
		helpers.assert_true(state.epochs[2] > state.epochs[1])
		helpers.assert_eq(state.repeated, { 2 }, "only the press after an observed key-up may own repetitions")
		helpers.assert_eq(state.raw, {})
		helpers.assert_eq(state.key_queries, 1)
		helpers.assert_eq(state.origins, 5)
	end)

	for _, mode in ipairs({ "added", "retired" }) do
		helpers.it("(magic-source-recovery) keeps " .. mode .. " keyboard ownership distinct for the same key code", function()
			local state = observe_recovery(mode)
			helpers.assert_true(state.started and state.reacquired)
			helpers.assert_eq(#state.epochs, 2)
			helpers.assert_type(state.epochs[1], "number")
			helpers.assert_type(state.epochs[2], "number")
			helpers.assert_true(state.epochs[2] > state.epochs[1])
			helpers.assert_eq(state.repeated, { 2 }, "only the new source's own accepted press may repeat")
			helpers.assert_eq(state.raw, {})
			helpers.assert_eq(state.opens, 2)
			helpers.assert_eq(state.origins, 4, "a warm acquisition already publishes qualified origin; no redundant scan")
			helpers.assert_eq(state.key_queries, mode == "added" and 1 or 0, "retired debt never queries or owns a replacement source")
		end)
	end
end)
