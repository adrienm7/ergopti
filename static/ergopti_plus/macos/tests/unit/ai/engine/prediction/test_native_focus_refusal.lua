--- tests/unit/ai/engine/prediction/test_native_focus_refusal.lua

--- Exercises native focus refusal at the real prediction backend dispatch edge.
local helpers = require("tests.helpers")
local Pipeline = require("tests.support.ai.prediction_pipeline")

-- These are the real pipeline's transitive modules and its explicit facade
-- injections. The existing fixture and all production entry points stay intact.
local OWNED = {
	"_generated.locale_table",
	"_generated.logger_sub_files",
	"core.fs.adapters.file_system",
	"core.fs.adapters.json_codec",
	"core.logger.adapters.log_transport",
	"platform.focus.secure_field_detector",
	"core.fs.adapters.storage",
	"core.events.timer_scheduler",
	"core.fs.engine.app_dirs",
	"core.lifecycle.engine.compat.utf8",
	"diagnostics.engine.operation_reporter",
	"diagnostics.engine.reports.redact",
	"diagnostics.engine.reports.error_description",
	"core.fs.engine.dir",
	"core.i18n.engine.i18n",
	"platform.input.keycodes",
	"core.lifecycle.engine.launcher_environment",
	"core.i18n.engine.locale",
	"core.logger.engine.log_folders",
	"core.logger.engine.logger",
	"core.fs.engine.paths",
	"core.text.engine.utils",
	"core.timing.engine.timings",
	"core.text.engine.toml.reader",
	"core.text.engine.json",
	"platform.input.keycodes.core",
	"lfs",
	"ai.engine.api.parser_core",
	"ai.engine.prediction.prompt_action",
	"ai.engine.prediction.prompt_builder_core",
	"ai.engine.prediction.rewrite",
	"ai.engine.prediction.translate",
	"core.i18n.engine.core",
	"core.logger.engine",
	"core.logger.engine.shim",
	"menu.engine.labels",
	"metrics.engine",
	"hotstrings.engine.expander.utils",
	"ai.engine",
	"ai.engine.api.common",
	"ai.engine.prediction.app_filter",
	"ai.engine.api.parser",
	"ai.engine.prediction.engine",
	"ai.engine.prediction.prompt_builder",
	"ai.engine.api.streaming_handler",
	"ai.engine.local_servers.warmup_controller",
	"shortcuts.engine.script_control",
	"core.fs.engine.native_path",
	"core.text.engine.number_policy",
	"core.text.engine.utils_core",
	"core.text.engine.toml_codec.basic_string",
	"core.text.engine.toml_codec.bom",
	"core.text.engine.toml_codec.key_path",
	"core.text.engine.toml_codec.reader",
	"core.text.engine.toml_codec.record_scanner",
	"core.text.engine.toml_codec.source_open",
	"core.ui.ui.tooltip",
}

