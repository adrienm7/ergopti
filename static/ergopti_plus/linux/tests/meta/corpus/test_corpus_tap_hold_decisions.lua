--- tests/meta/corpus/test_corpus_tap_hold_decisions.lua

--- ==============================================================================
--- MODULE: Tap-Hold Decision Corpus Replay (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/tap_hold/decision_vectors.json through the
--- production engine (platform/remap/tap_hold_engine) with the shipped typing
--- keys of [tap_hold.rollover], the shared tap minimum and one-shot timeout,
--- and the keyboard hook's order of calls: M:tick at each event's time, then
--- M:process. What comes out, and every event the engine passes through, is
--- read as the keystrokes an application receives.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Catalog = require("tap_hold.key_catalog")
local Timings = require("infra.timings")
local EvdevCodes = require("infra.evdev_codes")
local Engine = require("platform.remap.tap_hold_engine")
local Fixture = require("tests.support.platform.remap.tap_hold.tap_hold_engine_fixture")
local Contract = require("test.tap_hold_decision_contract")

local SHARED = helpers.driver_root() .. "/../_shared"
local DOWN, UP = 1, 0

-- The ordinary keys the corpus strikes, by kernel code (input-event-codes.h).
local LETTER_CODES = { a = 30, j = 36 }

-- The hold-picker name of each modifier role infra/evdev_codes gives a key.
local PICKER_MODIFIER_OF_ROLE = { ctrl = "ctrl", shift = "shift", alt = "alt", altgr = "alt_gr", meta = "win" }

-- The side-specific name of each modifier key, for `hold_presses`.
local SIDED_MODIFIER_OF_CODE = {
	[EvdevCodes.KEY_LEFTCTRL] = "left_ctrl", [EvdevCodes.KEY_RIGHTCTRL] = "right_ctrl",
	[EvdevCodes.KEY_LEFTSHIFT] = "left_shift", [EvdevCodes.KEY_RIGHTSHIFT] = "right_shift",
	[EvdevCodes.KEY_LEFTALT] = "left_alt", [EvdevCodes.KEY_RIGHTALT] = "right_alt",
	[EvdevCodes.KEY_LEFTMETA] = "left_win", [EvdevCodes.KEY_RIGHTMETA] = "right_win",
}

--- Reads one shared file whole.
--- @param path string
--- @return string
local function read(path)
	local handle = assert(io.open(path, "r"), "cannot open " .. path)
	local text = handle:read("*a")
	handle:close()
	return text
end

local defaults = require("toml_codec").decode(read(SHARED .. "/tap_hold/defaults.toml"))
local corpus = Json.decode(read(SHARED .. "/tests/corpus/tap_hold/decision_vectors.json"))

-- Catalogue id -> this driver's key id and evdev code, through its own column.
local ID_OF_KEY, CODE_OF_KEY, KEY_OF_CODE = {}, {}, {}
for _, entry in ipairs(Catalog.for_platform(defaults, "linux")) do
	ID_OF_KEY[entry.key] = entry.id
	CODE_OF_KEY[entry.key] = assert(Engine.KEY_CODES[entry.id], "the engine has no code for '" .. entry.id .. "'")
end
for key, code in pairs(LETTER_CODES) do CODE_OF_KEY[key] = code end
for key, code in pairs(CODE_OF_KEY) do
	if not EvdevCodes.MODIFIER_OF[code] then KEY_OF_CODE[code] = key end
end

local ROLL_KEYS = {}
for id in pairs(Catalog.rollover_for_platform(defaults, "linux")) do ROLL_KEYS[#ROLL_KEYS + 1] = id end
table.sort(ROLL_KEYS)

--- The engine configuration of one corpus binding.
--- @param binding table { tap, hold, threshold_ms }.
--- @return table
local function key_config(binding)
	return {
		tap_action = binding.tap or "",
		hold_modifier = binding.hold,
		time_activation_seconds = binding.threshold_ms / 1000,
	}
end

--- Replays one vector and reads what applications receive.
--- @param vector table
--- @return table { strokes, hold_presses }
local function replay(vector)
	local keys, first_bound = {}, nil
	for key, binding in pairs(vector.bindings) do
		local id = assert(ID_OF_KEY[key], vector.id .. ": '" .. key .. "' is no Linux tap-hold key")
		keys[id] = key_config(binding)
	end
	for _, event in ipairs(vector.events) do
		if event[1] == "down" and vector.bindings[event[2]] then first_bound = event[2]; break end
	end
	local engine = Engine.new({
		keys = keys,
		roll_keys = ROLL_KEYS,
		tap_min_ms = Timings.ms("tap_hold", "tap_min_duration_ms"),
		one_shot_timeout_ms = Timings.ms("tap_hold", "one_shot_shift_timeout_ms"),
		key_text = Fixture.us_text,
		plan_text = Fixture.us_plan,
		one_shot_result = Fixture.one_shot_result,
	})
	local mods_down, strokes, hold_presses = {}, {}, {}

	--- Reads one event an application receives.
	local function receive(row, from_bound_press)
		helpers.assert_true(row.tap == nil, vector.id .. ": an action tap '" .. tostring(row.tap)
			.. "' is not a keystroke; the corpus taps keys only")
		local role = EvdevCodes.MODIFIER_OF[row.code]
		if role then
			if row.value == DOWN then
				mods_down[row.code] = true
				if from_bound_press then hold_presses[#hold_presses + 1] = SIDED_MODIFIER_OF_CODE[row.code] end
			elseif row.value == UP then
				mods_down[row.code] = nil
			end
			return
		end
		if row.value ~= DOWN then return end
		local held = {}
		for code in pairs(mods_down) do held[PICKER_MODIFIER_OF_ROLE[EvdevCodes.MODIFIER_OF[code]]] = true end
		strokes[#strokes + 1] = {
			key = assert(KEY_OF_CODE[row.code], vector.id .. ": unnamed key " .. tostring(row.code)),
			mods = held,
		}
	end

	for _, event in ipairs(vector.events) do
		local code = assert(CODE_OF_KEY[event[2]], vector.id .. ": unknown key '" .. event[2] .. "'")
		local value = event[1] == "down" and DOWN or UP
		for _, row in ipairs(engine:tick(event[3])) do receive(row, false) end
		local out, tap = engine:process(code, value, event[3])
		helpers.assert_nil(tap, vector.id .. ": an action tap is not a keystroke; the corpus taps keys only")
		local own_press = value == DOWN and event[2] == first_bound and #hold_presses == 0
		if out == nil then
			receive({ code = code, value = value }, false)
		else
			for _, row in ipairs(out) do receive(row, own_press) end
		end
	end
	return { strokes = strokes, hold_presses = hold_presses }
end

Contract.run(helpers, "linux", corpus, defaults.tap_hold.hold_picker, replay)
