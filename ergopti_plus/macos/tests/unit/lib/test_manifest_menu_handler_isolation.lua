--- tests/unit/lib/test_manifest_menu_handler_isolation.lua

--- ==============================================================================
--- MODULE: Regression — ManifestMenu.build handler dispatch has no pcall isolation (F-HIGH-18)
--- DESCRIPTION:
--- dynamic_handlers[id](...) and group_builders[id](...) were bare, unguarded
--- calls inside ManifestMenu.build's dispatch loop. A throw inside ANY single
--- manifest-driven handler unwound straight out of M.build — the single outer
--- pcall in the caller's rebuild_menu_cache() then caught it at the granularity
--- of the WHOLE menu tree, so one broken component took down the entire menu
--- instead of just its own item.
---
--- Fix: wrap each dispatch call (action, dynamic, group) with pcall +
--- Logger.error(manifest_key.id, err), matching the menu system's existing
--- per-component isolation pattern (Logger.build / push_into in ui/menu/builder.lua).
---
--- This test drives M.build with a manifest array containing one THROWING
--- handler and one GOOD handler, and asserts the good handler's item still
--- appears in the built result — it fails before the fix (the throw propagates
--- out of M.build and no items are ever returned) and passes after.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.manifest_menu_fixture")

local MANIFEST = [[
{
	"test_menu": [
		{ "type": "dynamic", "id": "throwing_handler" },
		{ "type": "dynamic", "id": "good_handler" }
	]
}
]]


helpers.describe("ManifestMenu.build: dispatch isolates each handler under pcall (F-HIGH-18)", function()
	helpers.it("a throwing dynamic handler does not prevent a sibling good handler's item from appearing", function()
		fixture.with_manifest(MANIFEST, nil, function(ManifestMenu)

			local dyn_handlers = {
				throwing_handler = function(_items, _ctx)
					error("boom — simulated handler crash")
				end,
				good_handler = function(items, _ctx)
					table.insert(items, { title = "good_item" })
				end,
			}

			local ok_call, built = pcall(ManifestMenu.build, "test_menu", "Test", dyn_handlers, nil, {})

			helpers.assert_true(ok_call,
				"M.build itself must never raise — a throwing handler must be isolated by an internal pcall (F-HIGH-18)")
			-- Isolation means the OTHER rows still render. A build that contained the
			-- exception by returning nothing would pass the check above and leave the
			-- user with an empty menu and no error.
			helpers.assert_eq(type(built), "table",
				"and must still return the rows the throwing handler did not own")

			local found_good = false
			for _, item in ipairs(built or {}) do
				if item.title == "good_item" then found_good = true end
			end
			helpers.assert_true(found_good,
				"the good_handler's item must still be present after a sibling handler threw — " ..
				"one broken manifest entry must not take down the whole menu tree (F-HIGH-18)")
		end)
	end)
end)
