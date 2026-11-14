--- tests/unit/ui/metrics/test_metrics_apps_picker_discovery_receipt.lua

--- ==============================================================================
--- MODULE: Metrics Application Discovery Receipts
--- DESCRIPTION:
--- A failed scan is not evidence that the system has no installed applications.
--- ==============================================================================

local helpers = require("tests.helpers")
local WarningContract = require("tests.support.dialog_warning_contract")
local with_window = require("tests.support.dashboard_window_fixture")
local PICKER_OWNERS = {
	"hs",
	"tests.stubs.hs",
	"hs.fs",
	"hs.json",
	"ui.metrics_apps",
	"ui.ui_builder",
	"core.logger.engine.logger",
	"infra.dialog_util",
	"core.fs.adapters.file_system",
	"infra.config_paths",
	"core.events.timer_scheduler",
	"modules.keystats.log_manager",
	"adapters.webview_result",
	"adapters.running_application",
	"adapters.own_window",
	"core.fs.engine.native_path",
	"infra.text_utils",
	"core.text.engine.utils_core",
	"core.lifecycle.engine.compat.utf8",
	"infra.toml.codec",
	"core.text.engine.toml_codec",
	"core.text.engine.toml_codec.codec",
	"core.text.engine.toml_codec.record_scanner",
	"core.text.engine.toml_codec.key_path",
	"core.text.engine.toml_codec.bom",
	"core.text.engine.toml_codec.basic_string",
	"core.fs.engine.app_dirs",
	"core.logger.engine.log_folders",
	"diagnostics.engine.operation_reporter",
	"core.fs.engine.dir",
}

--- Scopes only this leaf's dashboard transitive imports; the shared fixture stays unchanged.
--- @param callback function Existing discovery scenario.
local function with_picker_window(callback)
	return helpers.with_stub_scope(PICKER_OWNERS, function()
		return with_window("ui.metrics_apps", callback)
	end)
end

helpers.describe("metrics_apps: discovery outcome", function()
	for _, mode in ipairs({ "failed_nil", "failed_table", "empty_success" }) do
		helpers.it("distinguishes " .. mode .. " from an empty successful scan", function()
			with_picker_window(function(dashboard, state)
				helpers.with_fresh_modules({ "infra.app_picker" }, function()
					local pending, logs = {}, {}
					local complete
					package.loaded["infra.app_picker"] = { discover_apps = function(callback) complete = callback end }
					local warnings = WarningContract.attach(package.loaded["infra.dialog_util"])
					package.loaded["core.logger.engine.logger"].debug = function(_, message, ...)
						logs[#logs + 1] = string.format(message, ...)
					end
					package.loaded["core.events.timer_scheduler"].after = function(_, callback)
						local handle = { timer = {} }
						pending[#pending + 1] = function() handle.timer = nil; callback() end
						return handle, true
					end
					helpers.assert_true(dashboard.show())
					state.receiver({ body = { action = "pick" } })
					pending[#pending]()
					helpers.assert_type(complete, "function")
					local success = mode == "empty_success"
					local rows
					if mode ~= "failed_nil" then rows = {} end
					complete(rows, success)
					helpers.assert_eq(warnings.shown, success and {
						{ "common.warning", "metrics_apps.no_app_detected", "button.ok" },
					} or {})
					helpers.assert_eq(warnings.refused, 0)
					local stopped = 0
					for _, message in ipairs(logs) do
						if message == "Application metrics picker stopped after discovery failure." then stopped = stopped + 1 end
					end
					helpers.assert_eq(stopped, success and 0 or 1)
				end)
			end)
		end)
	end
end)
