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

--- Installs a fake get_menu_def by stubbing lib.paths.shared to point at a
--- temp fixture-less manifest key — instead we directly monkeypatch the
--- module's cached manifest root via M.invalidate_cache + a stub JSON file.
--- Simpler: write a throwaway manifest fixture with a "test_menu" array and
--- point lib.paths at its directory.
--- @return string tmp_dir Absolute path of the fixture directory created.
local function write_fixture_manifest()
	local tmp_dir = os.tmpname()
	os.remove(tmp_dir) -- os.tmpname() creates a file; we want a directory
	local ok_mkdir = os.execute('mkdir "' .. tmp_dir .. '"')
	helpers.assert_true(ok_mkdir and true or ok_mkdir == 0, "could not create fixture tmp dir")

	local manifest_dir = tmp_dir .. "/modules/menu"
	os.execute('mkdir "' .. tmp_dir .. '/modules" "' .. manifest_dir .. '"')

	local fh = io.open(manifest_dir .. "/menu_manifest.json", "w")
	helpers.assert_true(fh ~= nil, "could not create fixture menu_manifest.json")
	fh:write([[
{
	"test_menu": [
		{ "type": "dynamic", "id": "throwing_handler" },
		{ "type": "dynamic", "id": "good_handler" }
	]
}
]])
	fh:close()

	return tmp_dir
end

helpers.describe("ManifestMenu.build: dispatch isolates each handler under pcall (F-HIGH-18)", function()
	helpers.it("a throwing dynamic handler does not prevent a sibling good handler's item from appearing", function()
		local ManifestMenu = helpers.load_with_stubs("infra.manifest_menu")

		local tmp_dir = write_fixture_manifest()
		package.loaded["infra.paths"].shared = function(rel)
			if rel and rel ~= "" then return tmp_dir .. "/" .. rel end
			return tmp_dir
		end
		ManifestMenu.invalidate_cache()

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
