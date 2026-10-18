--- tests/support/platform/remap/tap_hold/tap_hold_engine_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_tap_hold_engine
--- DESCRIPTION:
--- Prelude shared by the test_tap_hold_engine_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

local Engine = require("platform.remap.tap_hold_engine")

local DOWN, UP, REPEAT = 1, 0, 2

local SHIFT, CTRL, ALT, CAPS, ENTER, BACKSPACE = 42, 29, 56, 58, 28, 14

local KEY_A, KEY_J, KEY_LEFT, RCTRL = 30, 36, 105, 97

local DEFAULTS = {
	left_shift = { tap_action = "copy", hold_modifier = "shift", time_activation_seconds = 0.35 },
	caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = 0.35 },
	left_alt = { tap_action = "backspace", hold_layer = "nav", time_activation_seconds = 0.2 },
	right_ctrl = { tap_action = "one_shot_shift", hold_modifier = "shift", time_activation_seconds = 0.2 },
}

-- What each key types on a US layout with NumLock on, as the hook's key_text
-- answers; a key absent here types nothing (the hook also answers nothing for
-- a key under Ctrl, Alt or Super, and for Enter, Tab and their kind).
local US_TEXT = {
	[16] = "q", [30] = "a", [36] = "j", [48] = "b", [2] = "1", [51] = ",", [52] = ".", [57] = " ",
	[79] = "1", -- KP_1
}

local function us_text(code) return US_TEXT[code] end

-- The keystrokes a US layout types the tests' characters with.
local US_PLAN = {
	["-"] = { keycode = 12, mods = {} }, [" "] = { keycode = 57, mods = {} }, [";"] = { keycode = 39, mods = {} },
	[":"] = { keycode = 39, mods = { "shift" } }, ["?"] = { keycode = 53, mods = { "shift" } },
	A = { keycode = 30, mods = { "shift" } }, B = { keycode = 48, mods = { "shift" } },
	J = { keycode = 36, mods = { "shift" } }, Q = { keycode = 16, mods = { "shift" } },
}

local function us_plan(text)
	local steps = {}
	for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		if not US_PLAN[char] then return nil end
		steps[#steps + 1] = US_PLAN[char]
	end
	return steps
end

-- What the one-shot Shift types instead of a capital, as the shared table has
-- it, with ★ as the magic key.
local RESULTS = { [" "] = "-", ["."] = " :", [","] = " ;", ["="] = "º", ["★"] = "J" }

local function one_shot_result(char) return RESULTS[char] end

--- An engine on `keys` (the defaults) reading the layout through `key_text`
--- and `plan_text`.
local function engine(keys, key_text, plan_text)
	local nav = require("tests.support.nav_layer_fixture").recommended()
	return Engine.new({ keys = keys or DEFAULTS, tap_min_ms = 50, one_shot_timeout_ms = 2000,
		nav_layer = nav,
		key_text = key_text or us_text, plan_text = plan_text or us_plan, one_shot_result = one_shot_result })
end

-- The random session also runs a Tab tap-hold and a Ctrl nobody configured.
DEFAULTS.tab = { tap_action = "alt_tab_monitor", hold_modifier = "alt", time_activation_seconds = 0.2 }

--- "42↓ 30↑" for a list of events.
local function trail(events)
	local parts = {}
	for _, ev in ipairs(events or {}) do
		parts[#parts + 1] = ev.code .. (ev.value == DOWN and "↓" or ev.value == UP and "↑" or "⟳")
	end
	return table.concat(parts, " ")
end

return {
	helpers = helpers,
	Engine = Engine,
	DOWN = DOWN,
	UP = UP,
	REPEAT = REPEAT,
	SHIFT = SHIFT,
	CTRL = CTRL,
	ALT = ALT,
	CAPS = CAPS,
	ENTER = ENTER,
	BACKSPACE = BACKSPACE,
	KEY_A = KEY_A,
	KEY_J = KEY_J,
	KEY_LEFT = KEY_LEFT,
	RCTRL = RCTRL,
	DEFAULTS = DEFAULTS,
	US_TEXT = US_TEXT,
	us_text = us_text,
	US_PLAN = US_PLAN,
	us_plan = us_plan,
	RESULTS = RESULTS,
	one_shot_result = one_shot_result,
	engine = engine,
	trail = trail,
}
