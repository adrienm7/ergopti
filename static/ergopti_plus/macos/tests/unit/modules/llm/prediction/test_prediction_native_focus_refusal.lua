--- tests/unit/modules/llm/prediction/test_prediction_native_focus_refusal.lua

--- Exercises native focus refusal at the real prediction backend dispatch edge.
local helpers = require("tests.helpers")
local Pipeline = require("tests.support.prediction_pipeline")

-- These are the real pipeline's transitive modules and its explicit facade
-- injections. The existing fixture and all production entry points stay intact.
local OWNED = {
	"_generated.locale_table",
	"_generated.logger_sub_files",
	"adapters.file_system",
	"adapters.json_codec",
	"adapters.log_transport",
	"adapters.secure_field_detector",
	"adapters.storage",
	"adapters.timer_scheduler",
	"app_dirs",
	"compat.utf8",
	"diagnostics.operation_reporter",
	"diagnostics.redact",
	"error_description",
	"infra.fs_dir",
	"infra.i18n",
	"infra.keycodes",
	"infra.launcher_environment",
	"infra.locale",
	"infra.log_folders",
	"infra.logger",
	"infra.paths",
	"infra.text_utils",
	"infra.timings",
	"infra.toml.reader",
	"json",
	"keycodes",
	"lfs",
	"llm.parser",
	"llm.prompt_action",
	"llm.prompt_builder",
	"llm.rewrite",
	"llm.translate",
	"locale.core",
	"logger",
	"logger.shim",
	"menu.labels",
	"modules.keystats",
	"modules.keymap.utils",
	"modules.llm",
	"modules.llm.api_common",
	"modules.llm.app_filter",
	"modules.llm.parser",
	"modules.llm.prediction_engine",
	"modules.llm.prompt_builder",
	"modules.llm.streaming_handler",
	"modules.llm.warmup_controller",
	"modules.shortcuts.script_control",
	"native_path",
	"number_policy",
	"text_utils",
	"toml_codec.basic_string",
	"toml_codec.bom",
	"toml_codec.key_path",
	"toml_codec.reader",
	"toml_codec.record_scanner",
	"toml_codec.source_open",
	"ui.tooltip",
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
			local warmup = table.pack(pcall(require("modules.llm.warmup_controller").stop))
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
