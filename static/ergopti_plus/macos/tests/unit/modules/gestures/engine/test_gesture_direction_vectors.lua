--- macos/tests/unit/modules/gestures/engine/test_gesture_direction_vectors.lua

--- ==============================================================================
--- MODULE: Gesture Direction Vectors (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/gestures/direction_vectors.json through the
--- geometry the engine commits with (computeDir, then slotForDir). Most diagonal
--- and five-finger slots were named by no test, so a direction that resolved to
--- an undeclared slot would bind silently to nothing.
---
--- The boundary vectors pin the shared classifier both drivers use
--- (_shared/lua/gestures/direction.lua) at its sector edges and its two
--- Manhattan minimums. macOS once put the diagonal boundary at 25 degrees and
--- Linux at a 2:1 ratio (26.6 degrees), with a different travel gate, so the
--- same swipe could name another slot on each.
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

	local Direction = require("gestures.direction")
	local rule = corpus.boundary_rule
	helpers.it("the boundary rule is the three-finger tuning in normalised units", function()
		helpers.assert_true(#corpus.boundary_vectors >= 12, "boundary vectors")
		helpers.assert_eq(rule.minimum, 1)
		helpers.assert_eq(rule.diagonal_minimum, Direction.DIAGONAL_MINIMUM_FACTOR)
	end)

	for _, vector in ipairs(corpus.boundary_vectors) do
		local expected = not Json.is_null(vector.direction) and vector.direction or nil
		helpers.it("boundary vector '" .. vector.id .. "' -> " .. tostring(expected), function()
			helpers.assert_eq(Direction.classify(vector.dx, vector.dy, rule.minimum, rule.diagonal_minimum),
				expected, vector.id .. ": shared classifier")
			for _, fingers in ipairs(corpus.fingers) do
				local dx, dy = vector.dx * Geometry.SWIPE_MIN, vector.dy * Geometry.SWIPE_MIN
				local axis = Geometry.computeDir(dx, dy, fingers)
				local slot = axis and Geometry.slotForDir(fingers, axis, dx, dy) or nil
				helpers.assert_eq(slot, expected and string.format("swipe_%d_%s", fingers, expected) or nil,
					string.format("%s: macOS geometry with %d fingers", vector.id, fingers))
			end
		end)
	end
end)
