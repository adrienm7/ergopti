--- tests/unit/modules/updater/test_updater_constants_single_source.lua

--- Regression guard: asserts that modules.updater exports the
--- canonical owner/repo/timing values from defaults.json. Tests assert the
--- module's exported values at load-time — NOT source text — so they catch
--- both a missing defaults.json read and a silent fallback mismatch.

local helpers = require("tests.helpers")


-- =============================================================
-- =============================================================
-- ======= 1/ Exported constants from defaults.json ============
-- =============================================================
-- =============================================================

helpers.describe("updater constants single source", function()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	local updater = helpers.load_with_stubs("modules.updater")

	helpers.it("GH_OWNER is the canonical GitHub owner", function()
		helpers.assert_eq(updater.GH_OWNER, "adrienm7", "M.GH_OWNER must equal defaults.json github.owner")
	end)

	helpers.it("GH_REPO is the canonical GitHub repo", function()
		helpers.assert_eq(updater.GH_REPO, "ergopti", "M.GH_REPO must equal defaults.json github.repo")
	end)

	helpers.it("DEFAULT_INTERVAL_SEC is 86400 (24 h)", function()
		helpers.assert_eq(updater.DEFAULT_INTERVAL_SEC, 86400, "M.DEFAULT_INTERVAL_SEC must equal defaults.json timing.default_check_interval_sec")
	end)

	helpers.it("BOOT_CHECK_DELAY_SEC is 30", function()
		helpers.assert_eq(updater.BOOT_CHECK_DELAY_SEC, 30, "M.BOOT_CHECK_DELAY_SEC must equal defaults.json timing.boot_check_delay_sec")
	end)

	helpers.it("INTERVAL_PRESETS has 12 entries (never changes unexpectedly)", function()
		helpers.assert_true(type(updater.INTERVAL_PRESETS) == "table" and #updater.INTERVAL_PRESETS == 12,
			"INTERVAL_PRESETS must have exactly 12 entries")
	end)

	helpers.it("INTERVAL_PRESETS last entry is the never/0 sentinel", function()
		local last = updater.INTERVAL_PRESETS and updater.INTERVAL_PRESETS[12]
		helpers.assert_true(type(last) == "table" and last.code == "never" and last.seconds == 0,
			"last preset must be { code='never', seconds=0 }")
	end)
end)
