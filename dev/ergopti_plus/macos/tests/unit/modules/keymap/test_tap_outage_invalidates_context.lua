--- tests/unit/modules/keymap/test_tap_outage_invalidates_context.lua

--- ==============================================================================
--- MODULE: Regression — keystrokes swallowed after a keyboard-tap outage
---         (tap-outage-stale-context)
--- DESCRIPTION:
--- Users reported characters simply disappearing while typing. Two distinct
--- mechanisms produced that, and both are pinned here.
---
--- ROOT CAUSE 1 — the residual outage lasted up to five seconds. Hammerspoon
--- 1.1.1 normally re-enables CoreGraphics timeout notifications in native code,
--- but a native or lifecycle failure can still leave a tap observed disabled.
--- A dead tap delivers no events to Lua, so the independent polling watchdog
--- bounds that residual outage. At 5 s, several sentences can pass while no
--- expansion fires and the buffer stops tracking the screen.
---
--- ROOT CAUSE 2 — and the part that outlived the outage: reviving the tap
--- restored the plumbing but not the truth. CoreState.buffer still described the
--- line as it was before the outage, while the user had kept typing. The next
--- expansion sized its backspaces against that stale buffer and erased
--- characters the user had actually typed. The driver's own documented symptom
--- for the same family is "hs★" → "hsammerspoon".
---
--- Both the watchdog and the in-callback error handler re-arm the tap, so BOTH
--- must invalidate — the error handler re-arms it so quickly that the watchdog
--- never sees it down and never runs its own invalidation.
---
--- WHY SOURCE-LEVEL: onKeyDownRaw and the watchdog are locals inside
--- modules/keymap/init.lua, and nothing in the suite can construct the
--- hs.eventtap.event object the handler consumes — tests/meta/
--- test_e2e_exercises_real_dispatch.lua records that this is deliberately out of
--- scope. The sibling regression test_cmdv_paste_counter_order.lua pins its own
--- ordering invariant the same way. These assertions are written against
--- STRUCTURE (a symbol exists, a call happens inside a given block, a value is
--- bounded) rather than prose, so they cannot be satisfied by a comment.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads the keymap engine's source by SYMBOL rather than by path, so the
--- assertions survive the file being moved or renamed (a CI ratchet enforces
--- this, and the pre-commit hook blocks a pinned path outright).
---
--- TAP_WATCHDOG_SEC is the selector because it is unique to the keymap engine
--- across the whole production tree — read_driver_source concatenates EVERY
--- file containing the symbol, and the position-comparing assertion below
--- ("the declaration precedes every call") would silently change meaning if two
--- files were returned. It is also the selector that survives the fix being
--- reverted, so a regression fails on the assertion that matters rather than on
--- an unreadable source.
--- @return string
local function keymap_source()
	local src = helpers.read_driver_source("TAP_WATCHDOG_SEC")
	assert(src and src ~= "", "the keymap engine source must be readable")
	return src
end

--- Extracts the body of a `local function <name>(` … matching `\nend` block.
--- @param src string
--- @param name string
--- @return string|nil
local function function_body(src, name)
	local start = src:find("local function " .. name .. "%(")
	if not start then
		-- Forward-declared callbacks use `name = function(...)` so constructors
		-- above them capture the local rather than an accidental nil global.
		start = src:find("\n" .. name .. "%s*=%s*function%(")
	end
	if not start then return nil end
	local rest = src:sub(start)
	local _, stop = rest:find("\nend\n")
	return stop and rest:sub(1, stop) or rest
end





-- ===========================================
-- ===========================================
-- ======= 1/ The Outage Must Be Short =======
-- ===========================================
-- ===========================================

helpers.describe("keymap tap watchdog: the polling interval bounds the outage", function()

	helpers.it("polls at most once per second", function()
		local src = keymap_source()
		local value = src:match("local TAP_WATCHDOG_SEC%s*=%s*([%d%.]+)")
		helpers.assert_not_nil(value,
			"TAP_WATCHDOG_SEC must exist as an independent still-disabled-tap backstop")
		local seconds = tonumber(value)
		helpers.assert_not_nil(seconds, "TAP_WATCHDOG_SEC must be numeric")
		helpers.assert_true(seconds <= 1,
			"the watchdog interval is the worst-case length of a total typing outage, not a "
				.. "sampling nicety. At 5 s the user types whole sentences into a driver that "
				.. "sees nothing. The poll is three isEnabled() reads on a timer, nowhere near "
				.. "the keystroke path, so a short interval costs nothing worth measuring")
	end)

end)





-- ====================================================
-- ====================================================
-- ======= 2/ Recovery Must Discard Stale State =======
-- ====================================================
-- ====================================================

