--- tests/meta/test_vscode_bridge_lifecycle_wired.lua

--- ==============================================================================
--- MODULE: Retired VS Code Bridge Ownership
--- DESCRIPTION:
--- Retirement removes activation and keeps cleanup of already loaded owners.
--- The tooltip continues to use its existing standard caret and window locator.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.tooltip_renderer_fixture")

helpers.describe("retired VS Code bridge", function()
	helpers.it("never activates a retired bridge but preserves loaded-owner shutdown", function()
		local source = helpers.read_driver_source("local function has_common_hotstring_groups")
		helpers.assert_type(source, "string")
		helpers.assert_true(#source > 0, "the real startup source must be present")
		helpers.assert_nil(source:find('require("infra.vscode_bridge").setup()', 1, true))
		local owner = source:match('name = "vscode%-bridge"([%s%S]-)name = "llm%-helper%-processes"')
		helpers.assert_type(owner, "string")
		helpers.assert_true(owner:find('package.loaded["infra.vscode_bridge"]', 1, true) ~= nil)
		helpers.assert_true(owner:find("return module.stop_server()", 1, true) ~= nil)
		helpers.assert_true(owner:find("module == nil then return true", 1, true) ~= nil)
	end)
end)

Fixture.it("tooltip uses the standard caret locator without the retired bridge", function()
	helpers.with_stub_scope({ "hs.axuielement" }, function()
		local legacy_calls = 0
		package.loaded["infra.vscode_bridge"] = {
			is_vscode = function() legacy_calls = legacy_calls + 1; return true end,
			estimate_position = function() return { x = 999, y = 999, h = 20, type = "retired" } end,
		}
		local renderer = Fixture.load()
		local selected = { location = 4, length = 3 }
		local element = {
			attributeValue = function(_, name)
				if name == "AXSelectedTextRange" then return selected end
			end,
			parameterizedAttributeValue = function(_, name, range)
				helpers.assert_eq(name, "AXBoundsForRange")
				helpers.assert_eq(range.location, 4)
				helpers.assert_eq(range.length, 0)
				return { x = 120, y = 140, h = 20 }
			end,
		}
		package.loaded["hs.axuielement"] = { systemWideElement = function()
			return { attributeValue = function() return element end }
		end }
		local position = renderer.resolve_anchor()
		helpers.assert_eq(position.x, 120)
		helpers.assert_eq(position.y, 140)
		helpers.assert_eq(position.type, "caret")
		helpers.assert_eq(legacy_calls, 0, "a cached retired owner cannot replace the standard locator")
		package.loaded["hs.axuielement"] = { systemWideElement = function() error("controlled AX refusal") end }
		hs.window.focusedWindow = function() return { frame = function() return { x = 10, y = 20, w = 80, h = 60 } end } end
		position = renderer.resolve_anchor()
		helpers.assert_eq(position.type, "window")
		helpers.assert_eq(position.x, 50)
		hs.window.focusedWindow = function() return nil end
		helpers.assert_nil(renderer.resolve_anchor(), "unavailable standard geometry remains refused")
	end)
end)
