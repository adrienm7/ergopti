// tools/audit/structure/rules.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Target Rules (Rule B, feature-first)
 * DESCRIPTION:
 * The target tree of docs/design/structure-plan.md, written as data so the
 * move map is computed rather than typed. The top level of every driver and
 * of _shared is one folder per feature a user can name (hotstrings, layouts,
 * ai, metrics, …), plus core/ for the foundations every feature uses and
 * platform/ for OS bindings no single feature owns. Inside a feature the
 * same sub-folders, layered: engine/ (the feature's logic), adapters/ (its OS
 * bindings), ui/ (what the user looks at), data/ (its data files), native/
 * (compiled sources). Tests mirror the tree under tests/<kind>/.
 *
 * Decided by the maintainer on 2026-11-11: feature-first. The vocabulary
 * below was decided by the coordinator on 2026-11-11, to review by the
 * maintainer.
 *
 * WHY RULES AND NOT A HAND-WRITTEN MAP:
 * About ten thousand files are concerned and several sessions keep adding
 * new ones. Rules give the same answer for a file born tomorrow, and the
 * plan regenerates its appendices from them in about a minute.
 *
 * HOW A PATH IS CLASSIFIED:
 * Today's trees are layer-first (infra/, adapters/, modules/, platform/,
 * ui/). The layer gives the sub-folder (modules and infra → engine, adapters
 * and platform → adapters, ui → ui, data → data); the first segment after
 * the layer, a folder name or a file stem, gives the feature through the
 * tables below. The rest of the path is kept, so tests/unit/infra/config/…
 * lands at tests/unit/settings/engine/… beside the code it covers.
 * ==============================================================================
 */

'use strict';

// ──────────────────────────────────────────────────────────────────────────────
// Feature vocabulary
// ──────────────────────────────────────────────────────────────────────────────

// The user-visible features, the same names on every tree. `core/<domain>`
// and `platform/<domain>` are the two cross-cutting roots.
const FEATURES = [
	'ai',
	'apps',
	'clipboard',
	'diagnostics',
	'gestures',
	'hotstrings',
	'layouts',
	'menu',
	'metrics',
	'onboarding',
	'keyboard',
	'settings',
	'shortcuts',
	'tap_hold',
	'tray',
	'updater'
];
const CORE_DOMAINS = [
	'crypto',
	'events',
	'fs',
	'i18n',
	'lifecycle',
	'logger',
	'network',
	'process',
	'text',
	'timing',
	'ui'
];
const PLATFORM_DOMAINS = ['desktop_focus', 'focus', 'input', 'native', 'system'];

// The sub-folders a feature (or a core domain) may hold, in this order.
const SUBS = ['engine', 'adapters', 'ui', 'data', 'native'];

// Today's folder names that already name a feature or a domain: the folder
// is absorbed into that root instead of nesting under it.
const ALIASES = {
	keystats: 'metrics',
	metrics: 'metrics',
	wpm: 'metrics',
	llm: 'ai',
	config: 'settings',
	settings: 'settings',
	scope: 'settings',
	preferences: 'settings',
	keymap: 'hotstrings',
	hotstrings: 'hotstrings',
	hotstring_engine: 'hotstrings',
	dynamic_hotstrings: 'hotstrings',
	layout: 'layouts',
	layouts: 'layouts',
	gestures: 'gestures',
	shortcuts: 'shortcuts',
	updater: 'updater',
	diagnostics: 'diagnostics',
	field_check: 'diagnostics',
	healthcheck: 'diagnostics',
	menu: 'menu',
	tray: 'tray',
	onboarding: 'onboarding',
	remap: 'keyboard',
	tap_hold: 'tap_hold',
	clipboard: 'clipboard',
	apps: 'apps',
	logger: 'core/logger',
	i18n: 'core/i18n',
	locale: 'core/i18n',
	lifecycle: 'core/lifecycle',
	network: 'core/network',
	toml: 'core/text',
	toml_codec: 'core/text',
	text: 'core/text',
	text_utils: 'core/text',
	timings: 'core/timing',
	timer: 'core/timing',
	file_system: 'core/fs',
	storage: 'core/fs',
	sqlite: 'core/fs',
	process: 'core/process',
	processes: 'core/process',
	crypto: 'core/crypto',
	webview: 'core/ui',
	tooltip: 'core/ui',
	input: 'platform/input',
	keyboard: 'platform/input',
	synthetic_input: 'platform/input',
	keyboard_hook: 'platform/input',
	system: 'platform/system',
	runtime: 'platform/system',
	// Folder names that exist only in today's test trees.
	dispatch: 'platform/input',
	uia: 'platform/focus',
	atspi: 'platform/focus',
	windows: 'core/ui',
	dialogs: 'core/ui',
	editors: 'core/ui',
	ui_builder: 'core/ui',
	hotstring_windows: 'hotstrings',
	hotstrings_config: 'hotstrings',
	composer_check: 'layouts',
	archive: 'updater',
	downloads: 'updater',
	manifest: 'menu',
	actions: 'shortcuts',
	contracts: 'core/lifecycle',
	shared_modules: 'core/lifecycle',
	native_artifacts: 'core/lifecycle',
	text_and_paths: 'core/text',
	personal_files: 'settings',
	karabiner_isolation: 'keyboard',
	vscode_bridge: 'core/network',
	file_watchers: 'core/fs',
	app_picker: 'apps',
	control: 'diagnostics',
	field_run: 'diagnostics',
	crash_report: 'diagnostics',
	shell_runner: 'core/process',
	log_transport: 'core/logger',
	compositor_focus: 'platform/focus',
	installed_source: 'layouts',
	runtime_capture: 'diagnostics',
	runtime_owner_ports: 'diagnostics',
	field_check_ports: 'diagnostics',
	prediction_tooltip_port: 'ai',
	karabiner_coexistence: 'keyboard'
};

// The aliases that are mere synonyms of their root: their folder dissolves
// into it. Any other alias (healthcheck, sqlite, tooltip, …) names a
// sub-module and stays as a folder under its root.
const SYNONYMS = new Set([
	'keystats',
	'metrics',
	'llm',
	'config',
	'settings',
	'hotstrings',
	'layouts',
	'gestures',
	'shortcuts',
	'updater',
	'diagnostics',
	'menu',
	'tray',
	'onboarding',
	'remap',
	'tap_hold',
	'clipboard',
	'apps',
	'logger',
	'i18n',
	'locale',
	'lifecycle',
	'network',
	'text',
	'timings',
	'file_system',
	'process',
	'processes',
	'crypto',
	'input',
	'system'
]);

