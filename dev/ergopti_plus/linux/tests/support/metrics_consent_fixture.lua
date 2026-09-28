--- tests/support/metrics_consent_fixture.lua

--- ==============================================================================
--- MODULE: Explicit Metrics Consent Fixture
--- DESCRIPTION:
--- Functional collector tests grant consent through the real public setter and
--- an isolated canonical preference port, without changing the developer's preferences.
--- ==============================================================================

local M = {}
local Fixture = require("tests.support.metrics_preferences_fixture")

--- Enables the collector for one functional scenario.
--- @param collector table Initialized metrics owner.
function M.enable(collector)
	Fixture.with(function(preferences)
		assert(collector.set_enabled(true) == true, "explicit metrics consent must be acknowledged")
		assert(preferences.get("metrics.enabled") == true, "consent must reach canonical preferences")
		assert(collector.is_enabled() == true, "consent must reach the runtime owner")
	end)
end

return M
