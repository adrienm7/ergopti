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
	"_generated.registry_limits",
	"shortcuts.engine.actions.assignable",
	"core.fs.engine.app_dirs",
	"apps.engine.parameter",
	"shortcuts.engine.brightness_actions",
	"shortcuts.engine.brightness_actions_data",
	"settings.engine.publication.binding_identity",
	"core.lifecycle.engine.compat.utf8",
	"settings.engine.publication.binding_publication",
	"settings.engine.publication.defaults",
	"settings.engine.publication.keyboard_publication",
	"core.lifecycle.engine.core.managed_ollama_daemon_receipt",
	"core.lifecycle.engine.core.ollama_runtime_choice",
	"keyboard.engine.desktop_navigation",
	"diagnostics.engine.operation_reporter",
	"diagnostics.engine.reports.redact",
	"diagnostics.engine.runtime_log",
	-- The real logger and timer scheduler describe failures through this pure owner.
	"diagnostics.engine.reports.error_description",
	-- The real manifest reader loads the shared features manifest through these owners.
	"settings.engine.features.manifest",
	"settings.engine.features.manifest_data",
	-- Path splitting and timer delay admission go through these pure owners.
	"core.fs.engine.native_path",
	"core.text.engine.number_policy",
	-- The real notifications owner focuses the clicked application through this adapter.
	"adapters.running_application",
	"hotstrings.engine.catalogue.personal_files",
	"core.text.engine.json",
	"platform.input.keycodes.core",
	"layouts.engine.layers.control_signals",
	"layouts.engine.utils",
	"lfs",
	"ai.engine.api.model_listing",
	"ai.engine.policy.context_buffer",
	"ai.engine.settings.enable_admission_core",
	"ai.engine.ollama.local_model_policy",
	"ai.engine.local_servers.auth",
	"ai.engine.local_servers.discovery",
	"ai.engine.local_servers.ports_core",
	"ai.engine.local_servers.model_capabilities",
	"ai.engine.api.parser_core",
	"ai.engine.settings.profile_selector",
	"ai.engine.prediction.prompt_action",
	"ai.engine.prediction.prompt_builder_core",
	"ai.engine.policy.provider_config_policy",
	"ai.engine.api.remote_formats",
	"ai.engine.request_plan.debounce",
	"ai.engine.request_plan.info_bar",
	"ai.engine.request_plan.live",
	"ai.engine.request_plan.ports",
	"ai.engine.request_plan.token_budget",
	"ai.engine.prediction.rewrite",
	"ai.engine.policy.thinking_off",
	"ai.engine.prediction.tone",
	"ai.engine.prediction.translate",
	"core.text.engine.identifiers",
	"ai.engine.prediction.vision",
	"core.logger.engine.shim",
	"menu.engine.manifest_reader_core",
	"core.logger.engine.perf_budget",
	"platform.remap.lease_helper",
	"settings.engine.program_parameter", "shortcuts.engine.user_action_parameter",
	"keyboard.engine.layers.script_chords",
	"platform.input.send_input",
	"tap_hold.engine.key_combinations",
	"core.text.engine.utils_core",
	"core.timing.engine.timings_core",
	"core.text.engine.toml_codec.basic_string",
	"core.text.engine.toml_codec.bom",
	"core.text.engine.toml_codec.key_path",
	"core.text.engine.toml_codec.reader",
	"core.text.engine.toml_codec.record_scanner",
	-- The real TOML reader opens its source through this shared owner.
	"core.text.engine.toml_codec.source_open",
	"keyboard.engine.wrap_pair",
	-- The secure-app rule and its generated list, loaded with the detector.
	"apps.engine.secure_apps",
	"apps.engine.secure_apps_data",

	"adapters.accessibility_permission",
	"adapters.clipboard",
	"adapters.event_provenance",
	"adapters.file_system",
	"adapters.metadata_command_stats",
	"adapters.write_lock_path",
	"adapters.http_client",
	"adapters.json_codec",
	"adapters.key_state",
	"adapters.log_transport",
	"adapters.managed_ollama_daemon",
	"adapters.modifier_injector",
	"adapters.prediction_tooltip_port",
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
	"infra.field_run_selftest",
	"infra.fs_dir",
	"infra.i18n",
	"infra.keycodes",
	"infra.llm_context_limit",
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
	"modules.gestures.frame_clock",
	"infra.gesture_frame_evidence",
	"modules.gestures.geometry",
	"gestures.engine.sensitivity",
	"modules.gestures.sticky_modifiers",
	"modules.keystats",
	"modules.keymap",
	"modules.keymap.control_sentinels",
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
	"modules.llm.local_server_ports",
	"modules.llm.local_servers",
	"modules.llm.network_env",
	-- network_env reads the shared proxy override through these two.
	"core.network.engine.proxy_override",
	"core.network.engine.route_plan",
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
	"ai.engine.policy.remote_response_classifier",
	"modules.llm.selection_publication",
	"modules.llm.selection_translation",
	"modules.llm.streaming_handler",
	"modules.llm.thinking_families",
	"modules.llm.warmup_controller",
	"modules.shortcuts.actions.screen_capture_flow",
	"modules.shortcuts.actions.screenshot_save",
	"modules.shortcuts.actions.text",
	"modules.shortcuts.actions.text_continuation",
	"modules.shortcuts.actions.text_dispatch",
	"modules.shortcuts.actions.text_transform_grace",
	-- Translation now owns one canonical AI-off subscription per module lifetime.
	"modules.shortcuts.ai_actions",
	"tests.support.modules.llm.selection_translation_destination",
	"ui.tooltip",

	-- Shared owners the real pipeline loads since the integrated catalogue,
	-- key-event health, per-application profile and storage-ownership work.
	"shortcuts.engine.actions.catalogue",
	"shortcuts.engine.actions.catalogue_data",
	"adapters.event_clock",
	"core.lifecycle.engine.compat.base64",
	"gestures.engine.direction",
	"infra.key_event_health",
	"infra.phase_stats",
	-- The phase counters' bookkeeping, shared with the Linux driver.
	"metrics.engine.perf.phase_stats_core",
	"ai.engine.policy.app_identity",
	"ai.engine.policy.app_profile_overrides",
	"ai.engine.policy.temperature",
	"settings.engine.scope.owner",
	"core.fs.engine.storage_owned",
	"core.text.engine.table_util",
	"core.text.engine.toml_codec.source_memo",
	-- The real logger and log transport probe the optional LuaSocket clock.
	"socket",
	"socket.core",
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
