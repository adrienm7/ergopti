--- tests/unit/ui/test_healthcheck_unavailable.lua

--- ==============================================================================
--- MODULE: Healthcheck Unavailable Features (macOS)
--- DESCRIPTION:
--- The diagnostics are the only place a user can ask why a menu row they read
--- about is not in their menu. The collector lists every absence the manifest
--- ships, explained or not, with the platforms that have it and the reason key
--- the page translates (tools/test/test-reason-keys-are-readable.cjs).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs the collector over a manifest reader answering the given gaps.
--- @param explained table
--- @param silent table
--- @return boolean ok, any result
local function collect(explained, silent)
	local result
	local ok, err = pcall(function()
		helpers.with_stub_scope({ "infra.logger", "infra.manifest_reader", "ui.healthcheck.helpers" }, function()
			helpers.load_with_stubs("infra.logger")
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.manifest_reader"] = { coverage_gaps = function() return explained, silent end }
			package.loaded["ui.healthcheck.helpers"] = nil
			result = require("ui.healthcheck.helpers").collect_unavailable()
		end)
	end)
	return ok, ok and result or err
end

helpers.describe("healthcheck: unavailable features (macOS)", function()
	helpers.it("lists explained and silent absences, sorted, with their platforms", function()
		local ok, section = collect(
			{ { path = "script.alt_gr_is_kana_remap", reason_key = "platform_reason.alt_gr_is_kana_remap",
				platforms = { "ahk" } } },
			{ { path = "hotstrings.expansion_delay", reason_key = "", platforms = { "ahk", "linux" } } })
		helpers.assert_true(ok, tostring(section))
		helpers.assert_eq(section.items, {
			{ feature = "hotstrings.expansion_delay", platforms = "Windows, Linux" },
			{ feature = "script.alt_gr_is_kana_remap", platforms = "Windows",
				reason = "platform_reason.alt_gr_is_kana_remap" },
		})
	end)

	helpers.it("refuses a platform code it cannot name", function()
		local ok, err = collect({}, { { path = "x.y", platforms = { "amiga" } } })
		helpers.assert_eq(ok, false)
		helpers.assert_contains(tostring(err), "unknown platform")
	end)
end)
