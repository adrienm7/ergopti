--- tests/unit/modules/keystats/lifecycle/test_metrics_warning_native_signature.lua

--- ==============================================================================
--- MODULE: Metrics Warning Native Signature
--- DESCRIPTION:
--- Exercises the real public metrics failure branch without starting the engine.
--- ==============================================================================

local helpers = require("tests.helpers")
local WarningContract = require("tests.support.dialog_warning_contract")
local Fixture = require("tests.support.keystats_provenance_fixture")
local OWNERS = {
	"core.events.clock",
	"infra.timings",
	"infra.toml.reader",
	"metrics.engine.metrics",
	"modules.keystats.privacy_context",
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
	"metrics.engine.capture.physical_lifecycle_observation", "adapters.physical_observation_clock", "hs", "tests.stubs.hs", "core.logger.engine.logger", "infra.manifest_reader", "infra.config_paths",
	"infra.dialog_util", "core.lifecycle.engine.shutdown.teardown_transaction", "modules.keystats.init",
	"modules.keystats.log_manager", "modules.keystats.context_tracker",
	"modules.keystats.kc_bridge", "modules.keystats.watchers", "modules.keystats.timestamp",
	"modules.keystats.physical_accounting_mode", "adapters.synthetic_input", "adapters.event_provenance", "adapters.process_lifecycle",
	"adapters.keyboard_hook", "adapters.input_source_broker", "core.fs.adapters.storage",
	"core.events.timer_scheduler", "modules.keystats.aggregator.events",
	"modules.keystats.aggregator.state", "modules.keystats.aggregator.core",
	"modules.keystats.aggregator.physical", "ui.metrics_typing.init", "ui.metrics_typing", "modules.keymap",
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
			local warnings = WarningContract.attach(package.loaded["infra.dialog_util"])
			local prior_loader = package.preload["ui.metrics_typing"]
			package.loaded["ui.metrics_typing"] = nil
			package.preload["ui.metrics_typing"] = function() error("controlled metrics module unavailable", 0) end
			local ok, detail = xpcall(function()
				fixture.keystats.show_metrics()
				helpers.assert_eq(warnings.shown, {
					{ "keystats.error_title", "keystats.error_body", "button.ok" },
				}, "Missing metrics UI must display its warning rather than raise a dialog argument error")
				helpers.assert_eq(warnings.refused, 0)
			end, debug.traceback)
			package.preload["ui.metrics_typing"] = prior_loader
			if not ok then error(detail, 0) end
		end)
	end)
end)

return true
