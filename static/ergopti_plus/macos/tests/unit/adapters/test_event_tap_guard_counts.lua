--- tests/unit/adapters/test_event_tap_guard_counts.lua

--- ==============================================================================
--- MODULE: Event-Tap Disable Accounting
--- DESCRIPTION:
--- When a tap callback overruns the CoreGraphics deadline, macOS disables the tap
--- and tells us so through the callback itself. That notification is the ONLY
--- latency event the OS reports to this driver directly, which makes counting it
--- the driver's only self-reported performance metric.
---
--- WHY A COUNT AND NOT JUST THE LOG LINE:
--- the guard has always logged the disable. A log line is recoverable — it takes
--- a user willing to send their log and someone willing to grep it — but it is
--- not OBSERVABLE: the driver cannot answer "how often did this happen to you?".
--- The count can, and it lands in the health report the same user already opens.
--- Found by the 2026-08-04 performance audit, whose own prompt names it: "compte
--- combien de fois il a tiré dans les logs — c'est ta mesure directe du nombre de
--- fois où le budget a été dépassé en conditions réelles."
---
--- THE TWO CAUSES ARE COUNTED SEPARATELY ON PURPOSE. A timeout is our latency to
--- fix. A user-input disable is the accessibility permission moving underneath
--- us, and has nothing to do with performance. Summing them would put the second
--- into a number someone reads as the first.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The synthetic event types. The guard resolves them from hs.eventtap.event.types
-- at call time, so the stub must publish the same names.
local TYPE_TIMEOUT    = 0xFFFE
local TYPE_USER_INPUT = 0xFFFF
local TYPE_KEY_DOWN   = 10




-- ==================================================
-- ==================================================
-- ======= 1/ Harness ===============================
-- ==================================================
-- ==================================================

--- Loads the guard against an hs stub that publishes the disable types.
--- @return table Guard module.
local function fresh_guard()
	local Guard = helpers.load_with_stubs("adapters.event_tap_guard", {
		eventtap = {
			event = {
				types = {
					tapDisabledByTimeout   = TYPE_TIMEOUT,
					tapDisabledByUserInput = TYPE_USER_INPUT,
					keyDown                = TYPE_KEY_DOWN,
				},
			},
		},
	})
	Guard.reset_disable_counts()
	return Guard
end

--- A minimal event object answering getType().
--- @param t number
--- @return table
local function event_of(t)
	return { getType = function() return t end }
end

--- A tap whose start() always succeeds.
--- @return table
local function live_tap()
	return { start = function() end }
end




-- ==================================================
-- ==================================================
-- ======= 2/ The tally =============================
-- ==================================================
-- ==================================================

helpers.describe("event_tap_guard: disable accounting", function()

	helpers.it("starts at zero", function()
		local Guard = fresh_guard()
		local counts = Guard.disable_counts()
		helpers.assert_eq(0, counts.by_timeout)
		helpers.assert_eq(0, counts.by_user)
	end)

	helpers.it("counts a callback overrun", function()
		local Guard = fresh_guard()
		Guard.handle_disabled(event_of(TYPE_TIMEOUT), live_tap(), "keymap.main")
		local counts = Guard.disable_counts()
		helpers.assert_eq(1, counts.by_timeout,
			"a tap disabled after its callback overran the deadline must be counted — it is the "
			.. "only latency event macOS reports to this driver directly")
		helpers.assert_eq(0, counts.by_user,
			"an overrun is not an accessibility change; summing the two would put a permission "
			.. "toggle into the number someone reads as a performance measurement")
	end)

	helpers.it("counts an accessibility change separately", function()
		local Guard = fresh_guard()
		Guard.handle_disabled(event_of(TYPE_USER_INPUT), live_tap(), "keymap.main")
		local counts = Guard.disable_counts()
		helpers.assert_eq(0, counts.by_timeout)
		helpers.assert_eq(1, counts.by_user)
	end)

	helpers.it("attributes each disable to its tap", function()
		local Guard = fresh_guard()
		Guard.handle_disabled(event_of(TYPE_TIMEOUT), live_tap(), "keymap.main")
		Guard.handle_disabled(event_of(TYPE_TIMEOUT), live_tap(), "keymap.main")
		Guard.handle_disabled(event_of(TYPE_TIMEOUT), live_tap(), "gestures.primer")
		local taps = Guard.disable_counts().taps
		helpers.assert_eq(2, taps["keymap.main"],
			"per-tap attribution is what turns the number into an action: it names WHICH callback "
			.. "is too slow, and they have very different owners")
		helpers.assert_eq(1, taps["gestures.primer"])
	end)

	helpers.it("does not count an ordinary event", function()
		local Guard = fresh_guard()
		Guard.handle_disabled(event_of(TYPE_KEY_DOWN), live_tap(), "keymap.main")
		local counts = Guard.disable_counts()
		helpers.assert_eq(0, counts.by_timeout,
			"every keystroke passes through this function. Counting one would report a driver that "
			.. "overruns its deadline on every key, which is the opposite of a useful metric")
		helpers.assert_eq(0, counts.by_user)
	end)

	helpers.it("hands back a copy, not the live tally", function()
		local Guard = fresh_guard()
		Guard.handle_disabled(event_of(TYPE_TIMEOUT), live_tap(), "keymap.main")
		local snapshot = Guard.disable_counts()
		snapshot.by_timeout = 999
		snapshot.taps["keymap.main"] = 999
		local fresh = Guard.disable_counts()
		helpers.assert_eq(1, fresh.by_timeout, "a caller mutating the snapshot must not rewrite history")
		helpers.assert_eq(1, fresh.taps["keymap.main"])
	end)

end)
