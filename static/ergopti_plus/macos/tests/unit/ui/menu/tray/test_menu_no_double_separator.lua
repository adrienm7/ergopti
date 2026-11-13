--- tests/unit/ui/menu/tray/test_menu_no_double_separator.lua

--- ==============================================================================
--- MODULE: No Doubled Separator In Any Menu
--- DESCRIPTION:
--- Renders every menu of the shared manifest for macOS and fails on any separator
--- that does not sit between two real rows: two in a row, or one at either end.
---
--- The Windows tray showed two lines in a row under « Disposition »: a row the
--- driver supplied brought its own separator next to a manifest `---`. The
--- shared renderer now normalises its output, and the probes in
--- test.menu_separators return a separator on both sides of every driver row, the
--- worst case any provider can produce. The first level of the tray is built by
--- the driver from `top_level`, so its declaration is checked on its own. The
--- same render checks that every section header titles real rows.
--- ==============================================================================

local helpers = require("tests.helpers")
local check   = require("tests.lua.menu.separators")

local PLATFORM      = "hs"
local MANIFEST_PATH = "../_shared/menu/data/menu_manifest.json"


helpers.describe("menu: no separator doubles up on macOS", function()

	helpers.it("renders every manifest menu without a misplaced separator", function()
		package.loaded["menu.engine.renderer"] = nil
		local defects, rendered = check.render_every_menu(require("menu.engine.renderer"), {
			platform      = PLATFORM,
			manifest_path = MANIFEST_PATH,
			json_decode   = require("core.text.engine.json").decode,
			logger        = helpers.make_logger_stub(),
		})
		helpers.assert_true(rendered > 10, "every menu of the shared manifest must render, got " .. rendered)
		helpers.assert_eq(defects, {}, "a separator must sit between two real rows")
	end)

	-- A section header titles the rows under it: never a separator, another
	-- header or the end of its menu right after it (test.menu_section_headers).
	helpers.it("renders every manifest menu with each section header over real rows", function()
		package.loaded["menu.engine.renderer"] = nil
		local defects, rendered, headers = require("tests.lua.menu.section_headers").render_every_menu(
			require("menu.engine.renderer"), {
				platform      = PLATFORM,
				manifest_path = MANIFEST_PATH,
				json_decode   = require("core.text.engine.json").decode,
				logger        = helpers.make_logger_stub(),
			})
		helpers.assert_true(rendered > 10, "every menu of the shared manifest must render, got " .. rendered)
		helpers.assert_true(headers > 10, "the section headers must be drawn by the shared format, got " .. headers)
		helpers.assert_eq(defects, {}, "a section header must title real rows")
	end)

	helpers.it("declares the first level of the tray without a misplaced separator", function()
		local fh = assert(io.open(MANIFEST_PATH, "r"))
		local root = require("core.text.engine.json").decode(fh:read("*a"))
		fh:close()
		helpers.assert_eq(check.top_level_defects(root, PLATFORM), {},
			"top_level must not put two separators in a row once other platforms' rows are dropped")
	end)

end)