// Ordered [root, pattern] pairs matched against a file stem (or a folder name)
// of today's infra/, modules/ and _shared/ trees. The first match wins.
const LOGIC_FEATURES = [
	[
		'diagnostics',
		/^(field_(check|run|probe|guided|todo)|startup_smoke|input_probe|diagnostic|error_(report|policy|description|net)|issue_|crash|redact|git_status|healthcheck|log_openers|console_window|adapter_errors)/
	],
	['tap_hold', /^(tap_hold|one_shot_shift)/],
	[
		'keyboard',
		/^(chord|tap_keys|sticky_modifiers|altgr|script_altgr|script_chord|capsword|caps_word|capslock|key_combination|nav_layer|wrap_pair|wrap_symbols|magic_editor|composed_text|suppressive_inputhook|slot_roles|remap|layers_loader|desktop_navigation)/
	],
	[
		'layouts',
		/^(layout|keyboard_layout|keylayout|xkb_|composer_check|input_sources|pending_layout|number_row|pause_layout|x11_layout|system_layout|managed_python)/
	],
	[
		'hotstrings',
		/^(hotstring|personal_hotstrings|user_hotstring|legacy_hotstring|dynamic_hotstrings|common_hotstrings|personal_info|expander|registry_|terminator|tap_copy|magic_key|section_keys|control_sentinels|selftest_gate|extension_packs|text_case|user_code)/
	],
	['metrics', /^(keystats|metrics|wpm|typed_input|phase_stats|hotpath)/],
	['ai', /^(llm|ai_|managed_ollama|ollama|mlx|prompt|prediction)/],
	['gestures', /^(gesture|touchpad|absolute_motion)/],
	[
		'shortcuts',
		/^(shortcut|personal_shortcuts|program_actions|user_actions?|user_action_parameter|action_parameter|brightness_actions|take_note|keep_awake|apple_shortcuts|physical_shortcut|open_target)/
	],
	['clipboard', /^(clipboard|selection)/],
	['updater', /^(updater|update_|release|asset_signature|archive_|version$)/],
	[
		'apps',
		/^(app_picker|app_folders|app_parameter|app_cloner|encryptor|bundled_apps|program_provider|secure_apps|linux_app_identities)/
	],
	['onboarding', /^(onboarding|first_boot|accessibility_wait|start_at_login|privacy_panes)/],
	['tray', /^(tray_|appindicator|tray$)/],
	['menu', /^(menu_|manifest_|feature_notice|native_presentation|ui_restore)/],
	[
		'settings',
		/^(config|preferences|scope_|.*_scope$|.*_preferences$|script_settings|script_config|script_override|script_scope|global_scope|feature_(io|state)|personal_(features|file|info_mask|info_preview|toml)|factory_reset|registry$|program_parameter|program_binding|owned_programs|send_input_parameter|llm_defaults|llm_context_limit|wpm_constants|metrics_state_keys|features$|legacy_folder|legacy_rules)/
	],
	[
		'core/logger',
		/^(logger|log_|bootstrap_log|perf|boot_profiler|tick_count|wall_clock|monotonic|.*_evidence$|key_event_health|keystroke_integrity|file_read_activity)/
	],
	[
		'core/timing',
		/^(timings?($|_)|paced_|native_timer|native_sleep|owned_timer|reload_timing|deferred_work)/
	],
	['core/i18n', /^(i18n|locale)/],
	[
		'core/network',
		/^(http_|managed_http|managed_redirect|proxy_|curl_|external_url|openssl_|fd_sha256|vscode_bridge|route_origins|network)/
	],
	[
		'core/fs',
		/^(file_|fs_|native_directory|native_path|regular_file|no_replace_move|corrupt_aside|private_sqlite|sqlite|user_private_group|paths$|config_paths|app_dirs|openstep_plist|storage_owned|module_source)/
	],
	[
		'core/text',
		/^(text_|json|number|source_text_codec|gvariant|toml|identifiers|unicode|table_util)/
	],
	[
		'core/lifecycle',
		/^(boot|startup_|teardown_|termination_|shutdown_|reload_|quit_|lifecycle|single_instance|instance_admission|suspend_|signal_handlers|restart_|daemon_restart|runtime_guard|launcher_|emergency_exit|session_lock|libuv_|main_thread_hold|uninstall|installation|bundle$|app_state|direct_require|literal_module_loader|bytecode_package|dev_source|master_gates|driver_control|account_name|reload_gate|quit_admission|native_worker_owner|compat|core$|control$)/
	],
	[
		'core/ui',
		/^(ui_style|webview|native_dialogs?|native_folder_picker|dialog_util|window_utils|window_titles|cursor_window_policy|native_theme|native_app_switcher|notifications|display_server|gui_stack|quit_request|color|file_selection|error_dialog)/
	],
	[
		'platform/input',
		/^(key_|keycodes|keysym|evdev_codes|hook_dispatcher|input_|device_|send_input)/
	],
	['platform/focus', /^application_notifier/],
	['core/process', /^(shell|process)/]
];

