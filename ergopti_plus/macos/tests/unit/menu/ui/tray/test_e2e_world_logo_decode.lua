--- tests/unit/menu/ui/tray/test_e2e_world_logo_decode.lua

--- ==============================================================================
--- MODULE: Regression — the E2E Mac decodes the shipped menu-bar logo
--- DESCRIPTION:
--- The installed-application boot scenarios booted on the shared hs stub,
--- whose hs.image.imageFromPath answers nil for every path. Once the menu bar
--- logged an undecodable logo (TRAY-05), every boot scenario logged an ERROR
--- for the logo the bundle does ship. The world decodes a PNG as NSImage does
--- and still refuses a missing, foreign or truncated file.
--- ==============================================================================

local helpers = require("tests.helpers")
local World = require("tests.e2e.boot.world")

local LOGO_DIR = helpers.driver_root() .. "../../img/logo/"

--- Writes bytes to a fresh temporary file.
--- @param bytes string
--- @return string path
local function scratch_file(bytes)
	local path = os.tmpname()
	local file = assert(io.open(path, "wb"))
	file:write(bytes)
	file:close()
	return path
end




-- ==================================
-- ==================================
-- ======= 1/ Decoding ==============
-- ==================================
-- ==================================

helpers.describe("E2E machine: hs.image decodes the shipped logos (tray-05)", function()

	helpers.it("decodes every shipped menu-bar logo at its PNG size", function()
		for _, name in ipairs({ "logo_simple.png", "logo_simple_disabled.png" }) do
			local image = World.image_from_path(LOGO_DIR .. name)
			helpers.assert_true(image ~= nil, name .. " must decode")
			local size = image:size()
			helpers.assert_true(size.w > 0 and size.h > 0, name .. " must carry its IHDR size")
		end
	end)

	helpers.it("resizes an image the way NSImage's setSize does", function()
		local image = World.image_from_path(LOGO_DIR .. "logo_simple.png")
		image:setSize({ w = 19, h = 19 })
		helpers.assert_eq(image:size(), { w = 19, h = 19 })
	end)

	helpers.it("answers nil for a missing, foreign or truncated file", function()
		helpers.assert_nil(World.image_from_path(LOGO_DIR .. "no_such_logo.png"))
		helpers.assert_nil(World.image_from_path(nil))
		local foreign = scratch_file("<svg xmlns='http://www.w3.org/2000/svg'></svg>")
		local truncated = scratch_file("\137PNG\r\n\26\n\0\0\0\13IHDR")
		helpers.assert_nil(World.image_from_path(foreign))
		helpers.assert_nil(World.image_from_path(truncated))
		os.remove(foreign)
		os.remove(truncated)
	end)
end)
