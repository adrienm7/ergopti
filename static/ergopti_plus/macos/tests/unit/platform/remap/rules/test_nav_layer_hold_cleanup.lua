--- tests/unit/platform/remap/rules/test_nav_layer_hold_cleanup.lua
local helpers = require("tests.helpers")
local NavLayer = require("platform.remap.nav_layer")

helpers.describe("navigation layer hold cleanup (nav-hold-cleanup)", function()
	helpers.it("retains each refused onboarding undo without replacing earlier cleanup", function()
		local undo = NavLayer.undo_import
		local first, second, cleaned = {}, {}, {}
		local ready = false
		local ok, err = pcall(function()
			NavLayer.undo_import = function(record)
				if not ready then return false end
				cleaned[#cleaned + 1] = record
				return true
			end
			helpers.assert_eq(NavLayer.undo_owned(first), false)
			helpers.assert_eq(NavLayer.undo_owned(second), false)
			ready = true
			helpers.assert_true(NavLayer.commit_hold("test", "none", function() return true end))
			helpers.assert_eq(cleaned, { first, second })
		end)
		NavLayer.undo_import = undo
		if not ok then error(err, 0) end
	end)
	helpers.it("retains failed onboarding imports until their cleanup settles", function()
		local import, undo = NavLayer.import_recommended, NavLayer.undo_import
		local failed = { path = "failed-wizard-import" }
		local ready, commits = false, 0
		local ok, err = pcall(function()
			NavLayer.import_recommended = function() return nil, "write refused", failed end
			NavLayer.undo_import = function(record) helpers.assert_eq(record, failed); return ready end
			helpers.assert_nil(NavLayer.import_owned({ config_dir = "/wizard" }))
			helpers.assert_eq(NavLayer.commit_hold("test", "none", function() commits = commits + 1; return true end), false)
			helpers.assert_eq(commits, 0)
			ready = true
			helpers.assert_true(NavLayer.commit_hold("test", "none", function() commits = commits + 1; return true end))
			helpers.assert_eq(commits, 1)
		end)
		NavLayer.import_recommended, NavLayer.undo_import = import, undo
		if not ok then error(err, 0) end
	end)
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