// Today's adapters/ and platform/ files: OS bindings.
const ADAPTER_FEATURES = [
	[
		'diagnostics',
		/^(boot_fatal|diagnostics_control|field_\w+_ports|runtime_\w+_ports?|event_provenance|foreign_ledger|metadata_command_stats|crash_report|console_window|reload_breadcrumb)/
	],
	[
		'clipboard',
		/^(clipboard|selection_transaction|wayland_selection|x11_selection|editor_replace|accessibility_copies|unicode_carrier|uia_selection)/
	],
	['tap_hold', /^one_shot_shift/],
	['keyboard', /^(karabiner|remap|system_switcher)/],
	[
		'layouts',
		/^(keyboard_layout|input_source|installed_physical_source|layout|xkb_|x11_keymap|keyboard_source)/
	],
	[
		'ai',
		/^(llm_|managed_ollama|ollama_|python_|native_python|native_bootstrap_pty|prediction_tooltip|mlx|source_alias_owner|suspended_image_owner|trusted_native_guardian)/
	],
	['shortcuts', /^(apple_shortcuts|physical_|window_switch|screen_brightness|mouse_control)/],
	['metrics', /^(wpm_surface|keystats)/],
	['updater', /^(updater_|update_launcher|release_stage)/],
	['apps', /^(bundled_apps|app_launcher|desktop_opener|desktop_application)/],
	['onboarding', /^(accessibility_permission|privacy_settings|tcc_grant)/],
	['tray', /^(tray_|notify_icon|appindicator)/],
	['core/logger', /^(log_transport|boot_journal)/],
	[
		'core/network',
		/^(http_client|curl_http_client|system_curl|network_|proxy_override|system_proxy|tcp_probe|gio_)/
	],
	[
		'core/process',
		/^(process_|shell_runner|owned_|program_|task_|sqlite_process_worker|uia_worker|crash_report_worker)/
	],
	[
		'core/fs',
		/^(storage|sqlite_native|toml_cache|ledger_append|file_|write_lock_path|json_codec|legacy_folder)/
	],
	['core/crypto', /^crypto/],
	[
		'core/events',
		/^(timer_scheduler|event_loop|event_clock|boot_clock|wake_watcher|physical_observation_clock)/
	],
	[
		'core/ui',
		/^(graphics_renderer|tooltip_renderer|webview_|native_folder_picker|native_text|native_number|spotlight_overlay|own_window|terminal_output)/
	],
	[
		'platform/focus',
		/^(window_|running_application|atspi_|compositor_focus|cosmic_toplevel|x11_focus|secure_field|application_notifier)/
	],
	[
		'platform/input',
		/^(keyboard_hook|key_state|hotkey_registrar|text_sender|synthetic_input|modifier_|uinput_writer|evdev_reader|input_probe|keyboard_geometry|send_input)/
	],
	['platform/system', /^(system_|screen_|power_source|notifier|tap_to_click|keyboard_)/]
];

// Today's ui/ windows and files.
const UI_FEATURES = [
	['menu', /^(menu|tray_menu)$/],
	['updater', /^(changelog|update_check|download_window|release_notes)$/],
	['diagnostics', /^(healthcheck|field_check|error_dialog|console_window|log_openers)$/],
	['settings', /^(config_cleanup|paths_editor|config_dir_picker|reload_refusal)$/],
	[
		'hotstrings',
		/^(hotstring_editor|hotstrings_config_window|personal_info_editor|personal_toml_editor(_webview)?)$/
	],
	['layouts', /^(layer_editor|layout_manager|layout_composer|layout_editor)$/],
	['shortcuts', /^(physical_shortcuts|action_picker(_webview)?|user_action_editor)$/],
	[
		'ai',
		/^(model_browser|prompt_editor|llm_enable_refusal|vision_parameter_prompt|owned_runtime_install|python_runtime_offer)$/
	],
	['metrics', /^(metrics_apps|metrics_typing|wpm|metrics_flush_bridge)$/],
	['onboarding', /^(onboarding|permission_dialog)$/],
	['gestures', /^(gesture_conflicts?|gesture_conflict_notice)$/],
	[
		'apps',
		/^(app_chooser|bundled_apps|app_cloner_python_offer|desktop_application_resolution(_worker)?)$/
	],
	['keyboard', /^(virtual_hid_update|legacy_rules_cleanup)$/],
	['core/network', /^proxy_override$/],
	[
		'core/ui',
		/^(tooltip|spotlight|numeric_prompt|token_prompt|text_prompt|choice_prompt|modal|native_dialog|dialog_host|webview_manager|webkit_host|webview_controller_pool|webview_close_owner|ui_builder|window_toggle|editors)$/
	]
];

// _shared/modules/<x> and _shared/data/<x>: data files, by name.
const DATA_FEATURES = [
	['core/timing', /^timings$/],
	['core/logger', /^logger$/],
	['core/i18n', /^(locales|locale_)/],
	['core/network', /^(network|http|owned_runtimes|linux_native_runtime)/],
	['core/fs', /^paths$/],
	['core/ui', /^(tooltip|native_theme)/],
	['core/text', /^identifiers/],
	['core/crypto', /^crypto$/],
	['hotstrings', /^(hotstrings|personal_info)$/],
	['layouts', /^(layouts|keycodes)$/],
	['ai', /^llm$/],
	['menu', /^menu$/],
	['updater', /^(updater|linux_appimage)/],
	['metrics', /^(wpm_widget|keystats_|metrics_|db$)/],
	['shortcuts', /^(actions|shortcuts)$/],
	['settings', /^(config|features)$/],
	['diagnostics', /^(control|diagnostics|field_)/],
	['keyboard', /^wrap_symbols$/],
	['apps', /^(app_cloner|encryptor)$/]
];

// Test data folders (fixtures, support, hardware proofs, the shared Lua
// contract tests) split by the feature their file names start with.
const TEST_DATA_FEATURES = [
	['metrics', /^(keystats|metrics|wpm|roi|ngram)/],
	['ai', /^(llm|ollama|mlx|model|prompt|prediction|agent|translate|vision)/],
	['layouts', /^(layout|keylayout|xkb|xi2|keymap|phys|physical|keyboard|led|magic)/],
	['updater', /^(updater|update|release|download|bundle)/],
	['gestures', /^(gesture|touchpad|trackpad)/],
	['hotstrings', /^(hotstring|personal|terminator|sendinstant|user)/],
	['menu', /^(menu|tray|sni)/],
	['settings', /^(config|toml|paths|profile|pause|script|scope)/],
	['onboarding', /^onboarding/],
	['keyboard', /^(sticky|wrap|chord|tap|caps)/],
	['clipboard', /^clipboard/],
	[
		'core',
		/^(input|synthetic|virtual|fake|key|text|plain|native|context|action|webview|ui|tooltip|window|healthcheck|application|screen|wayland|secure|atspi|desktop|system|managed|winhttp|network|proxy|sqlite|session|startup|logger|lib|validate|runner|local|hotpath)/
	]
];

// File stems inside today's modules/<feature>/ that bind the OS.
const OS_BINDING =
	/(touchpad|_hid$|^raw_|virtual_desktops|screenshots|pointer_warp|workspace_switcher|window_cycle|native_app_switcher|_native$|_worker(_entry)?$|^x11_|wayland|atspi|^uia_|_watcher$|kc_bridge|network_watcher|topology_watcher|clipboard_telemetry)/;

