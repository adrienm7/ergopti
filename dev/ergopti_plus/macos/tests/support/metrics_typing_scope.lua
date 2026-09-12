--- tests/support/metrics_typing_scope.lua

--- ==============================================================================
--- MODULE: Typing Metrics Scenario Scope
--- DESCRIPTION:
--- Retains exact predecessor modules and native state across complete UI scenarios.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}
local OWNERS = {
	"adapters.file_system", "adapters.timer_scheduler", "infra.logger", "infra.paths",
	"infra.i18n", "infra.fs_dir", "infra.text_utils", "text_utils",
	"hs.fs", "hs.json", "json", "ui.ui_builder", "ui.metrics_typing",
	"modules.keylogger.log_manager", "modules.keylogger.sqlite_reader",
}

--- Runs construction and every callback within the same native and cache scope.
--- @param callback function Complete scenario.
--- @return ... Scenario results.
function M.run(callback)
	return helpers.with_stub_scope(OWNERS, callback)
end

--- Registers an independently selectable scenario with automatic scope restoration.
--- @param name string Scenario name.
--- @param callback function Complete scenario.
function M.it(name, callback)
	helpers.it(name, function() return M.run(callback) end)
end

return M
