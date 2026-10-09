--- tests/support/keyboard_geometry.lua

--- ==============================================================================
--- MODULE: Keyboard Geometry Fixture
--- DESCRIPTION:
--- Supplies an explicit native-map double to an already owned fresh adapter.
--- This fixture models ANSI, ISO and JIS; it does not classify real hardware.
--- ==============================================================================

local M = {}

--- Initializes the supplied fresh owner and restores the environment reader.
--- @param geometry table Fresh production keyboard geometry adapter.
function M.initialize(geometry)
	local getenv = os.getenv
	os.getenv = function(key)
		if key ~= "ERGOPTI_KEYBOARD_GEOMETRY_V1" then return getenv(key) end
		return require("json").encode({ version = 1, maximum = 32767, ranges = {
			{ first = 0, last = 40, form = "ansi" },
			{ first = 41, last = 41, form = "iso" },
			{ first = 42, last = 42, form = "jis" },
			{ first = 43, last = 32767, form = "unknown" },
		} })
	end
	local called, result = pcall(geometry.initialize)
	os.getenv = getenv
	assert(called and result, tostring(result))
end

return M