// The sections of the tray menu that belong to one feature, by the name of
// the section (menu_<name>, or a row builder named after the feature).
const MENU_SECTIONS = [
	['gestures', /^gestures?/],
	['hotstrings', /^(hotstring|programmatic_hotstrings|magic_key)/],
	['metrics', /^(metrics|wpm)/],
	['shortcuts', /^(shortcuts?|shortcut_utils)/],
	['apps', /^(apps|app_exclusion_rows)/],
	['ai', /^(llm|ai_parent|agent|local_server_rows)/],
	['tap_hold', /^(tap_holds?|taphold|tap_keys)/],
	[
		'layouts',
		/^(keyboard_layout|layouts?|active_layout_rows|pause_layout_rows|quit_layout|keyboard_slots)/
	],
	['keyboard', /^(caps_word|key_combinations)/],
	[
		'settings',
		/^(paths|configuration|language|scoped_preferences|preferences_transaction|unused_keys_cleanup)/
	],
	['diagnostics', /^debug/],
	['updater', /^about/],
	['onboarding', /^start_at_login/]
];

// ──────────────────────────────────────────────────────────────────────────────
// Second-level splits of oversized sub-folders
// ──────────────────────────────────────────────────────────────────────────────

const SPLITS = {
	'metrics/engine': {
		strip: /^keystats_/,
		table: [
			[
				'reader',
				/^(reader|sqlite_reader|ledger_replay|rebuild|export|ngrams?|frames|partial|query)/
			],
			[
				'journal',
				/^(journal|llm_journal|hotstring_log|hotstring_units|log_manager|rotation|rollover|sql|sqlite_writer|maintenance|prefetch|buffer_snapshot|event_id|timestamp|ingest|write)/
			],
			['walker', /^walker/],
			[
				'capture',
				/^(hook|mouse|device|clipboard|physical|kc_bridge|sensors|collection|password|av_state|host_signature)/
			],
			['apps', /^(app_categor|apps_editor)/],
			[
				'system',
				/^(system_|session_events|virtual_desktop|window_topology|topology|watchers|network|shutdown|health)/
			],
			['privacy', /^(roi|trigger_roi|privacy|text_cipher|text_migration|text_crypto|token)/],
			['aggregator', /^aggregator/],
			['perf', /^(hotpath|phase_stats)/],
			['wpm', /^(live_wpm|wpm)/],
			['media', /^media_/],
			['view', /^(ui|webview|private_window|manifest_keys|filters|shortcuts)/]
		]
	},
	'ai/engine': {
		strip: /^llm_(?!request)/,
		table: [
			[
				'settings',
				/^(profiles?|profile_settings|settings|.*_settings|enable_admission|api_key_migration|api_entries|api_token_store|error_log|display|models)/
			],
			[
				'api',
				/^(api_|remote_formats|request_plan|option_validation|parser|rs256_signer|streaming_handler|stream_payload|backend_|provider_uses|thinking_families|opaque_network|proxy_relay|network_env|context$)/
			],
			['ollama', /^(ollama|managed_ollama|local_model|ensure-ollama)/],
			[
				'local_servers',
				/^(local_server|warmup|owned_timer|runtime_|inference|model_|mlx|api_mlx|ensure-mlx)/
			],
			[
				'bootstrap',
				/^(managed_|native_python|boot_cleanup|bootstrap_|dependency_|ensure-|network-retry|uv-release|pty_process|.*-release)/
			],
			[
				'prediction',
				/^(prediction|prompt_|progressive_reveal|screen_answer|selection_|tone|rewrite|translat|vision|llm_request_latency|app_filter)/
			],
			['agent', /^agent/],
			[
				'policy',
				/(_policy$|_classifier$|^(failure_class|thinking_off|temperature|process_limits|provider_config|config_guard|app_identity|app_profile|process_port|finite_process_port|context_buffer))/
			]
		]
	},
	'menu/ui': {
		strip: /^menu_/,
		table: [
			['llm', /^(llm|ai_parent|agent|local_server_rows|chatgpt_url)/],
			['hotstrings', /^(hotstring|programmatic_hotstrings|magic_key)/],
			[
				'keyboard',
				/^(keyboard|layout|tap|taphold|caps_word|active_layout_rows|pause_layout_rows|key_combinations|quit_layout|keymap_lifecycle|base_delay)/
			],
			[
				'features',
				/^(apps|gestures|metrics|shortcuts|paths|app_exclusion_rows|metrics_scope|gesture_scope|shortcut_utils|shortcuts_scope|hotstrings_scope|llm_scope)/
			],
			[
				'transactions',
				/_transaction$|^(scoped_preferences|session_demotions|recoverable_file_moves|refresh_scope|global_scope|unused_keys_cleanup|uninstall|start_at_login|profile_editor_request)/
			],
			[
				'builder',
				/^(builder|engine|init|rebuild|submenus|state|utils|watchers|actions|about|configuration|debug|dialogs|language|quit|reload|branch_rows|canvas_badge|click_gate|rebuild_owner|timed_build|feature_notice|hotstring_order|hotstring_switches)/
			]
		]
	},
	'ai/ui/menu': {
		strip: /^menu_/,
		table: [
			['models', /^(models?_|custom_models|mlx_|ollama_|models$)/],
			['panels', /_panel$/]
		]
	},
	'settings/engine': {
		strip: null,
		table: [
			[
				'migration',
				/^(config_(migrate|obsolete|outdated|unused|file_inverse|cleanup|transition)|legacy_)/
			],
			[
				'publication',
				/(_publication$|^config_(binding|reset|save|write_lease|registry_cache|user_models|defaults|keyboard))/
			],
			[
				'scope',
				/(_scope$|^scope_|^config_scope|^config_global_scope|^global_scope|^script_scope|^script_)/
			],
			[
				'preferences',
				/(preferences$|^script_settings|^personal_|^feature_(io|state)|^program_binding|^owned_programs)/
			]
		]
	},
	'core/lifecycle/engine': {
		strip: null,
		table: [
			['reload', /^(reload|restart|daemon_restart|single_instance|instance_admission|suspend_)/],
			[
				'shutdown',
				/^(quit|shutdown|termination|teardown|signal_handlers|emergency_exit|libuv_exit|session_lock|uninstall)/
			]
		]
	},
	'keyboard/engine': {
		strip: null,
		table: [
			[
				'keys',
				/^(altgr|backspace|capslock|delete|enter|escape|lalt|lshift|rctrl|rshift|space|tab|win|key_combination|constants)/
			],
			['layers', /^(nav_layer|layers_loader|scope_layer|script_chord|chord|sticky)/],
			[
				'runtime',
				/^(runtime_|ke_|lease_|deploy_pacing|managed_rule|token_reuse|legacy_release|guardian|generator|action_catalogue|watchers|config|defaults|onboarding|init)/
			]
		]
	},
	'hotstrings/engine': {
		strip: null,
		table: [
			[
				'matcher',
				/^(hotstring_|terminator|preview_switches|expander|registry|tap_copy|section_keys|control_sentinels|selftest_gate|state|utils)/
			],
			[
				'catalogue',
				/^(hotstrings_|personal_|extension_packs|common_autocorrection|programmable|catalogue)/
			],
			['dynamic', /^(dynamic|user_code|date|personal_info|fields)/]
		]
	},
	'diagnostics/engine': {
		strip: null,
		table: [
			['field_check', /^field_(check|probe)/],
			['field_run', /^(field_run|field_guided|startup_smoke|input_probe)/],
			['reports', /^(crash|diagnostic|error_|issue_|redact|git_status)/]
		]
	},
	'keyboard/adapters': {
		strip: null,
		table: [
			['runtime', /^(runtime_|deploy_pacing|guardian|managed_rule|token_reuse)/],
			['karabiner', /^(ke_|lease_|karabiner)/]
		]
	},

	'core/ui/engine': {
		strip: null,
		table: [
			['webview', /^webview/],
			['tooltip', /^tooltip/]
		]
	},
	'core/text/engine': {
		strip: null,
		table: [['toml', /^toml/]]
	},
	'layouts/engine': {
		strip: null,
		table: [
			['composer', /^(composer|source_|xkb_converter|keylayout|extension|catalogue)/],
			['layers', /^(layer|control_signals|magic_key|terminators)/],
			['registry', /^(layout_registry|registry|layout_rows|layouts?_)/],
			['emulation', /^(layout_emulation|emulation|number_row|pause_layout|x11_layout)/]
		]
	}
};

