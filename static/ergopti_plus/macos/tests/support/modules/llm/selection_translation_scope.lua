--- tests/support/modules/llm/selection_translation_scope.lua

--- ==============================================================================
--- MODULE: Selection Translation Fixture Ownership
--- DESCRIPTION:
--- Restores explicit real transitive consumers plus every existing module that
--- the historical translation fixture invalidates. Stub-loader writes and the
--- native hs identity are restored on both successful and failing scenarios.
--- ==============================================================================

local helpers = require("tests.helpers")
local OWNED = {
	"_generated.action_catalogue",
	"_generated.gesture_emit_actions",
	"_generated.logger_sub_files",
	"actions.assignable",
	"app_dirs",
	"app_parameter",
	"brightness_actions",
	"brightness_actions_data",
	"config_binding_identity",
	"compat.utf8",
	"config_binding_publication",
	"config_defaults",
	"config_keyboard_publication",
	"core.llm.managed_ollama_daemon_receipt",
	"core.llm.ollama_runtime_choice",
	"desktop_navigation",
	"diagnostics.operation_reporter",
	"diagnostics.redact",
	"diagnostics.runtime_log",
	"hotstrings.personal_files",
	"json",
	"keycodes",
	"keymap.utils",
	"lfs",
	"llm.enable_admission",
	"llm.local_model_policy",
	"llm.local_server_auth",
	"llm.local_server_discovery",
	"llm.parser",
	"llm.profile_selector",
	"llm.prompt_action",
	"llm.prompt_builder",
	"llm.provider_config_policy",
	"llm.remote_formats",
	"llm.rewrite",
	"llm.tone",
	"llm.translate",
	"llm.vision",
	"logger.shim",
	"platform.remap.lease_helper",
	"program_parameter",
	"script_chords",
	"send_input",
	"tap_hold.key_combinations",
	"text_utils",
	"toml_codec.basic_string",
	"toml_codec.bom",
	"toml_codec.key_path",
	"toml_codec.reader",
	"toml_codec.record_scanner",
	"wrap_pair",

	"adapters.accessibility_permission",
	"adapters.event_provenance",
	"adapters.file_system",
	"adapters.http_client",
	"adapters.json_codec",
	"adapters.key_state",
	"adapters.log_transport",
	"adapters.managed_ollama_daemon",
	"adapters.modifier_injector",
	"adapters.mouse_control",
	"adapters.owned_program_runner",
	"adapters.python_interpreter",
	"adapters.secure_field_detector",
	"adapters.shell_runner",
	"adapters.storage",
	"adapters.synthetic_input",
	"adapters.task_environment",
	"adapters.timer_scheduler",
	"adapters.window_info",
	"infra.config_paths",
	"infra.deferred_work",
	"infra.emergency_exit",
	"infra.fs_dir",
	"infra.i18n",
	"infra.keycodes",
	"infra.launcher_environment",
	"infra.log_folders",
	"infra.logger",
	"infra.manifest_reader",
	"infra.notifications",
	"infra.paths",
	"infra.script_chord_catalogue",
	"infra.termination_coordinator",
	"infra.text_utils",
	"infra.timings",
	"infra.toml.reader",
	"modules.gestures",
	"modules.gestures.actions",
	"modules.gestures.actions_aux_owner",
	"modules.gestures.actions_click",
	"modules.gestures.conflicts",
	"modules.gestures.engine",
	"modules.gestures.geometry",
	"modules.gestures.sticky_modifiers",
	"modules.keylogger",
	"modules.keymap",
	"modules.keymap.utils",
	"modules.llm",
	"modules.llm.api_common",
	"modules.llm.api_mlx",
	"modules.llm.api_mlx_discovery",
	"modules.llm.api_mlx_fetch",
	"modules.llm.api_mlx_inference",
	"modules.llm.mlx_stream_retirement",
	"modules.llm.api_ollama",
	"modules.llm.api_remote",
	"modules.llm.api_token_crypto",
	"modules.llm.app_filter",
	"modules.llm.local_servers",
	"modules.llm.network_env",
	"modules.llm.ollama_binary",
	"modules.llm.ollama_endpoint",
	"modules.llm.ollama_server_command",
	"modules.llm.opaque_network_admission",
	"modules.llm.parser",
	"modules.llm.prediction_engine",
	"modules.llm.profiles",
	"modules.llm.progressive_reveal",
	"modules.llm.prompt_builder",
	"modules.llm.provider_uses",
	"modules.llm.remote_response_classifier",
	"modules.llm.selection_publication",
	"modules.llm.selection_translation",
	"modules.llm.streaming_handler",
	"modules.llm.warmup_controller",
	"modules.shortcuts.actions.screen_capture_flow",
	"modules.shortcuts.actions.screenshot_save",
	"modules.shortcuts.actions.text",
	"modules.shortcuts.actions.text_continuation",
	"modules.shortcuts.actions.text_dispatch",
	"modules.shortcuts.actions.text_transform_grace",
	"tests.support.modules.llm.selection_translation_destination",
	"ui.tooltip",
}
local OWNED_GLOBALS = {
	"ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME", "ERGOPTI_TOUCH_DEVICES",
	"ERGOPTI_TOUCH_WATCHERS", "ERGOPTI_TOUCH_WATCHER_TOKENS", "lfs",
}
local M = {}

--- Runs construction, timers and assertions inside the same owned stub scope.
--- @param scenario function Complete fixture scenario.
--- @return any result
function M.run(scenario)
	local names, seen = {}, {}
	local function own(name)
		if not seen[name] then names[#names + 1] = name; seen[name] = true end
	end
	for _, name in ipairs(OWNED) do own(name) end
	for name in pairs(package.loaded) do
		if type(name) == "string" and (name:match("^modules%.") or name:match("^adapters%.")
			or name:match("^infra%.") or name:match("^ui%.")) then own(name) end
	end
	-- Fresh native modules must initialize their own maps, not mutate a prior
	-- world's retained device/watchers or LuaFileSystem's published table.
	local globals = {}
	for index, name in ipairs(OWNED_GLOBALS) do
		globals[index] = rawget(_G, name)
		rawset(_G, name, nil)
	end
	local outcome = table.pack(xpcall(function()
		return helpers.with_stub_scope(names, scenario)
	end, debug.traceback))
	for index, name in ipairs(OWNED_GLOBALS) do rawset(_G, name, globals[index]) end
	if not outcome[1] then error(outcome[2], 0) end
	return table.unpack(outcome, 2, outcome.n)
end

return M
