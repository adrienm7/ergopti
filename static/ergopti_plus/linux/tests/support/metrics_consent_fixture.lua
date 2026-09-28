--- tests/support/metrics_consent_fixture.lua

--- ==============================================================================
--- MODULE: Explicit Metrics Consent Fixture
--- DESCRIPTION:
--- Functional collector tests grant consent through the real public setter and
--- an isolated storage port, without changing the developer's preferences.
--- ==============================================================================

local M = {}
local Fakes = require("tests.fakes")

--- Enables the collector for one functional scenario.
--- @param collector table Initialized metrics owner.
function M.enable(collector)
	local previous = package.loaded["adapters.storage"]
	local storage = Fakes.storage()
	package.loaded["adapters.storage"] = storage
	local ok, result = pcall(collector.set_enabled, true)
	package.loaded["adapters.storage"] = previous
	assert(ok and result == true, "explicit metrics consent must be acknowledged")
	assert(storage.get("metrics.enabled") == true, "explicit consent must reach storage")
	assert(collector.is_enabled() == true, "consent must reach the runtime owner")
end

return M
