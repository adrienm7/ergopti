--- macos/tests/unit/modules/gestures/engine/test_gesture_direction_vectors.lua

--- ==============================================================================
--- MODULE: Gesture Direction Vectors (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/gestures/direction_vectors.json through the
--- geometry the engine commits with (computeDir, then slotForDir). Most diagonal
--- and five-finger slots were named by no test, so a direction that resolved to
--- an undeclared slot would bind silently to nothing.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local function read(relative)
	local handle = assert(io.open(helpers.shared(relative), "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

helpers.describe("gesture direction vectors (macOS)", function()
	local Geometry = require("modules.gestures.geometry")
	local corpus = assert(Json.decode_lossless(read("tests/corpus/gestures/direction_vectors.json")))
	local actions = read("modules/actions/actions.toml")
	local scale = { swipe = 4 * Geometry.SWIPE_MIN, short = Geometry.SWIPE_MIN / 4 }

	for _, fingers in ipairs(corpus.fingers) do
		for _, vector in ipairs(corpus.vectors) do
			local expected = not Json.is_null(vector.direction)
				and string.format("swipe_%d_%s", fingers, vector.direction) or nil
			helpers.it(string.format("%d fingers, %d degrees, %s travel -> %s",
				fingers, vector.angle, vector.travel, tostring(expected)), function()
				local radians = math.rad(vector.angle)
				local dx = math.cos(radians) * scale[vector.travel]
				local dy = math.sin(radians) * scale[vector.travel]
				local direction = Geometry.computeDir(dx, dy, fingers)
				local slot = direction and Geometry.slotForDir(fingers, direction, dx, dy) or nil
				helpers.assert_eq(slot, expected)
				if expected then
					helpers.assert_true(actions:find(expected .. "%f[^%w_]") ~= nil,
						expected .. " is declared in actions.toml")
				end
			end)
		end
	end
end)
