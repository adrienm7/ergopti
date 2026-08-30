--- tests/unit/meta/test_injector_terminator_contract.lua

--- ==============================================================================
--- MODULE: Regression guard — the injector's terminator and pacing contract
--- DESCRIPTION:
--- macOS was repaired in July 2026 for three typing defects. This file pins the
--- Linux side of the same three so a well-meaning port of the macOS fix cannot
--- make things worse here, and so the properties Linux DOES rely on cannot be
--- optimised away.
---
--- 1. TERMINATOR ORDERING. The grabbed hook re-emits the physical terminator
---    before dispatching it to the matcher. A non-auto expansion must erase that
---    already-visible terminator to reach the trigger, type the replacement, then
---    replay the terminator only when its catalogue policy says consume=false.
---    Omitting the replay changes `teh ` into `the` and silently joins the next
---    word to the correction.
---
---    The exposure this used to record is closed by that ordering rather than
---    argued away: anything typed during the erase-and-type window stays in the
---    kernel buffer and is read AFTER, because the daemon owns the stream.
---
--- 2. THE ERASE MUST SETTLE BEFORE THE TEXT. The two-phase injection exists
---    because a replacement arriving before the deletes have been processed
---    scrambles the output — the "pex★" → "pexar exemple" shape. The inter-phase
---    delay is that guarantee; a zero would remove it silently, because nothing
---    fails, the characters merely land in the wrong order.
---
--- 3. THE KEY DELAY MUST NOT BE ZERO. ydotool at --key-delay=0 is measurably
---    lossy in some applications: keystrokes are dropped, which is how an
---    expansion loses its backspaces and prints on top of the trigger.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads the injector's source for the structural assertions below.
--- @return string
local function injector_source()
	local path = helpers.driver_root() .. "/modules/hotstrings/injector.lua"
	local fh = assert(io.open(path, "r"), "cannot open modules/hotstrings/injector.lua")
	local src = fh:read("*a")
	fh:close()
	return src
end




-- ==============================================================
-- ==============================================================
-- ======= 1/ Non-Consumed Terminator Replay =====================
-- ==============================================================
-- ==============================================================