// ──────────────────────────────────────────────────────────────────────────────
// OS-specific folders allowed on one driver only
// ──────────────────────────────────────────────────────────────────────────────

const OS_SPECIFIC = {
	macos: {
		launcher: 'the Swift host application of the macOS runtime',
		'keyboard/data': 'Karabiner remap data that only the macOS remap runtime reads',
		'onboarding/ui': 'the macOS privacy (TCC) grant walkthrough lives here'
	},
	linux: {
		install: 'the shell installers and launcher the Linux package runs before LuaJIT',
		'platform/desktop_focus': 'GNOME Shell and KWin code reading the focused window under Wayland',
		'updater/native': 'the O_TMPFILE/linkat archive publication of the Linux updater'
	},
	windows: {
		'layouts/native': 'the keyboard DLL sources generated from the .keylayout',
		'platform/native': 'the WH_KEYBOARD_LL component owning navigation events'
	}
};

// ──────────────────────────────────────────────────────────────────────────────
// Path mapping
// ──────────────────────────────────────────────────────────────────────────────

const DRIVERS = ['windows', 'macos', 'linux'];

/** The stem used for classification: no extension, test markers or prefixes. */
function classStem(name, strip) {
	let stem = name.replace(/\.[^.]+$/, '').replace(/\.[^.]+$/, '');
	stem = stem.replace(/^(test|run|fixture|spec)_/, '').replace(/_(test|spec)$/, '');
	if (strip) stem = stem.replace(strip, '');
	return stem;
}

function classify(table, stem) {
	const hit = table.find(([, re]) => re.test(stem));
	return hit ? hit[0] : null;
}

/** True when a root is a cross-cutting domain, which has no feature sub-folders. */
const isPlatform = (root) => root.startsWith('platform/');

/**
 * Builds a target from a feature root, a sub-folder and the remaining path.
 * platform/ roots are OS bindings throughout and take no sub-folder.
 */
function place(root, sub, rest) {
	const parts = isPlatform(root) ? [root, ...rest] : [root, sub, ...rest];
	return applySplits(parts.join('/'));
}

/**
 * Classifies the segment that follows a layer: a folder name or a file stem.
 * @returns {{root: string, absorb: boolean}|null}
 */
function rootOf(table, segment, isFile) {
	const stem = isFile ? classStem(segment) : segment;
	if (!isFile && ALIASES[stem]) return { root: ALIASES[stem], absorb: SYNONYMS.has(stem) };
	const root = classify(table, stem) || (isFile ? null : classify(table, classStem(segment)));
	return root ? { root, absorb: false } : null;
}

/**
 * Maps the code part of a driver path (tests prefix removed).
 * @param {string} rel e.g. "infra/logger.lua" or "ui/changelog/bridge.lua".
 * @param {string} tree The driver.
 * @returns {string} The target path relative to the driver root.
 */
