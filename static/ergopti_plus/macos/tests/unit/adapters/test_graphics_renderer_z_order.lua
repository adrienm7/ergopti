--- tests/unit/adapters/test_graphics_renderer_z_order.lua

--- ==============================================================================
--- MODULE: Graphics renderer z-order regression tests (HS-056)
--- DESCRIPTION:
--- Verifies that createWindow() maps the alwaysOnTop option to the native canvas
--- levels without transiently assigning the opposite level first.
--- ==============================================================================

local helpers = require("tests.helpers")

local FLOATING_LEVEL = 10
local OVERLAY_LEVEL = 20

local function load_fixture()
	local canvases = {}
	local canvas_port = {
		windowBehaviors = { canJoinAllSpaces = 1 },
		windowLevels = {
			floating = FLOATING_LEVEL,
			overlay = OVERLAY_LEVEL,
		},
	}

	function canvas_port.new()
		local canvas = { level_calls = {} }

		function canvas:behavior()
			return self
		end

		function canvas:level(level)
			self.level_calls[#self.level_calls + 1] = level
			self.final_level = level
			return self
		end

		function canvas:ignoresMouseEvents()
			return self
		end

		function canvas:delete() end

		canvases[#canvases + 1] = canvas
		return canvas
	end

	local adapter = helpers.load_with_stubs("adapters.graphics_renderer", {
		canvas = canvas_port,
	})
	return adapter, canvases
end

helpers.describe("GraphicsRenderer z-order", function()
	helpers.it("maps alwaysOnTop to the intended native level", function()
		helpers.assert_true(FLOATING_LEVEL < OVERLAY_LEVEL,
			"the fixture must model overlay above floating")

		local cases = {
			{ label = "omitted", opts = {}, expected = OVERLAY_LEVEL },
			{ label = "true", opts = { alwaysOnTop = true }, expected = OVERLAY_LEVEL },
			{ label = "false", opts = { alwaysOnTop = false }, expected = FLOATING_LEVEL },
		}

		for _, case in ipairs(cases) do
			local adapter, canvases = load_fixture()
			local handle = adapter.createWindow(case.opts)
			helpers.assert_true(handle ~= nil and handle ~= 0,
				case.label .. ": createWindow must return a native handle")
			helpers.assert_eq(#canvases[1].level_calls, 1,
				case.label .. ": createWindow must assign exactly one native level")
			helpers.assert_eq(canvases[1].final_level, case.expected,
				case.label .. ": alwaysOnTop must select the intended native level")
		end
	end)
end)

return helpers