helpers.describe("keymap tap recovery: a revived tap must not trust the old buffer", function()

	helpers.it("declares an invalidation routine", function()
		local body = function_body(keymap_source(), "invalidate_observed_context")
		helpers.assert_not_nil(body,
			"a tap outage means keystrokes were missed; something must exist to say so")
	end)

	helpers.it("the routine drops only context inferred from observed physical input", function()
		local body = function_body(keymap_source(), "invalidate_observed_context")
		helpers.assert_not_nil(body, "invalidate_observed_context must exist")
		helpers.assert_true(body:find('CoreState%.buffer%s*=%s*""') ~= nil,
			"the buffer describes a line that no longer exists — keeping it is what makes the "
				.. "next expansion backspace over the user's own text")
		helpers.assert_true(body:find("CoreState%.start_is_word_boundary%s*=%s*false") ~= nil,
			"the cursor sits in territory we never observed, so word-anchored triggers must "
				.. "stay silent until a real terminator is seen — assuming a boundary here "
				.. "fires expansions flush against unknown text")
		helpers.assert_true(body:find("LLMBridge%.set_runtime_quarantined%(true%)") ~= nil,
			"the HID path must close prediction interaction immediately without canvas/task work")
		helpers.assert_true(body:find("arm_observed_context_reconcile%(false%)") ~= nil,
			"the closed runtime must arm the retained full-reset obligation")
		local arm_body = function_body(keymap_source(), "arm_observed_context_reconcile")
		helpers.assert_not_nil(arm_body, "the async reconciliation armer must exist")
		helpers.assert_true(arm_body:find("_context_reconcile_pending%s*=%s*true") ~= nil,
			"the armer must retain a full-reset obligation for timer failure/watchdog retry")
		helpers.assert_true(body:find("SyntheticInput%.cancel") == nil,
			"tap recovery must not revoke already-authorized tagged user output")
	end)

	helpers.it("the routine releases a held terminator rather than dropping it", function()
		local body = function_body(keymap_source(), "invalidate_observed_context")
		helpers.assert_not_nil(body, "invalidate_observed_context must exist")
		helpers.assert_true(body:find("TerminatorReplay%.flush_now") ~= nil,
			"a terminator held across the outage has lost its ordering guarantee, but silently "
				.. "discarding it eats the user's Enter — late is recoverable, lost is not")
	end)

	helpers.it("the watchdog invalidates when it revives the keyDown tap", function()
		local body = function_body(keymap_source(), "tap_watchdog")
		helpers.assert_not_nil(body, "tap_watchdog must exist")
		helpers.assert_true(body:find("invalidate_observed_context%(") ~= nil,
			"reviving the tap without invalidating restores the plumbing and keeps the lie: "
				.. "this is the half of the bug that outlives the outage")
		helpers.assert_true(body:find("keydown_revived") ~= nil,
			"only the keyDown tap feeds the buffer, so the invalidation must be conditional on "
				.. "THAT tap having been revived — firing it whenever the passive mouse tap "
				.. "recovers would wipe the buffer mid-word for no reason")
	end)

	helpers.it("the in-callback error handler invalidates too", function()
		local src = keymap_source()
		-- The error path re-arms the tap itself, so the watchdog never observes it
		-- down and never runs its own invalidation. If this path does not
		-- invalidate, nothing does.
		local at = src:find("Event tap disabled after error", 1, true)
		helpers.assert_not_nil(at, "the error-path re-arm must still exist")
		local window = src:sub(at, at + 800)
		helpers.assert_true(window:find("invalidate_observed_context%(") ~= nil,
			"this handler re-arms the tap fast enough that the watchdog never sees it down, "
				.. "so it must do its own invalidation or the stale buffer survives unnoticed")
	end)

	helpers.it("the routine is declared above every caller", function()
		-- A Lua local's scope begins after its declaration: a copy placed further
		-- down binds the never-assigned GLOBAL in the error handler, and indexing
		-- nil raises inside the very handler meant to recover from a fault.
		local src = keymap_source()
		local decl = src:find("local function invalidate_observed_context%(")
		helpers.assert_not_nil(decl, "invalidate_observed_context must exist")
		-- [^%w_] not [^%s]: production calls sit at the start of an indented line,
		-- so the character before them is a TAB. Requiring a non-whitespace
		-- character there meant this guard never matched a real call site and
		-- passed vacuously — a guard against the driver's signature bug that
		-- could not fire.
		local first_call = src:find("[^%w_]invalidate_observed_context%(")
		helpers.assert_not_nil(first_call,
			"the pattern must actually match a call site, or this assertion is vacuous")
		helpers.assert_true(first_call > decl,
			"every call site must sit BELOW the declaration — see the interceptor-error-latch "
				.. "regression for what an above-declaration reference does here")
	end)

end)





-- ==================================================
-- ==================================================
-- ======= 3/ Unobserved Windows Leak Nothing =======
-- ==================================================
-- ==================================================

helpers.describe("keymap: tagged events are filtered before ignored-window exits", function()

	helpers.it("the explicit ownership gate precedes the window query", function()
		local src = keymap_source()
		local raw_pos = src:find(
			"local function onKeyDownRaw%(e, provenance, provenance_status%)")
		helpers.assert_not_nil(raw_pos, "the raw keyDown handler must remain locatable")
		local raw = src:sub(raw_pos)
		local gate_pos = raw:find("if provenance and not internal_loopback then", 1, true)
		local ignored_pos = raw:find("km_utils.is_ignored_window", 1, true)
		helpers.assert_true(gate_pos ~= nil and ignored_pos ~= nil,
			"owned-event gate and ignored-window fast exit must both remain present")
		helpers.assert_true(gate_pos < ignored_pos,
			"an owned tag must bypass every window-dependent physical-input branch")
		local gate = raw:sub(gate_pos, ignored_pos)
		helpers.assert_true(gate:find("return false", 1, true) ~= nil,
			"ordinary owned events must leave the handler before ignored-window state")
	end)

end)