function mapCode(rel, tree) {
	const parts = rel.split('/');
	const [layer, segment] = parts;
	if (parts.length < 2) return rel;
	const isFile = parts.length === 2;
	const rest = parts.slice(2);
	const keep = (hit) => (hit.absorb || isFile ? (isFile ? [segment] : rest) : [segment, ...rest]);

	if (layer === 'modules') {
		// keymap holds the hotstring expander on macOS and the layout code on
		// every driver: each file goes to its own feature.
		if (segment === 'keymap' && !isFile) {
			if (rest[0] === 'layout' && rest.length > 1) return place('layouts', 'engine', rest.slice(1));
			if (rest[0] === 'keylayout') return place('layouts', 'engine', rest);
			const own = rest.length === 1 ? classify(LOGIC_FEATURES, classStem(rest[0])) : null;
			if (own && own !== 'hotstrings') return place(own, 'engine', rest);
			// The rest of keymap is the macOS hotstring expander: a sub-module of
			// hotstrings, kept apart from modules/hotstrings so the two never meet.
			return place('hotstrings', 'engine', ['expander', ...rest]);
		}
		if (segment === 'dynamic_hotstrings' && !isFile)
			return place('hotstrings', 'engine', ['dynamic', ...rest]);
		const hit = rootOf(LOGIC_FEATURES, segment, isFile);
		if (!hit || !hit.root) return rel;
		// A flat module file is the feature's entry point and stays at its root.
		if (isFile && ALIASES[classStem(segment)]) return `${hit.root}/${segment}`;
		// Inside a feature module, a file whose name says it binds the OS goes
		// to the feature's adapters/, the rest to its engine/.
		const leaf = parts[parts.length - 1];
		const sub = OS_BINDING.test(classStem(leaf)) ? 'adapters' : 'engine';
		return place(hit.root, sub, keep(hit));
	}
	if (layer === 'infra' || layer === 'adapters' || layer === 'platform') {
		const sub = layer === 'infra' ? 'engine' : 'adapters';
		if (layer === 'platform' && !isFile) {
			if (segment === 'remap') {
				const leaf = rest[rest.length - 1];
				const stem = classStem(leaf);
				if (rest.length === 1 && /^tap_hold/.test(stem)) return place('tap_hold', 'engine', rest);
				if (rest[0] === 'data') return place('keyboard', 'data', rest.slice(1));
				if (
					rest.length === 1 &&
					/^(runtime_|ke_|lease_|deploy_pacing|managed_rule|token_reuse|guardian)/.test(stem)
				)
					return place('keyboard', 'adapters', rest);
				return place('keyboard', 'engine', rest);
			}
			if (segment === 'network') return place('core/network', 'adapters', rest);
			if (segment === 'tray') return place('tray', 'adapters', rest);
		}
		const table = layer === 'infra' ? LOGIC_FEATURES : ADAPTER_FEATURES;
		// A file no table places (mostly cross-port tests such as the adapter
		// compliance suite) goes to the layer's default domain, never back to a
		// layer folder that no longer exists.
		const hit = rootOf(table, segment, isFile) ||
			rootOf(layer === 'infra' ? ADAPTER_FEATURES : LOGIC_FEATURES, segment, isFile) || {
				root: layer === 'infra' ? 'core/lifecycle' : 'platform/system',
				absorb: false
			};
		return place(hit.root, sub, keep(hit));
	}
	if (layer === 'ui') {
		const stem = isFile ? classStem(segment) : segment;
		const root =
			classify(UI_FEATURES, stem) || (ALIASES[stem] && !isFile ? ALIASES[stem] : null) || 'core/ui';
		const absorbed = !isFile && ALIASES[stem] === root && SYNONYMS.has(stem);
		// The tray menu's builder stays in menu/; each feature's own section of
		// the menu moves to that feature's ui/menu/, beside its other windows.
		if (absorbed && root === 'menu' && rest[0] === 'menu_llm')
			return place('ai', 'ui', ['menu', ...rest.slice(1)]);
		if (absorbed && root === 'menu' && rest.length === 1) {
			const section = classStem(rest[0]).replace(/^menu_/, '');
			const owner = MENU_SECTIONS.find(([, re]) => re.test(section));
			if (owner) return place(owner[0], 'ui', ['menu', rest[0]]);
		}
		return place(root, 'ui', isFile || absorbed ? (isFile ? [segment] : rest) : [segment, ...rest]);
	}
	if (layer === 'native') {
		if (segment === 'keyboard_layout') return ['layouts', 'native', ...parts.slice(1)].join('/');
		if (segment === 'archive_output') return ['updater', 'native', ...parts.slice(1)].join('/');
		if (segment === 'nav_event_owner') return ['platform', 'native', ...parts.slice(1)].join('/');
		if (isFile) return place('shortcuts', 'native', [segment]);
	}
	if (layer === 'data' && isFile) {
		const stem = classStem(segment);
		const root =
			classify(
				[
					['diagnostics', /^field_/],
					['onboarding', /^privacy_panes/],
					['ai', /^generate_models/]
				],
				stem
			) || 'settings';
		return place(root, 'data', [segment]);
	}
	return rel;
}

/** Applies the second-level split of the folder a file sits directly in. */
function applySplits(rel) {
	const parts = rel.split('/');
	const name = parts[parts.length - 1];
	const folder = parts.slice(0, -1).join('/');
	const split = SPLITS[folder];
	if (!split || /^(README\.md|init\.(lua|ahk)|_index\.ahk)$/.test(name)) return rel;
	const sub = classify(split.table, classStem(name, split.strip));
	return sub ? applySplits(`${folder}/${sub}/${name}`) : rel;
}

/**
 * True when a path already has the target shape: a feature folder, a
 * core/<domain> or platform/<domain> folder, or (in _shared) the folders that
 * keep their place. Today's homonyms are told apart: _shared/tap_hold/data/ held
 * flat data files, _shared/core/ held config_schema/ and domain/, and the
 * drivers' platform/ held remap/, network/, tray/ and flat files.
 */
function isTargetShaped(tree, parts) {
	let p = parts;
	if (p[0] === 'tests') {
		if (tree === '_shared')
			return ['lua', 'corpus', 'fixtures', 'conformance'].includes(p[1]) && p[1] !== 'lua'
				? true
				: p[1] === 'lua' && p.length > 3;
		if (!/^(unit|meta|integration|contract|e2e|fixtures|support|hardware)$/.test(p[1] || ''))
			return false;
		p = p.slice(2);
	}
	const [first, second] = p;
	if (p.length < 2) return false;
	if (first === 'core') {
		if (tree === '_shared' && (second === 'ports' || second === 'features.json')) return true;
		return CORE_DOMAINS.includes(second) && p.length > 2;
	}
	if (first === 'platform') return PLATFORM_DOMAINS.includes(second) && p.length > 2;
	if (!FEATURES.includes(first)) return false;
	if (tree === '_shared' && first === 'tap_hold' && p.length === 2) return false;
	return true;
}

/**
 * Maps one tree-relative path ("linux/core/logger/engine/sink.lua") to its target,
 * before the singleton pass.
 */
