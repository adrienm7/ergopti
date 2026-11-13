--- tests/support/metrics_typing_scope.lua

--- ==============================================================================
--- MODULE: Typing Metrics Scenario Scope
--- DESCRIPTION:
--- Retains exact predecessor modules and native state across complete UI scenarios.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}
local OWNERS = {
	"core.lifecycle.engine.compat.utf8",
	"core.ui.adapters.webview_result",
	"diagnostics.engine.operation_reporter",
	-- The real dashboard resolves application icons through this adapter.
	"platform.focus.running_application",
	-- It also tells whether its own window is focused through this adapter.
	"core.ui.adapters.own_window",
	"core.fs.adapters.file_system", "diagnostics.adapters.metadata_command_stats", "core.fs.adapters.write_lock_path", "core.events.timer_scheduler", "core.logger.engine.logger", "core.fs.engine.paths",
	"core.i18n.engine.i18n", "core.fs.engine.dir", "core.text.engine.utils", "core.text.engine.utils_core",
	"hs.fs", "hs.json", "core.text.engine.json", "core.ui.ui.builder", "metrics.ui.metrics_typing",
	"metrics.engine.journal.log_manager", "metrics.engine.reader.sqlite_reader",
	-- The dashboard and the reader name the shared metric keys through this table.
	"metrics.engine.view.manifest_keys",
	"core.timing.engine.paced_job", "core.timing.engine.paced_json", "metrics.ui.metrics_typing.projection", "metrics.ui.metrics_typing.snapshot",
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
