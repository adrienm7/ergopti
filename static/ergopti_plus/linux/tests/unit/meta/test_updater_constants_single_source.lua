--- tests/unit/meta/test_updater_constants_single_source.lua

--- ==============================================================================
--- MODULE: Updater Constants Single-Source Test (Linux driver)
--- DESCRIPTION:
--- Drift/parity guard asserting that the Linux updater manager resolves its
--- owner/repo/timing scalars from _shared/modules/updater/defaults.json instead
--- of re-declaring them inline. Mirrors the macOS test of the same name and the
--- JS gate tools/test/test-updater-constants-single-source.cjs. Reads the shared
--- JSON at test time and compares it to the module's exported constants, so both
--- a missing read and a silently drifted fallback are caught.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json    = require("json")

helpers.describe("updater constants single source (Linux)", function()
	-- Read the canonical shared defaults independently of the module under test,
	-- reusing the sibling-of-driver path the corpus test relies on
	local shared_root   = helpers.driver_root() .. "/../_shared"
	local defaults_path = shared_root .. "/modules/updater/defaults.json"
	local fh = io.open(defaults_path, "r")
	helpers.assert_not_nil(fh, "defaults.json must be readable at " .. defaults_path)
	local raw = fh:read("*a")
	fh:close()
	local defs = Json.decode(raw)
	helpers.assert_true(type(defs) == "table", "defaults.json must decode to a table")

	local M = helpers.load_module("modules.updater.manager")

	helpers.it("GH_OWNER is read from defaults.json github.owner", function()
		helpers.assert_eq(M.GH_OWNER, defs.github.owner,
			"M.GH_OWNER must equal defaults.json github.owner")
	end)

	helpers.it("GH_REPO is read from defaults.json github.repo", function()
		helpers.assert_eq(M.GH_REPO, defs.github.repo,
			"M.GH_REPO must equal defaults.json github.repo")
	end)

	helpers.it("DEFAULT_INTERVAL_SEC is read from defaults.json timing", function()
		helpers.assert_eq(M.DEFAULT_INTERVAL_SEC, defs.timing.default_check_interval_sec,
			"M.DEFAULT_INTERVAL_SEC must equal defaults.json timing.default_check_interval_sec")
	end)

	helpers.it("BOOT_CHECK_DELAY_SEC is read from defaults.json timing", function()
		helpers.assert_eq(M.BOOT_CHECK_DELAY_SEC, defs.timing.boot_check_delay_sec,
			"M.BOOT_CHECK_DELAY_SEC must equal defaults.json timing.boot_check_delay_sec")
	end)

	helpers.it("repo_info reflects the shared owner/repo", function()
		local info = M.repo_info()
		helpers.assert_eq(info.owner, defs.github.owner, "repo_info().owner must match defaults.json")
		helpers.assert_eq(info.repo, defs.github.repo, "repo_info().repo must match defaults.json")
	end)
end)