function mapPath(treeRel) {
	const [tree, ...restParts] = treeRel.split('/');
	const rest = restParts.join('/');
	// Already in the target tree: the rules are idempotent, so a step
	// recomputed after its predecessors have landed moves nothing twice.
	if (isTargetShaped(tree, restParts)) return treeRel;
	if (tree === '_shared') return `_shared/${mapShared(rest)}`;
	if (!DRIVERS.includes(tree)) return treeRel;

	// Linux-only folders folded into their roots (see OS_SPECIFIC).
	if (tree === 'linux' && rest.startsWith('desktop_focus/')) return `linux/platform/${rest}`;
	if (tree === 'linux' && rest.startsWith('bin/')) return `linux/install/${rest.slice(4)}`;
	if (tree === 'macos' && rest.startsWith('apps/')) return `macos/apps/bundled/${rest.slice(5)}`;

	const test = rest.match(/^tests\/(unit|meta|integration|contract|e2e)\/(.+)$/);
	if (test) return `${tree}/tests/${test[1]}/${mapCode(test[2], tree)}`;
	// Support and fixture folders that mirror a code layer follow that layer.
	const mirrored = rest.match(
		/^tests\/(fixtures|support)\/((?:infra|adapters|modules|platform|ui)\/.+)$/
	);
	if (mirrored) return `${tree}/tests/${mirrored[1]}/${mapCode(mirrored[2], tree)}`;
	const data = rest.match(/^tests\/(fixtures|support|hardware)\/([^/]+)$/);
	if (data) {
		const feature = classify(TEST_DATA_FEATURES, classStem(data[2]));
		return feature ? `${tree}/tests/${data[1]}/${feature}/${data[2]}` : treeRel;
	}
	if (rest.startsWith('tests/')) return treeRel;
	return `${tree}/${mapCode(rest, tree)}`;
}

