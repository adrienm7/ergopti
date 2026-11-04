--- tests/support/adapters/keyboard_hook/keyboard_hook_intercept_passthrough_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_keyboard_hook_intercept_passthrough
--- DESCRIPTION:
--- Prelude shared by the test_keyboard_hook_intercept_passthrough_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
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

return {
	helpers = helpers,
	EV_KEY = EV_KEY,
	EV_MSC = EV_MSC,
	EV_SYN = EV_SYN,
	ev = ev,
	GRABBED_STREAM = GRABBED_STREAM,
	OBSERVED_STREAM = OBSERVED_STREAM,
	drive = drive,
}
