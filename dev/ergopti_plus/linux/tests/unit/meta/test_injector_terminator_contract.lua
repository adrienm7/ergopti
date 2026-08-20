--- tests/unit/meta/test_injector_terminator_contract.lua

--- ==============================================================================
--- MODULE: Regression guard — the injector's terminator and pacing contract
--- DESCRIPTION:
--- macOS was repaired in July 2026 for three typing defects. This file pins the
--- Linux side of the same three so a well-meaning port of the macOS fix cannot
--- make things worse here, and so the properties Linux DOES rely on cannot be
--- optimised away.
---
--- 1. TERMINATOR ORDERING. On macOS the driver consumes the physical terminator
---    and replays it after the replacement, and getting that order wrong sent
---    Enter before the autocorrection had landed. Linux must NOT copy the replay,
---    and the reason has changed while the conclusion has not. It used to be that
---    the hook observed without grabbing, so the terminator reached the
---    application on its own. The hook now GRABS — but it re-emits every consumed
---    event through its own uinput device BEFORE dispatching it, so by the time a
---    match fires the terminator has already landed exactly once. Re-injecting it
---    would still DOUBLE it. inject() therefore takes a backspace count and a
---    replacement, and nothing else.
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
-- ======= 1/ The Terminator Is Never Re-Injected ===============
-- ==============================================================
-- ==============================================================

helpers.describe("linux injector: the terminator is the application's, not ours", function()

	helpers.it("inject() takes only a backspace count and a replacement", function()
		local src = injector_source()
		local sig = src:match("function M%.inject%(([^%)]*)%)")
		helpers.assert_not_nil(sig, "M.inject must exist")
		helpers.assert_true(sig:find("backspace_count", 1, true) ~= nil,
			"the erase count is part of the contract")
		helpers.assert_true(sig:find("replacement_text", 1, true) ~= nil,
			"the replacement is part of the contract")
		helpers.assert_true(sig:find("terminator", 1, true) == nil,
			"the injector must NOT grow a terminator parameter while the hook observes rather "
				.. "than grabs. The physical terminator already reached the application; "
				.. "re-emitting it would double every space and every newline. Porting the "
				.. "macOS replay here without switching to intercept mode is the mistake this "
				.. "assertion exists to catch")
	end)

	helpers.it("the injector emits no Return or Tab of its own", function()
		local src = injector_source()
		-- KEY_ENTER = 28, KEY_TAB = 15 in input-event-codes.h. Emitting either
		-- would be the doubled-terminator bug described above.
		helpers.assert_true(src:find('"28:1"', 1, true) == nil,
			"the injector must never synthesise Return — the user's own Return already landed")
		helpers.assert_true(src:find('"15:1"', 1, true) == nil,
			"the injector must never synthesise Tab, for the same reason")
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
