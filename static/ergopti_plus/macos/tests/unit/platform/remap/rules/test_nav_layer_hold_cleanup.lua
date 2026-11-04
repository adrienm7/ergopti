--- tests/unit/platform/remap/rules/test_nav_layer_hold_cleanup.lua
local helpers = require("tests.helpers")
local NavLayer = require("platform.remap.nav_layer")

helpers.describe("navigation layer hold cleanup (nav-hold-cleanup)", function()
	helpers.it("retains a refused import cleanup and blocks a successor until it settles", function()
		local import, undo = NavLayer.import_recommended, NavLayer.undo_import
		local failed = { path = "failed-import" }
		local can_clean, cleaned, commits, imports = false, 0, 0, 0
		local ok, err = pcall(function()
			NavLayer.import_recommended = function() imports = imports + 1; return nil, "refused", failed end
			NavLayer.undo_import = function(record)
				helpers.assert_eq(record, failed)
				cleaned = cleaned + 1
				return can_clean
			end
			helpers.assert_eq(NavLayer.commit_hold("test", "layer", function() commits = commits + 1; return true end), false)
			helpers.assert_eq(NavLayer.commit_hold("test", "none", function() commits = commits + 1; return true end), false)
			helpers.assert_eq(commits, 0)
			can_clean = true
			helpers.assert_eq(NavLayer.commit_hold("test", "none", function() commits = commits + 1; return true end), true)
			helpers.assert_eq(commits, 1)
			helpers.assert_eq(imports, 1)
			helpers.assert_true(cleaned >= 2)
		end)
		NavLayer.import_recommended, NavLayer.undo_import = import, undo
		if not ok then error(err, 0) end
	end)

	helpers.it("retains rollback debt after the setting itself refuses", function()
		local import, undo = NavLayer.import_recommended, NavLayer.undo_import
		local owned = { path = "imported-layer" }
		local can_clean, retries = false, 0
		local ok, err = pcall(function()
			NavLayer.import_recommended = function() return owned end
			NavLayer.undo_import = function(record)
				helpers.assert_eq(record, owned)
				retries = retries + 1
				return can_clean
			end
			helpers.assert_eq(NavLayer.commit_hold("test", "layer", function() return false end), false)
			helpers.assert_eq(NavLayer.commit_hold("test", "none", function() error("must not start") end), false)
			can_clean = true
			helpers.assert_eq(NavLayer.commit_hold("test", "none", function() return true end), true)
			helpers.assert_true(retries >= 2)
		end)
		NavLayer.import_recommended, NavLayer.undo_import = import, undo
		if not ok then error(err, 0) end
	end)
end)
