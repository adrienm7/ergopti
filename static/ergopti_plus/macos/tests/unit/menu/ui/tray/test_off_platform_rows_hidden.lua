--- tests/unit/menu/ui/tray/test_off_platform_rows_hidden.lua

--- ==============================================================================
--- MODULE: Off-Platform Rows Are Hidden On macOS, Unless Declared Greyed
--- DESCRIPTION:
--- The macOS tray showed the rows other drivers have as greyed stand-ins with a
--- long explanation: "… — Linux only" rows, and the Windows registry options
--- under Gestures. They made the tray very wide and none of them could be used.
--- Renders every menu of the real shared manifest for hs and fails on any row
--- whose title carries a `platform_reason.*` text, except the stand-in of a row
--- declared `unavailable = "grey"` (not yet ported here, the maintainer's rule
--- of 2026-09-30). No such row is left for macOS: the tap-hold word reset, the
--- emulated-rows submenu and, last, the Shortcuts restore and clear
--- (2026-11-20) are all live here, so the greyed count is zero and a row that
--- comes back greyed fails. The fixture cases for every row shape, the greyed
--- stand-in included, live in the Linux suite, which runs the same shared
--- renderer.
--- ==============================================================================

local helpers = require("tests.helpers")
local leaks   = require("tests.lua.menu.off_platform")

local PLATFORM      = "hs"
local MANIFEST_PATH = "../_shared/menu/data/menu_manifest.json"


helpers.describe("menu: no off-platform explanation is rendered on macOS", function()

	helpers.it("the real manifest has rows the old renderer showed greyed on macOS", function()
		local fh = assert(io.open(MANIFEST_PATH, "r"))
		local root = require("core.text.engine.json").decode(fh:read("*a"))
		fh:close()
		helpers.assert_true(leaks.explained_off_platform_count(root, PLATFORM) > 0,
			"without such rows the check below cannot fail and proves nothing")
	end)

	helpers.it("renders every manifest menu for macOS without a platform_reason text", function()
		package.loaded["menu.engine.renderer"] = nil
		local found, rendered, greyed = leaks.reason_leaks(require("menu.engine.renderer"), {
			platform      = PLATFORM,
			manifest_path = MANIFEST_PATH,
			json_decode   = require("core.text.engine.json").decode,
			logger        = helpers.make_logger_stub(),
		})
		helpers.assert_true(rendered > 10, "every menu of the shared manifest must render, got " .. rendered)
		helpers.assert_eq(found, {}, "a row another platform has must not reach the macOS tray")
		-- The tap-hold word reset is live on macOS since its Karabiner marker, the
		-- emulated-rows submenu since the macOS emulation (2026-11-06), and the
		-- Shortcuts restore and clear since their composed scope (2026-11-20).
		helpers.assert_eq(greyed, 0, "no row is drawn greyed as not yet ported on macOS")
	end)

end)
