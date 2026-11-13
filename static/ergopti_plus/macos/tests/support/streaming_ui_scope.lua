--- tests/support/streaming_ui_scope.lua

--- ==============================================================================
--- MODULE: Streaming UI Scenario Scope
--- DESCRIPTION:
--- Owns injected handlers, native overrides and real facade imports per scenario.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}
local OWNERS = {
	"modules.llm.parser", "modules.llm.streaming_handler", "core.events.timer_scheduler",
	"ui.tooltip.init", "core.ui.ui.tooltip.config", "core.ui.ui.tooltip.llm",
	"core.ui.ui.tooltip.hotstring", "core.logger.engine.logger",
}

--- Registers a scenario whose fixture state is restored even after an assertion.
--- @param name string Scenario name.
--- @param callback function Fixture construction and scenario assertions.
function M.it(name, callback)
	helpers.it(name, function()
		return helpers.with_stub_scope(OWNERS, callback)
	end)
end

return M