/** _shared: the same feature roots; Lua under engine/, pages under ui/, data under data/. */
function mapShared(rest) {
	const parts = rest.split('/');
	const [root, segment] = parts;
	const isFile = parts.length === 2;
	const tail = parts.slice(2);
	if (root === 'lua') {
		if (segment === 'test') {
			const leaf = parts[2];
			if (parts.length !== 3) return ['tests', 'lua', ...parts.slice(2)].join('/');
			const f =
				classify(TEST_DATA_FEATURES, classStem(leaf)) || classify(LOGIC_FEATURES, classStem(leaf));
			return ['tests', 'lua', ...(f ? [f.replace(/\//g, '_')] : []), leaf].join('/');
		}
		if (segment === 'test_support' || segment === 'tests') return rest;
		if (segment === 'keymap' && !isFile) return place('layouts', 'engine', tail);
		// The same sub-module names the drivers use for these.
		if (segment === 'dynamic_hotstrings' && !isFile)
			return place('hotstrings', 'engine', ['dynamic', ...tail]);
		if (segment === 'hotstring_engine' && !isFile)
			return place('hotstrings', 'engine', ['matcher', ...tail]);
		const hit =
			rootOf(LOGIC_FEATURES, segment, isFile) ||
			(isFile ? null : rootOf(LOGIC_FEATURES, segment, true));
		if (!hit) return rest;
		const kept = isFile ? [segment] : hit.absorb ? tail : [segment, ...tail];
		return place(hit.root, 'engine', kept);
	}
	// _shared/ui/ is the webview document root: hosts build _shared/ui/<page>
	// at runtime, pages import ../dom_utils.js, and the WebViews are allowed
	// to read that one tree. It keeps its place (decided by the coordinator on
	// 2026-11-11, to review by the maintainer); its page names already name
	// their feature.
	if (root === 'ui') return rest;
	// The hotstring catalogue is read as a directory tree (every pack under it
	// loads), so it keeps a folder of its own instead of absorbing the
	// feature's data folder, where personal_info/ and autocorrection/ land.
	if (root === 'modules' && segment === 'hotstrings' && !isFile)
		return place('hotstrings', 'data', ['catalogue', ...tail]);
	if (root === 'modules' || root === 'data') {
		const stem = isFile ? classStem(segment) : segment;
		const feature = classify(DATA_FEATURES, stem);
		if (!feature) return rest;
		// modules/<feature>/ is the feature's data folder and dissolves into it;
		// a data/<folder>/ beside it keeps a name, so the two never meet.
		const absorbed =
			root === 'modules' && !isFile && ALIASES[segment] === feature && SYNONYMS.has(segment);
		const named = root === 'data' && segment === 'hotstrings' ? 'autocorrection' : segment;
		return place(feature, 'data', isFile || !absorbed ? [named, ...tail] : tail);
	}
	if (root === 'core') {
		if (segment === 'config_schema') return place('settings', 'data', ['config_schema', ...tail]);
		if (segment === 'domain') return place('core/text', 'data', ['domain', ...tail]);
		return rest; // core/ports and core/features.json keep their place
	}
	if (root === 'keymap') return place('layouts', 'data', [segment]);
	if (root === 'tap_hold') return place('tap_hold', 'data', parts.slice(1));
	if (root === 'ahk')
		return segment === 'tap_hold'
			? place('tap_hold', 'engine', tail)
			: place('settings', 'engine', [segment]);
	if (root === 'assets') return place('tray', 'data', [segment]);
	if (root === 'python')
		return place(/^network_proxy/.test(segment) ? 'core/network' : 'ai', 'adapters', [
			'python',
			segment
		]);
	if (root === 'go') return place('core/network', 'native', ['go', ...parts.slice(1)]);
	if (root === 'native') return place('core/network', 'native', parts.slice(2));
	return rest;
}

// ──────────────────────────────────────────────────────────────────────────────
// Module names built at runtime
// ──────────────────────────────────────────────────────────────────────────────

// A Lua module name completed at runtime ("modules.llm." .. name) cannot be
// found by a token scan. Each such site is listed with the names it builds,
// so the plan can prove the new prefix reaches every one of them, and the
// applier rewrites the prefix in that file only.
const RUNTIME_PREFIXES = [
	{
		file: 'linux/infra/llm_scope.lua',
		old: 'modules.llm.',
		names: [
			'settings',
			'trigger_settings',
			'display_settings',
			'navigation_settings',
			'profile_settings',
			'agent_settings',
			'profiles'
		]
	},
	{
		file: 'linux/settings/ui/menu/unused_keys_cleanup.lua',
		old: 'modules.llm.',
		names: [
			'settings',
			'trigger_settings',
			'display_settings',
			'navigation_settings',
			'profile_settings'
		]
	},
	{
		file: 'linux/tests/unit/modules/llm/runtime/test_scope_native_ack.lua',
		old: 'modules.llm.',
		names: ['api_ollama', 'api_remote']
	},
	{
		file: 'macos/tests/support/llm_count_menu_fixture.lua',
		old: 'ui.menu.menu_llm.',
		names: ['temperature_panel', 'streaming_panel', 'trigger_panel']
	},
	{
		file: 'macos/tests/support/physical_shortcut_registrar_fixture.lua',
		old: 'modules.shortcuts.actions.',
		names: ['text', 'apps', 'system']
	},
	{
		file: 'macos/tests/support/physical_shortcut_scope_fixture.lua',
		old: 'modules.shortcuts.actions.',
		names: ['text', 'apps', 'system']
	},
	{
		file: 'macos/tests/support/shortcuts_scope_fixture.lua',
		old: 'modules.shortcuts.actions.',
		names: ['text', 'apps', 'system']
	},
	{
		file: 'macos/tests/unit/menu/ui/state/test_boot_saves_read_only.lua',
		old: 'modules.shortcuts.',
		// config-key-literal-ok: these are folder names that share a config key's spelling.
		names: ['bindings', 'keyboard_shortcuts', 'tap_keys', 'script_control']
	}
];

// A runtime-built name whose modules land under different prefixes: the site
// is rewritten by a literal edit, and the plan checks that each old module
// name reaches the new one the edit spells.
const RUNTIME_EDITS = [
	{
		file: 'macos/tests/meta/boot/test_startup_optimizations.lua',
		from: `for _, name in ipairs({ "gestures", "keymap", "shortcuts", "dynamic_hotstrings" }) do
			local loaded = src:find('require("modules.' .. name .. '")', 1, true)`,
		to: `for _, name in ipairs({ "gestures.engine", "hotstrings.engine.expander", "shortcuts.engine", "hotstrings.engine.dynamic" }) do
			local loaded = src:find('require("' .. name .. '")', 1, true)`,
		expect: [
			['macos', 'modules.gestures', 'gestures.engine'],
			['macos', 'modules.keymap', 'hotstrings.engine.expander'],
			['macos', 'modules.shortcuts', 'shortcuts.engine'],
			['macos', 'modules.dynamic_hotstrings', 'hotstrings.engine.dynamic']
		],
		prefix: 'modules.'
	}
];

/** The old module names a runtime site builds: they keep their file names. */
function pinnedModules() {
	const out = new Set();
	// By old module name, and by file stem in its tree, so a step recomputed
	// after the move (where the old name is gone) keeps the pin.
	for (const r of RUNTIME_PREFIXES)
		for (const n of r.names)
			out.add(`${r.file.split('/')[0]}|${r.old}${n}`).add(`${r.file.split('/')[0]}|stem:${n}`);
	for (const e of RUNTIME_EDITS) for (const [tree, old] of e.expect) out.add(`${tree}|${old}`);
	return out;
}

// ──────────────────────────────────────────────────────────────────────────────
// Prefix renames (decided by the maintainer on 2026-11-11)
// ──────────────────────────────────────────────────────────────────────────────

// Names a file keeps whatever prefix it carries: an entry point a loader looks
// for by name, or a name too short to say anything once stripped.
const RESERVED_STEMS = new Set([
	'init',
	'index',
	'main',
	'_index',
	'readme',
	'core',
	'test',
	'run',
	'spec',
	'fixture'
]);

// Only source files are renamed: data files, pages and assets are read by name.
const RENAMED_EXTENSIONS = new Set(['.lua', '.ahk']);

/** The singular a feature name has as a file prefix (layouts → layout_). */
function singular(name) {
	return name.endsWith('s') ? name.slice(0, -1) : name;
}

/**
 * The prefixes a file's name may repeat once it sits in its feature folder:
 * the feature (and its singular), every old folder name that is a synonym
 * of that feature (keystats, llm, …), and each folder between the feature
 * and the file. A prefix whose folder was folded away stays: menu_x.lua that
 * lands directly in <feature>/ui/ keeps saying it is a menu section.
 * @param {string} oldRel Path relative to its tree today.
 * @param {string} newRel Path relative to its tree after the move.
 */
function redundantPrefixes(oldRel, newRel) {
	const target = newRel.split('/');
	const isTest = target[0] === 'tests';
	const inner = isTest ? target.slice(2) : target;
	// Only files inside a feature, core/<domain> or platform/<domain> folder.
	const cross = ['core', 'platform'].includes(inner[0]);
	if (inner.length < (cross ? 3 : 2) || (!cross && !FEATURES.includes(inner[0]))) return [];
	const root = cross ? inner.slice(0, 2).join('/') : inner[0];
	const out = new Set();
	const last = root.split('/').pop();
	out.add(last).add(singular(last));
	for (const [alias, value] of Object.entries(ALIASES))
		if (value === root && SYNONYMS.has(alias)) out.add(alias).add(singular(alias));
	for (const folder of inner.slice(root.split('/').length, -1)) {
		if (!SUBS.includes(folder)) out.add(folder).add(singular(folder));
	}
	return [...out].filter((p) => p.length >= 2).sort((a, b) => b.length - a.length);
}

/**
 * The name a moved source file takes: its leading redundant prefixes
 * stripped (keystats_walker.ahk in metrics/engine/walker/ → walker.ahk), as
 * long as something meaningful remains. A test keeps its test_ marker. The
 * caller keeps the old name when the new one is not unique in its folder.
 * @returns {string} The file name, unchanged when nothing applies.
 */
function strippedName(oldRel, newRel) {
	const name = newRel.split('/').pop();
	const ext = name.slice(name.lastIndexOf('.'));
	if (!RENAMED_EXTENSIONS.has(ext) || /(^|\/)(_generated|vendor|data)\//.test(newRel)) return name;
	let stem = name.slice(0, -ext.length);
	const marker = (stem.match(/^(test_|run_)/) || [''])[0];
	stem = stem.slice(marker.length);
	const prefixes = redundantPrefixes(oldRel, newRel);
	for (let changed = true; changed; ) {
		changed = false;
		for (const p of prefixes) {
			if (!stem.startsWith(`${p}_`)) continue;
			const rest = stem.slice(p.length + 1);
			if (rest.length < 2 || /^\d/.test(rest) || RESERVED_STEMS.has(rest)) continue;
			stem = rest;
			changed = true;
			break;
		}
	}
	return `${marker}${stem}${ext}`;
}

module.exports = {
	FEATURES,
	CORE_DOMAINS,
	PLATFORM_DOMAINS,
	SUBS,
	ALIASES,
	OS_SPECIFIC,
	SPLITS,
	classStem,
	strippedName,
	RUNTIME_PREFIXES,
	RUNTIME_EDITS,
	pinnedModules,
	mapPath
};
