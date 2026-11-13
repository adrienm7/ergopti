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
	"platform.focus.running_application",
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
	"keyboard.adapters.karabiner.lease_helper",
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
	"clipboard.adapters.clipboard",
	"diagnostics.adapters.event_provenance",
	"core.fs.adapters.file_system",
	"diagnostics.adapters.metadata_command_stats",
	"core.fs.adapters.write_lock_path",
	"core.network.adapters.http_client",
	"core.fs.adapters.json_codec",
	"platform.input.key_state",
	"core.logger.adapters.log_transport",
	"ai.adapters.managed_ollama_daemon",
	"platform.input.modifier_injector",
	"ai.adapters.prediction_tooltip_port",
	"adapters.mouse_control",
	"core.process.adapters.owned_program_runner",
	"ai.adapters.python_interpreter",
	"platform.focus.secure_field_detector",
	"core.process.adapters.shell_runner",
	"core.fs.adapters.storage",
	"platform.input.synthetic_input",
	"core.process.adapters.task_environment",
	"core.events.timer_scheduler",
	"platform.focus.window_info",
	"settings.engine.paths",
	"core.timing.engine.deferred_work",
	"core.lifecycle.engine.shutdown.emergency_exit",
	"diagnostics.engine.field_run.selftest",
	"core.fs.engine.dir",
	"core.i18n.engine.i18n",
	"platform.input.keycodes",
	"ai.engine.context_limit",
	"core.lifecycle.engine.launcher_environment",
	"core.logger.engine.log_folders",
	"core.logger.engine.logger",
	"menu.engine.manifest_reader",
	"core.ui.engine.notifications",
	"core.fs.engine.paths",
	"keyboard.engine.layers.script_chord_catalogue",
	"core.lifecycle.engine.shutdown.termination_coordinator",
	"core.text.engine.utils",
	"core.timing.engine.timings",
	"core.text.engine.toml.reader",
	"gestures.engine",
	"gestures.engine.actions",
	"gestures.engine.actions_aux_owner",
	"gestures.engine.actions_click",
	"gestures.engine.conflicts",
	"gestures.engine.engine",
	"gestures.engine.frame_clock",
	"gestures.engine.frame_evidence",
	"gestures.engine.geometry",
	"gestures.engine.sensitivity",
	"gestures.engine.sticky_modifiers",
	"metrics.engine",
	"hotstrings.engine.expander",
	"hotstrings.engine.expander.control_sentinels",
	"hotstrings.engine.expander.utils",
	"ai.engine",
	"ai.engine.api.common",
	"ai.engine.api.mlx",
	"ai.engine.api.mlx_discovery",
	"ai.engine.api.mlx_fetch",
	"ai.engine.api.mlx_inference",
	"ai.engine.local_servers.mlx_stream_retirement",
	"ai.engine.api.ollama",
	"ai.engine.api.remote",
	"ai.engine.api.token_crypto",
	"ai.engine.prediction.app_filter",
	"ai.engine.local_servers.ports",
	"ai.engine.local_servers.local_servers",
	"ai.engine.api.network_env",
	-- network_env reads the shared proxy override through these two.
	"core.network.engine.proxy_override",
	"core.network.engine.route_plan",
	"ai.engine.ollama.binary",
	"ai.engine.ollama.endpoint",
	"ai.engine.ollama.server_command",
	"ai.engine.api.opaque_network_admission",
	"ai.engine.api.parser",
	"ai.engine.prediction.engine",
	"ai.engine.settings.profiles",
	"ai.engine.prediction.progressive_reveal",
	"ai.engine.prediction.prompt_builder",
	"ai.engine.api.provider_uses",
	"ai.engine.policy.remote_response_classifier",
	"ai.engine.prediction.selection_publication",
	"ai.engine.prediction.selection_translation",
	"ai.engine.api.streaming_handler",
	"ai.engine.api.thinking_families",
	"ai.engine.local_servers.warmup_controller",
	"modules.shortcuts.actions.screen_capture_flow",
	"modules.shortcuts.actions.screenshot_save",
	"modules.shortcuts.actions.text",
	"modules.shortcuts.actions.text_continuation",
	"modules.shortcuts.actions.text_dispatch",
	"modules.shortcuts.actions.text_transform_grace",
	-- Translation now owns one canonical AI-off subscription per module lifetime.
	"modules.shortcuts.ai_actions",
	"tests.support.modules.llm.selection_translation_destination",
	"core.ui.ui.tooltip",

	-- Shared owners the real pipeline loads since the integrated catalogue,
	-- key-event health, per-application profile and storage-ownership work.
	"shortcuts.engine.actions.catalogue",
	"shortcuts.engine.actions.catalogue_data",
	"core.events.clock",
	"core.lifecycle.engine.compat.base64",
	"gestures.engine.direction",
	"core.logger.engine.key_event_health",
	"metrics.engine.perf.phase_stats",
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
