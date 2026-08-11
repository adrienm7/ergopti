--- tests/unit/adapters/test_event_tap_guard_counts.lua

--- ==============================================================================
--- MODULE: Honest Event-Tap Timeout Telemetry
--- DESCRIPTION:
--- The bundled Hammerspoon runtime consumes tap-disable notifications before
--- Lua. A zero count would therefore claim a measurement that never ran. The
--- health snapshot and both report formats must disclose that blind spot.
---
--- ROOT CAUSE ENCODED:
--- The former counter was only exercised through constants invented by the test
--- stub. These behavioral assertions observe the diagnostic data and text that
--- users actually receive, including the fallback for older stored snapshots.
--- ==============================================================================

local helpers = require("tests.helpers")

local CONTRACT_VERSION = "1.1.1"
local TELEMETRY_LABEL = "Native tap timeout telemetry"


--- Loads the healthcheck formatter without invoking live OS collectors.
--- @return table Healthcheck core module.
local function load_healthcheck(runtime_version)
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["ui.healthcheck.helpers"] = {
		format_uptime = function() return "0s" end,
		sys_info = function() return { hs_version = runtime_version or CONTRACT_VERSION } end,
	}
	package.loaded["infra.paths"] = {
		shared = function() return "" end,
	}
	package.loaded["healthcheck.snapshot"] = {
		count_issues = function() return 0, 0 end,
		extract_recent_issues = function() return {} end,
	}
	package.loaded["ui.healthcheck.core"] = nil
	return require("ui.healthcheck.core")
end


--- Returns the smallest complete snapshot accepted by format_plain().
--- @return table Diagnostic snapshot.
local function empty_snapshot()
	return {
		version = "test",
		uptime_sec = 0,
		warn_count = 0,
		err_count = 0,
		sys = {},
		ports_validated = {},
		failed_adapters = {},
		unwired_adapters = {},
		wired_count = 0,
		adapter_count = 0,
	}
end


helpers.describe("event tap telemetry: health snapshot", function()

	helpers.it("publishes a structured unavailable result", function()
		local telemetry = load_healthcheck().run().event_tap_timeout_telemetry

		helpers.assert_not_nil(telemetry,
			"the web renderer receives M.run(), so a format-only disclaimer stays invisible")
		helpers.assert_eq(false, telemetry.available,
			"the snapshot must not describe this native-only signal as measured")
	end)

	helpers.it("ties the unavailable result to the reviewed runtime", function()
		local telemetry = load_healthcheck().run().event_tap_timeout_telemetry

		helpers.assert_eq(CONTRACT_VERSION, telemetry.reviewed_hammerspoon_version)
		helpers.assert_eq(CONTRACT_VERSION, telemetry.runtime_hammerspoon_version)
		helpers.assert_eq(true, telemetry.native_contract_reviewed)
		helpers.assert_contains(telemetry.summary, CONTRACT_VERSION)
		helpers.assert_contains(telemetry.summary, "unavailable")
	end)

	helpers.it("does not apply the reviewed contract to a different runtime", function()
		local telemetry = load_healthcheck("9.9.9").run().event_tap_timeout_telemetry

		helpers.assert_eq("9.9.9", telemetry.runtime_hammerspoon_version)
		helpers.assert_eq(false, telemetry.native_contract_reviewed)
		helpers.assert_contains(telemetry.summary, "unreviewed runtime Hammerspoon 9.9.9")
		helpers.assert_true(not telemetry.summary:find("reviewed Hammerspoon 1.1.1 consumes", 1, true),
			"a build override must not inherit the default runtime's native guarantee")
	end)

	helpers.it("returns an isolated telemetry table on every run", function()
		local Healthcheck = load_healthcheck()
		local first = Healthcheck.run().event_tap_timeout_telemetry
		first.summary = "forged"
		local second = Healthcheck.run().event_tap_timeout_telemetry

		helpers.assert_true(first ~= second, "diagnostic snapshots must not share mutable state")
		helpers.assert_true(second.summary ~= "forged",
			"a report consumer must not be able to rewrite future telemetry status")
	end)

end)


helpers.describe("event tap telemetry: plain report", function()

	helpers.it("states unavailable instead of reporting a false zero", function()
		local report = load_healthcheck().format_plain(empty_snapshot())

		helpers.assert_contains(report, TELEMETRY_LABEL,
			"an absent line is ambiguous; the blind spot must be explicit")
		helpers.assert_contains(report, CONTRACT_VERSION,
			"the claim must name the runtime contract it was derived from")
		helpers.assert_contains(report, "unavailable")
	end)

	helpers.it("does not retain the old invented measurement language", function()
		local report = load_healthcheck().format_plain(empty_snapshot())

		helpers.assert_true(not report:find("after a callback overran", 1, true),
			"the removed counter must not survive in the text fallback")
		helpers.assert_true(not report:find("Tap disables", 1, true),
			"the report must not present native-only events as a Lua tally")
	end)

	helpers.it("keeps older stored snapshots honest through the fallback", function()
		local snapshot = empty_snapshot()
		snapshot.event_tap_timeout_telemetry = nil
		local report = load_healthcheck().format_plain(snapshot)

		helpers.assert_contains(report, "unavailable")
		helpers.assert_contains(report, CONTRACT_VERSION)
	end)

end)
