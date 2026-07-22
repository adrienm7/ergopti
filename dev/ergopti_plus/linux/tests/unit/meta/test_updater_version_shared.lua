--- linux/tests/unit/meta/test_updater_version_shared.lua

local helpers = require("tests.helpers")

helpers.describe("_shared/lua/updater/version.lua", function()
	helpers.it("module loads without error", function()
		local ok, mod = pcall(require, "updater.version")
		helpers.assert_true(ok, "require('updater.version') should succeed")
		helpers.assert_true(type(mod) == "table", "should return a table")
	end)

	local V = require("updater.version")

	helpers.it("normalize_tag strips leading 'v'", function()
		helpers.assert_eq(V.normalize_tag("v2.5.0"), "2.5.0")
		helpers.assert_eq(V.normalize_tag("2.5.0"), "2.5.0")
		helpers.assert_eq(V.normalize_tag("V2.5.0"), "2.5.0")
		helpers.assert_eq(V.normalize_tag(nil), "")
		helpers.assert_eq(V.normalize_tag("  v2.5.0  "), "2.5.0")
	end)

	helpers.it("compare_versions: equal versions", function()
		helpers.assert_eq(V.compare_versions("2.5.0", "2.5.0"), 0)
		helpers.assert_eq(V.compare_versions("v2.5.0", "2.5.0"), 0)
	end)

	helpers.it("compare_versions: newer major", function()
		helpers.assert_eq(V.compare_versions("3.0.0", "2.9.9"), 1)
	end)

	helpers.it("compare_versions: newer minor", function()
		helpers.assert_eq(V.compare_versions("2.6.0", "2.5.0"), 1)
	end)

	helpers.it("compare_versions: newer patch", function()
		helpers.assert_eq(V.compare_versions("2.5.1", "2.5.0"), 1)
	end)

	helpers.it("compare_versions: prerelease vs stable", function()
		helpers.assert_eq(V.compare_versions("2.5.0", "2.5.0-dev.4"), 1,
			"stable is newer than prerelease")
		helpers.assert_eq(V.compare_versions("2.5.0-dev.4", "2.5.0"), -1,
			"prerelease is older than stable")
	end)

	helpers.it("compare_versions: fail-closed on non-semver", function()
		helpers.assert_eq(V.compare_versions("10", "9"), 0,
			"non-semver '10' vs '9' returns 0 (fail-closed)")
		helpers.assert_eq(V.compare_versions("garbage", "2.5.0"), 0)
	end)

	helpers.it("is_newer_version returns boolean", function()
		helpers.assert_eq(V.is_newer_version("2.6.0", "2.5.0"), true)
		helpers.assert_eq(V.is_newer_version("2.5.0", "2.6.0"), false)
		helpers.assert_eq(V.is_newer_version("2.5.0", "2.5.0"), false)
	end)
end)
