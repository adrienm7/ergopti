--- tests/unit/infra/config/test_registry_limits.lua

--- ==============================================================================
--- MODULE: Generated Registry Limits Tests
--- DESCRIPTION:
--- The generated [limits] table that the logger transport, the TOML cache and
--- the shell runner read answers every registry key with the value the timings
--- reader gives, and refuses a key or a section it does not hold.
--- ==============================================================================

local helpers = require("tests.helpers")

local REGISTRY_KEYS = { "log_prepare_tick_bytes", "shell_captured_output_bytes", "toml_source_chunk_bytes" }

helpers.describe("Generated registry limits", function()
	helpers.it("answers the registry value of every key the early modules read", function()
		local Generated = require("_generated.registry_limits")
		local Timings = require("infra.timings")
		for _, key in ipairs(REGISTRY_KEYS) do
			helpers.assert_eq(Generated.count("limits", key), Timings.count("limits", key), key)
		end
	end)

	helpers.it("refuses a missing key and another section", function()
		local Generated = require("_generated.registry_limits")
		helpers.assert_throws(function() Generated.count("limits", "absent_bytes") end, "a missing key fails fast")
		helpers.assert_throws(function() Generated.count("logger", "flush_interval_ms") end, "only [limits] is generated")
	end)
end)