--- Runs the unchanged pipeline fixture with one exact native focus port.
---@param callback function Receives real pipeline and native read controls.
local function with_pipeline(callback)
	local original_lfs = rawget(_G, "lfs")
	local outcome = table.pack(xpcall(function()
		return helpers.with_stub_scope(OWNED, function()
			local fixture = Pipeline.load({ capture_debug = true })
			local native_hs = hs
			local original_ax = native_hs.axuielement
			local controls = { mode = "secure", focus_reads = 0, calls = {} }
			local field = { attributeValue = function(_, attribute)
				if attribute == "AXRole" then return "AXTextField" end
				if attribute == "AXSubrole" and controls.mode ~= "ordinary" then return "AXSecureTextField" end
				return nil
			end }
			local application = { attributeValue = function(_, attribute)
				helpers.assert_eq(attribute, "AXFocusedUIElement")
				controls.focus_reads = controls.focus_reads + 1
				if controls.mode == "refused" then
					controls.calls[#controls.calls + 1] = { mode = "refused", returns = 2,
						value_is_nil = true, detail = "Messaging failed" }
					return nil, "Messaging failed"
				end
				controls.calls[#controls.calls + 1] = { mode = controls.mode, returns = 1 }
				return field
			end }
			native_hs.axuielement = { applicationElementForPID = function(pid)
				helpers.assert_eq(pid, 42, "The actual pipeline fixture application owns the AX request")
				return application
			end }
			fixture.engine.set_llm_secure_field_filter_enabled(true)
			fixture.engine.set_llm_url_bar_filter_enabled(false)
			local result = table.pack(xpcall(function() return callback(fixture, controls) end, debug.traceback))
			-- Reset the real pipeline before releasing its scope, including after an
			-- expected pre-fix assertion. No model or HTTP client is constructed.
			local reset = table.pack(pcall(fixture.engine.reset))
			local warmup = table.pack(pcall(require("ai.engine.local_servers.warmup_controller").stop))
			native_hs.axuielement = original_ax
			helpers.assert_true(reset[1] and reset[2] == true, "The actual prediction engine must reset after every body")
			helpers.assert_true(warmup[1] and warmup[2] == true, "The actual warmup owner must retire after every body")
			for _, timer in ipairs(native_hs.timer.__timers) do
				helpers.assert_eq(timer.running, false, "Every timer acquired by the pipeline must retire")
			end
			helpers.assert_true(rawequal(native_hs.axuielement, original_ax), "Restore the exact native AX table before scope finally")
			if not result[1] then error(result[2], 0) end
			return table.unpack(result, 2, result.n)
		end)
	end, debug.traceback))
	rawset(_G, "lfs", original_lfs)
	if not outcome[1] then error(outcome[2], 0) end
	return table.unpack(outcome, 2, outcome.n)
end

--- Drives the actual public pipeline while checking one native resolution.
local function perform(fixture, controls, expected, label)
	local reads = controls.focus_reads
	fixture.engine.perform_check(true)
	helpers.assert_eq(controls.focus_reads - reads, 1, "One real app-filter AX focus resolution per request")
	helpers.assert_eq(fixture.fetches, expected, label)
	helpers.assert_eq(fixture.loading_calls, expected, "A refused field must not display prediction loading")
end

helpers.describe("Prediction dispatch under native AX focus refusal", function()
	helpers.it("refuses backend dispatch for an exclusion restored as a string", function()
		with_pipeline(function(fixture, controls)
			controls.mode = "ordinary"
			require("tests.support.settings.toml_output_fixture").with_output(function(path)
				local file = assert(io.open(path, "wb"))
				assert(file:write('[llm.trigger]\ndisabled_apps = ["test.fixture"]\n'))
				file:close()
				local Preferences = helpers.load_with_stubs("settings.engine.preferences.preferences")
				local saved, status = Preferences.load(path)
				helpers.assert_eq(status, "ok")
				helpers.assert_eq(saved.llm_disabled_apps, { "test.fixture" })
				fixture.engine.set_llm_disabled_apps(saved.llm_disabled_apps)
				perform(fixture, controls, 0, "the restored identifier must block actual dispatch")
				fixture.engine.set_llm_disabled_apps({})
				perform(fixture, controls, 1, "removing the exclusion restores normal dispatch")
			end)
		end)
	end)

	helpers.it("refuses dispatch when an excluded application path cannot be read", function()
		with_pipeline(function(fixture)
			fixture.engine.set_llm_secure_field_filter_enabled(false)
			fixture.engine.set_llm_disabled_apps({ { appPath = "/Applications/Secret.app" } })
			local app = hs.application.frontmostApplication()
			local original_path = app.path
			app.path = function() return nil end
			fixture.engine.perform_check(true)
			helpers.assert_eq(fixture.fetches, 0, "unknown excluded path must not reach the backend")
			helpers.assert_eq(fixture.loading_calls, 0)
			app.path = original_path
			fixture.engine.perform_check(true)
			helpers.assert_eq(fixture.fetches, 1, "a readable nonexcluded application must still dispatch")
		end)
	end)
	helpers.it("(native-ai-dispatch) refuses a healthy known secure field before backend dispatch", function()
		with_pipeline(function(fixture, controls)
			perform(fixture, controls, 0, "Healthy secure focus must suppress actual backend dispatch")
		end)
	end)
	helpers.it("(native-ai-dispatch) refuses a native focus error before backend dispatch", function()
		with_pipeline(function(fixture, controls)
			perform(fixture, controls, 0)
			controls.mode = "refused"
			perform(fixture, controls, 0, "Confirmed native AX focus refusal must suppress actual backend dispatch")
			local refusal = controls.calls[#controls.calls]
			helpers.assert_eq(refusal.returns, 2); helpers.assert_eq(refusal.value_is_nil, true)
			helpers.assert_eq(refusal.detail, "Messaging failed")
		end)
	end)
	helpers.it("(native-ai-dispatch) dispatches once after ordinary focus recovers from refusal", function()
		with_pipeline(function(fixture, controls)
			controls.mode = "refused"
			perform(fixture, controls, 0, "Confirmed native AX focus refusal must suppress actual backend dispatch")
			controls.mode = "ordinary"
			perform(fixture, controls, 1, "Healthy ordinary recovery must reach the actual backend port once")
			helpers.assert_eq(fixture.last_fetch.model, "test-model")
			helpers.assert_eq(fixture.last_fetch.force, true)
			helpers.assert_eq(fixture.last_fetch.context, "hello world")
		end)
	end)
end)