helpers.describe("linux injector: non-consumed terminator replay", function()

	helpers.it("replays Space and punctuation after the replacement (lnx-001)", function()
		local injector = helpers.load_module("modules.hotstrings.injector")
		local layout = require("adapters.keyboard_layout")
		local codes = require("infra.evdev_codes")
		local original_ready, original_plan = layout.is_ready, layout.plan
		local rendered, active_terminator
		local keycodes = { t = 1001, h = 1002, e = 1003, terminator = 1004 }
		local chars = { [1001] = "t", [1002] = "h", [1003] = "e" }
		local channel = { is_open = function() return true end }
		channel.emit = function(code, value)
			if value ~= 1 then return true end
			if code == codes.KEY_BACKSPACE then
				rendered = rendered:sub(1, -2)
			elseif code == keycodes.terminator then
				rendered = rendered .. active_terminator
			elseif chars[code] then
				rendered = rendered .. chars[code]
			end
			return true
		end
		layout.is_ready = function() return true end
		layout.plan = function(text)
			if text == "the" then
				return {
					{ keycode = keycodes.t, mods = {} },
					{ keycode = keycodes.h, mods = {} },
					{ keycode = keycodes.e, mods = {} },
				}
			end
			if text == active_terminator then
				return { { keycode = keycodes.terminator, mods = {} } }
			end
			error("unexpected text in terminator replay test")
		end
		injector._set_uinput(channel)
		injector._set_nanosleep_for_test(function() end)

		local ok, err = pcall(function()
			for _, terminator in ipairs({ " ", ",", "." }) do
				active_terminator = terminator
				rendered = "teh" .. terminator
				injector.inject(4, "the", false, terminator)
				helpers.assert_eq(rendered, "the" .. terminator,
					"the erased terminator must be replayed after the replacement")
			end
		end)

		injector._set_uinput(nil)
		injector._set_nanosleep_for_test(nil)
		layout.is_ready, layout.plan = original_ready, original_plan
		if not ok then error(err, 0) end
	end)

	helpers.it("replays Enter and Tab as control keystrokes after text (lnx-002)", function()
		local injector = helpers.load_module("modules.hotstrings.injector")
		local layout = require("adapters.keyboard_layout")
		local codes = require("infra.evdev_codes")
		local original_ready, original_plan = layout.is_ready, layout.plan
		local emitted = {}
		local channel = {
			is_open = function() return true end,
			emit = function(code, value)
				emitted[#emitted + 1] = string.format("%d:%d", code, value)
				return true
			end,
		}
		layout.is_ready = function() return true end
		layout.plan = function(text)
			if text == "x" then return { { keycode = 1001, mods = {} } } end
			error("control terminators must bypass the text planner")
		end
		injector._set_uinput(channel)
		injector._set_nanosleep_for_test(function() end)

		local ok, err = pcall(function()
			for _, scenario in ipairs({
				{ char = "\n", keycode = codes.KEY_ENTER },
				{ char = "\t", keycode = codes.KEY_TAB },
			}) do
				emitted = {}
				injector.inject(0, "x", false, scenario.char)
				helpers.assert_eq(table.concat(emitted, " "), string.format(
					"1001:1 1001:0 %d:1 %d:0", scenario.keycode, scenario.keycode),
					"the terminator key must be emitted after the replacement")
			end
		end)

		injector._set_uinput(nil)
		injector._set_nanosleep_for_test(nil)
		layout.is_ready, layout.plan = original_ready, original_plan
		if not ok then error(err, 0) end
	end)

	helpers.it("the daemon owns the output stream, which is what makes the above safe", function()
		local hook = helpers.load_module("adapters.keyboard_hook")
		helpers.assert_type(hook.get_mode, "function",
			"get_mode() is how a caller learns whether the daemon owns the output stream")

		-- Asserted on the DAEMON, not on a freshly loaded hook. A hook that has
		-- never been started reports "observe" because nothing has set the flag
		-- yet, so asking it here would answer a question about module
		-- initialisation while appearing to answer one about the driver.
		local path = helpers.driver_root() .. "/ergopti_hotstrings.lua"
		local fh = assert(io.open(path, "r"))
		local daemon = fh:read("*a")
		fh:close()
		helpers.assert_true(daemon:find("grab%s*=%s*true") ~= nil,
			"the grab is what puts the re-emitted terminator in front of the match "
				.. "instead of racing it; a default of false would leave the physical "
				.. "terminator interleaving with the replacement again")
	end)

end)





-- ===============================================================
-- ===============================================================
-- ======= 2/ Pacing Guarantees Must Not Be Optimised Away =======
-- ===============================================================
-- ===============================================================

helpers.describe("linux injector: erase and text must not collide", function()

	helpers.it("a non-zero inter-phase delay separates the erase from the text", function()
		local src = injector_source()
		local value = src:match("local INTER_PHASE_DELAY_MS%s*=%s*(%d+)")
		helpers.assert_not_nil(value, "INTER_PHASE_DELAY_MS must exist")
		helpers.assert_true(tonumber(value) > 0,
			"the replacement must not arrive before the target has processed the deletes. "
				.. "At zero nothing errors — the characters simply land in the wrong order and "
				.. "the trigger survives in front of its own replacement")
	end)

	helpers.it("the erase spawns no process at all", function()
		local src = injector_source()
		-- The concern the old form of this check expressed — "one process spawn per
		-- backspace leaves gaps a physical keystroke can land in" — is now answered
		-- by there being no spawn: backspaces are written straight to the uinput
		-- device. Asserted as an absence, because a reintroduced subprocess would
		-- otherwise pass every behavioural test while restoring the gap.
		helpers.assert_true(src:find("ydotool key", 1, true) == nil,
			"the erase phase must not shell out; it writes to the driver's own uinput device")
		helpers.assert_true(src:find("io.popen", 1, true) == nil,
			"and it must not open a pipe either — under a grab, a gap in the erase is "
				.. "a window a physical keystroke lands in")
	end)

	helpers.it("no key delay is needed, because nothing is being rate-limited", function()
		local src = injector_source()
		-- ydotool needed a per-key delay because 0 dropped keystrokes through its
		-- socket. Writing struct input_event to /dev/uinput is a syscall the kernel
		-- either accepts or reports; there is nothing to pace, and a delay here
		-- would be latency the user sees for no reason.
		helpers.assert_true(src:find("YDOTOOL_KEY_DELAY_MS", 1, true) == nil,
			"a per-key delay constant must not come back with the subprocess it paced")
	end)

	helpers.it("the two phases are ordered erase-then-type inside inject()", function()
		local src = injector_source()
		local at = src:find("function M%.inject%(")
		helpers.assert_not_nil(at, "M.inject must exist")
		local body = src:sub(at)
		local erase_at = body:find("send_backspaces(", 1, true)
		local type_at  = body:find("send_text(", 1, true)
		helpers.assert_not_nil(erase_at, "inject must erase")
		helpers.assert_not_nil(type_at, "inject must type")
		helpers.assert_true(erase_at < type_at,
			"typing before erasing would delete the replacement's own tail instead of the "
				.. "trigger")
	end)

end)
