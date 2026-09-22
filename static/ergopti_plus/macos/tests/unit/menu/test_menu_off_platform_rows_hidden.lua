--- tests/unit/menu/test_menu_off_platform_rows_hidden.lua

--- ==============================================================================
--- MODULE: Off-Platform Rows Are Hidden On macOS
--- DESCRIPTION:
--- The macOS tray showed the rows other drivers have as greyed stand-ins with a
--- long explanation: "… — Linux only" rows, and the Windows registry options
--- under Gestures. They made the tray very wide and none of them could be used.
--- Renders every menu of the real shared manifest for hs and fails on any row
--- whose title carries a `platform_reason.*` text. The fixture cases for every
--- row shape live in the Linux suite, which runs the same shared renderer.
--- ==============================================================================

local helpers = require("tests.helpers")
local leaks   = require("test.menu_off_platform")

local PLATFORM      = "hs"
local MANIFEST_PATH = "../_shared/modules/menu/menu_manifest.json"


helpers.describe("menu: no off-platform explanation is rendered on macOS", function()

	helpers.it("the real manifest has rows the old renderer showed greyed on macOS", function()
		local fh = assert(io.open(MANIFEST_PATH, "r"))
		local root = require("json").decode(fh:read("*a"))
		fh:close()
		helpers.assert_true(leaks.explained_off_platform_count(root, PLATFORM) > 0,
			"without such rows the check below cannot fail and proves nothing")
	end)

	helpers.it("renders every manifest menu for macOS without a platform_reason text", function()
		package.loaded["menu.renderer"] = nil
		local found, rendered = leaks.reason_leaks(require("menu.renderer"), {
			platform      = PLATFORM,
			manifest_path = MANIFEST_PATH,
			json_decode   = require("json").decode,
			logger        = helpers.make_logger_stub(),
		})
		helpers.assert_true(rendered > 10, "every menu of the shared manifest must render, got " .. rendered)
		helpers.assert_eq(found, {}, "a row another platform has must not reach the macOS tray")
	end)

end)
