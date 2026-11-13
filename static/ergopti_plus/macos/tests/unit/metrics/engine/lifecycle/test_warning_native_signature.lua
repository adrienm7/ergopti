--- tests/unit/metrics/engine/lifecycle/test_warning_native_signature.lua

--- ==============================================================================
--- MODULE: Metrics Warning Native Signature
--- DESCRIPTION:
--- Exercises the real public metrics failure branch without starting the engine.
--- ==============================================================================

local helpers = require("tests.helpers")
local WarningContract = require("tests.support.dialog_warning_contract")
local Fixture = require("tests.support.metrics.provenance_fixture")
local OWNERS = {
	"core.events.clock",
	"core.timing.engine.timings",
	"core.text.engine.toml.reader",
	"metrics.engine.metrics",
	"metrics.engine.privacy.context",
	"diagnostics.engine.reports.error_description",
	"core.text.engine.number_policy",
	"core.text.engine.json",
	"core.lifecycle.engine.compat.utf8",
	"core.text.engine.toml_codec.reader",
	"core.text.engine.toml_codec.bom",
	"core.text.engine.toml_codec.basic_string",
	"core.text.engine.toml_codec.key_path",
	"core.text.engine.toml_codec.record_scanner",
	"core.text.engine.toml_codec.source_open",
	"metrics.engine.capture.physical_lifecycle_observation", "shortcuts.adapters.physical_observation_clock", "hs", "tests.stubs.hs", "core.logger.engine.logger", "menu.engine.manifest_reader", "settings.engine.paths",
	"core.ui.engine.dialog_util", "core.lifecycle.engine.shutdown.teardown_transaction", "modules.keystats.init",
	"metrics.engine.journal.log_manager", "metrics.engine.context_tracker",
	"metrics.adapters.kc_bridge", "metrics.engine.system.watchers", "metrics.engine.journal.timestamp",
	"metrics.engine.capture.physical_accounting_mode", "platform.input.synthetic_input", "diagnostics.adapters.event_provenance", "core.process.adapters.lifecycle",
	"platform.input.keyboard_hook", "layouts.adapters.input_source_broker", "core.fs.adapters.storage",
	"core.events.timer_scheduler", "metrics.engine.aggregator.events",
	"metrics.engine.aggregator.state", "metrics.engine.aggregator.core",
	"metrics.engine.aggregator.physical", "ui.metrics_typing.init", "metrics.ui.metrics_typing", "hotstrings.engine.expander",
}





--- =========================================
--- =========================================
--- ======= 1/ Public Failure Warning =======
--- =========================================
--- =========================================

helpers.describe("typing metrics warning native signature", function()
	helpers.it("presents the unavailable metrics warning without a native signature error", function()
		helpers.with_stub_scope(OWNERS, function()
			local fixture = Fixture.load_keystats()
			local warnings = WarningContract.attach(package.loaded["core.ui.engine.dialog_util"])
			local prior_loader = package.preload["metrics.ui.metrics_typing"]
			package.loaded["metrics.ui.metrics_typing"] = nil
			package.preload["metrics.ui.metrics_typing"] = function() error("controlled metrics module unavailable", 0) end
			local ok, detail = xpcall(function()
				fixture.keystats.show_metrics()
				helpers.assert_eq(warnings.shown, {
					{ "keystats.error_title", "keystats.error_body", "button.ok" },
				}, "Missing metrics UI must display its warning rather than raise a dialog argument error")
				helpers.assert_eq(warnings.refused, 0)
			end, debug.traceback)
			package.preload["metrics.ui.metrics_typing"] = prior_loader
			if not ok then error(detail, 0) end
		end)
	end)
end)

return true
