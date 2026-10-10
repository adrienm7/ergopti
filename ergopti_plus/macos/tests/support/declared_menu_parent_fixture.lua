--- tests/support/declared_menu_parent_fixture.lua

--- ==============================================================================
--- MODULE: Declared Menu Parent Fixture
--- DESCRIPTION:
--- Gives explicit positive native-child capture fixtures their actual shared
--- parent owner. Missing-owner and withdrawn-source scenarios keep their own
--- renderer and are never enrolled through an automatic facade repair.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}

--- Binds the genuine canonical parent owner for one positive capture fixture.
--- @return table renderer Actual shared renderer with independent source custody.
function M.new()
	return assert(require("menu.renderer").new({
		platform = "hs",
		manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
		json_decode = require("json").decode,
		i18n = require("infra.i18n"), logger = helpers.make_logger_stub(),
	}))
end

return M
