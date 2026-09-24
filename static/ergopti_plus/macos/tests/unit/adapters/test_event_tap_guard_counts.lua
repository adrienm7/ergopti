--- tests/unit/adapters/test_event_tap_guard_counts.lua

--- ==============================================================================
--- MODULE: Honest Event-Tap Timeout Telemetry
--- DESCRIPTION:
--- The bundled Hammerspoon runtime consumes tap-disable notifications before
--- Lua. A zero count would therefore claim a measurement that never ran. The
--- diagnostics snapshot must disclose that blind spot, tied to the runtime it
--- was reviewed for; the shared page renders it in the developer details
--- (tools/test/test-diagnostic-ui-integrity.cjs).
---
--- ROOT CAUSE ENCODED:
--- The former counter was only exercised through constants invented by the test
--- stub. These behavioral assertions observe the diagnostic data users actually
--- receive.
--- ==============================================================================

local helpers = require("tests.helpers")

local CONTRACT_VERSION = "1.1.1"


--- Loads the healthcheck core over empty collectors and a given runtime.
--- @param runtime_version string|nil
--- @return table Healthcheck core module.
local function load_healthcheck(runtime_version)
	helpers.load_with_stubs("infra.logger")
	local logger = helpers.make_logger_stub()
	logger.ring_buffer_snapshot = function() return {} end
	logger.session_issues = function() return { warn_count = 0, err_count = 0 } end
	package.loaded["infra.logger"] = logger
	local collectors = {}
	for _, name in ipairs({
		"collect_paths", "collect_versions", "collect_hardware", "collect_system", "collect_input",
		"collect_features", "collect_ai", "collect_permissions", "collect_peripherals",
	}) do collectors[name] = function() return {} end end
	package.loaded["ui.healthcheck.helpers"] = collectors
	package.loaded["adapters.system_info"] = {
		runtime_version = function() return runtime_version or CONTRACT_VERSION end,
	}
	package.loaded["ui.healthcheck.core"] = nil
	return require("ui.healthcheck.core")
end

-- The modules each case replaces, restored after it
local FIXTURE_MODULES = { "infra.logger", "ui.healthcheck.helpers", "adapters.system_info", "ui.healthcheck.core" }

--- Runs body with the healthcheck core over empty collectors and a runtime.
--- @param runtime_version string|nil
--- @param body function Receives the healthcheck core module.
local function with_healthcheck(runtime_version, body)
	helpers.with_stub_scope(FIXTURE_MODULES, function()
		body(load_healthcheck(runtime_version))
	end)
end


helpers.describe("event tap telemetry: health snapshot", function()

	helpers.it("publishes the unavailable status in the developer details", function()
		with_healthcheck(nil, function(Healthcheck)
			local developer = Healthcheck.run().sections.developer
			helpers.assert_contains(developer.event_tap_telemetry, "unavailable",
				"the snapshot must not describe this native-only signal as measured")
			helpers.assert_contains(developer.event_tap_telemetry, CONTRACT_VERSION,
				"the claim must name the runtime contract it was derived from")
		end)
	end)

	helpers.it("ties the unavailable result to the reviewed runtime", function()
		with_healthcheck(nil, function(Healthcheck)
			local telemetry = Healthcheck.event_tap_telemetry(CONTRACT_VERSION)
			helpers.assert_eq(false, telemetry.available)
			helpers.assert_eq(CONTRACT_VERSION, telemetry.reviewed_hammerspoon_version)
			helpers.assert_eq(CONTRACT_VERSION, telemetry.runtime_hammerspoon_version)
			helpers.assert_eq(true, telemetry.native_contract_reviewed)
			helpers.assert_true(not telemetry.summary:find("after a callback overran", 1, true),
				"the removed counter's language must not survive")
		end)
	end)

	helpers.it("does not apply the reviewed contract to a different runtime", function()
		with_healthcheck("9.9.9", function(Healthcheck)
			local summary = Healthcheck.run().sections.developer.event_tap_telemetry
			helpers.assert_contains(summary, "unreviewed runtime Hammerspoon 9.9.9")
			helpers.assert_true(not summary:find("reviewed Hammerspoon 1.1.1 consumes", 1, true),
				"a build override must not inherit the default runtime's native guarantee")
		end)
	end)

	helpers.it("returns an isolated telemetry table on every call", function()
		with_healthcheck(nil, function(Healthcheck)
			local first = Healthcheck.event_tap_telemetry(CONTRACT_VERSION)
			first.summary = "forged"
			local second = Healthcheck.event_tap_telemetry(CONTRACT_VERSION)
			helpers.assert_true(first ~= second, "diagnostic snapshots must not share mutable state")
			helpers.assert_true(second.summary ~= "forged",
				"a report consumer must not be able to rewrite future telemetry status")
		end)
	end)

end)
