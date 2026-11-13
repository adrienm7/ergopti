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
	return assert(require("menu.engine.renderer").new({
		platform = "hs",
		manifest_path = function() return helpers.shared("menu/data/menu_manifest.json") end,
		json_decode = require("core.text.engine.json").decode,
		i18n = require("core.i18n.engine.i18n"), logger = helpers.make_logger_stub(),
	}))
end

--- Builds a renderer stub around a scenario's own `build`, keeping the actual
--- parent owner and declared templates (the Shortcuts menu draws its ChatGPT
--- editor frame on every build, whatever the scenario's build returns).
--- @param build function The scenario's manifest build.
--- @return table stub { group_receiver, template_rows, build }.
function M.stub(build)
	local parent = M.new()
	return { group_receiver = parent.group_receiver, template_rows = parent.template_rows, build = build }
end

return M
