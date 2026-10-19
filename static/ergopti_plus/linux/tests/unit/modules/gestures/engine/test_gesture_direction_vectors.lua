--- tests/unit/modules/gestures/engine/test_gesture_direction_vectors.lua

--- ==============================================================================
--- MODULE: Gesture Direction Vectors (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/gestures/direction_vectors.json through the
--- actual evdev decoder: N fingers land one at a time, travel along the vector's
--- angle and lift. Linux had no test for several shipped slots, among them
--- swipe_3_down, so a direction that resolved to an undeclared slot would bind
--- silently to nothing.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local Decoder = helpers.load_module("modules.gestures.mt_decoder")

local EV_SYN, EV_KEY, EV_ABS = Decoder.EV_SYN, Decoder.EV_KEY, Decoder.EV_ABS
local BTN_TOOL = { [1] = 0x145, [2] = 0x14d, [3] = 0x14e, [4] = 0x14f, [5] = 0x148 }

local function read(relative)
	local handle = assert(io.open(require("infra.paths").shared(relative), "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Feeds one whole gesture and returns what the decoder completed.
--- @param fingers integer
--- @param dx integer
--- @param dy integer
--- @return table|nil
local function decode(fingers, dx, dy)
	local decoder, last = Decoder.new(), nil
	local function push(t, c, v)
		local out = decoder:feed({ type = t, code = c, value = v })
		if out then last = out end
	end
	for index = 0, fingers - 1 do
		push(EV_ABS, Decoder.ABS_MT_SLOT, index)
		push(EV_ABS, Decoder.ABS_MT_TRACKING_ID, 500 + index)
		push(EV_ABS, Decoder.ABS_MT_POSITION_X, 2000 + index * 200)
		push(EV_ABS, Decoder.ABS_MT_POSITION_Y, 2000)
		if index > 0 then push(EV_KEY, BTN_TOOL[index], 0) end
		push(EV_KEY, BTN_TOOL[index + 1], 1)
		if index == 0 then push(EV_KEY, Decoder.BTN_TOUCH, 1) end
		push(EV_SYN, Decoder.SYN_REPORT, 0)
	end
	for step = 1, 4 do
		for index = 0, fingers - 1 do
			push(EV_ABS, Decoder.ABS_MT_SLOT, index)
			push(EV_ABS, Decoder.ABS_MT_POSITION_X, 2000 + index * 200 + math.floor(dx * step / 4))
			push(EV_ABS, Decoder.ABS_MT_POSITION_Y, 2000 + math.floor(dy * step / 4))
		end
		push(EV_SYN, Decoder.SYN_REPORT, 0)
	end
	for index = fingers - 1, 0, -1 do
		push(EV_ABS, Decoder.ABS_MT_SLOT, index)
		push(EV_ABS, Decoder.ABS_MT_TRACKING_ID, -1)
		push(EV_KEY, BTN_TOOL[index + 1], 0)
		if index > 0 then push(EV_KEY, BTN_TOOL[index], 1) end
		push(EV_SYN, Decoder.SYN_REPORT, 0)
	end
	push(EV_KEY, Decoder.BTN_TOUCH, 0)
	push(EV_SYN, Decoder.SYN_REPORT, 0)
	return last
end

helpers.describe("gesture direction vectors (Linux)", function()
	local corpus = assert(Json.decode_lossless(read("tests/corpus/gestures/direction_vectors.json")))
	local actions = read("modules/actions/actions.toml")
	local threshold = Decoder.DEFAULT_SWIPE_THRESHOLD
	local scale = { swipe = 4 * threshold, short = threshold / 4 }

	for _, fingers in ipairs(corpus.fingers) do
		for _, vector in ipairs(corpus.vectors) do
			local expected = not Json.is_null(vector.direction)
				and string.format("swipe_%d_%s", fingers, vector.direction) or nil
			helpers.it(string.format("%d fingers, %d degrees, %s travel -> %s",
				fingers, vector.angle, vector.travel, tostring(expected)), function()
				local radians = math.rad(vector.angle)
				local out = decode(fingers, math.floor(math.cos(radians) * scale[vector.travel] + 0.5),
					math.floor(math.sin(radians) * scale[vector.travel] + 0.5))
				helpers.assert_true(out ~= nil, "the gesture completes when the last finger lifts")
				helpers.assert_eq(out.fingers, fingers)
				local slot = out.direction and string.format("swipe_%d_%s", out.fingers, out.direction) or nil
				helpers.assert_eq(slot, expected)
				if expected then
					helpers.assert_true(actions:find(expected .. "%f[^%w_]") ~= nil,
						expected .. " is declared in actions.toml")
				end
			end)
		end
	end
end)
