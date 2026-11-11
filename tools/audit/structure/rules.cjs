// tools/audit/structure/rules.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Target Rules (Rule B)
 * DESCRIPTION:
 * The proposed target tree of docs/design/structure-plan.md, written as data
 * so the move map is computed rather than typed: one vocabulary of domain and
 * sub-module names, applied identically to windows/, macos/, linux/ and to
 * _shared/lua/, so a file named the same way lands at the same place on every
 * driver.
 *
 * WHY RULES AND NOT A HAND-WRITTEN MAP:
 * About ten thousand files are concerned and several sessions keep adding new
 * ones. A hand-written map is stale the day after it is written; rules give
 * the same answer for a file born tomorrow, and the plan regenerates its
 * appendices from them in seconds.
 *
 * WHAT IT DECIDES (decided by the coordinator on 2026-11-11, to review by the
 * maintainer):
 * 1. The top level keeps the layers every driver already has (adapters,
 *    infra, modules, platform, ui, native, data, apps, vendor, _generated,
 *    tests). Only folders outside the 2..20 entry bounds, and names that
 *    differ between drivers, move.
 * 2. Flat oversized folders split by DOMAIN: the same names under infra/,
 *    adapters/ and _shared/lua/.
 * 3. ui/ groups its windows: menu, panels, editors, dialogs, overlays, shell.
 * 4. A folder left with one file becomes that file, named after the folder
 *    (init.lua and bridge.lua take the folder name).
 * 5. A folder holding only a Convention S README is retired: its absence is
 *    declared in _shared/core/features.json instead of by an empty folder.
 * ==============================================================================
 */

'use strict';

// ──────────────────────────────────────────────────────────────────────────────
// Domain vocabulary
// ──────────────────────────────────────────────────────────────────────────────

// Ordered [domain, pattern] pairs, matched against a file stem from which the
// test markers and the layer's own redundant prefix have been removed. The
// first match wins, so the specific patterns come first.
const INFRA_DOMAINS = [
	['field_check', /^(field_(check|run|probe)|startup_smoke|input_probe)/],
	[
		'diagnostics',
		/^(diagnostic|error_(report|policy|description)|issue_|crash|redact|git_status|bootstrap_log)/
	],
	['config', /^timings?($|_)/],
	[
		'logger',
		/^(perf|phase_stats|hotpath|boot_profiler|tick_count|wall_clock|monotonic|.*_evidence$|key_event_health|keystroke_integrity|file_read_activity|reload_timing|paced_)/
	],
	['logger', /^(logger|log_)/],
	['i18n', /^(i18n|locale|manifest_descriptions)/],
	['menu', /^(menu_|manifest_|slot_roles|program_actions|user_actions)/],
	[
		'network',
		/^(http_|managed_http|managed_redirect|proxy_|curl_|external_url|openssl_|asset_signature|fd_sha256|error_net|vscode_bridge|llm_bridge|route_origins)/
	],
	[
		'lifecycle',
		/^(boot|first_boot|startup_|teardown_|termination_|shutdown_|reload_|quit_|lifecycle|single_instance|instance_admission|suspend_|signal_handlers|restart_|daemon_restart|runtime_guard|launcher_|emergency_exit|session_lock|libuv_|deferred_work|main_thread_hold|updater_boot_ready|start_at_login|uninstall|installation|version|legacy_folder|bundle$|app_state|direct_require|literal_module_loader|dev_source|common_hotstrings_boot|accessibility_wait|master_gates|ui_restore|driver_control|script_scope|global_scope|account_name)/
	],
	[
		'file_system',
		/^(file_|fs_|native_directory|regular_file|no_replace_move|corrupt_aside|archive_|private_sqlite|sqlite|user_private_group|paths$|config_paths|app_folders|openstep_plist|factory_reset)/
	],
	[
		'config',
		/^(config|preferences|scope_registry|.*_scope$|.*_preferences$|script_settings|feature_(io|state)|personal_|extension_packs|registry$|program_parameter|send_input_parameter|wrap_symbols_config|llm_defaults|llm_context_limit|wpm_constants|metrics_state_keys|owned_programs|program_binding)/
	],
	['hotstrings', /^(hotstring|user_hotstring|legacy_hotstring|dynamic_hotstrings)/],
	[
		'input',
		/^(chord|tap_keys|sticky_modifiers|altgr|script_altgr|script_chord|capsword|capslock|key_|keycodes|keysym|evdev_codes|xkb_|hook_dispatcher|input_|typed_input|absolute_motion|nav_layer|wrap_pair|magic_editor|composed_text|text_case|suppressive_inputhook|device_|clipboard_)/
	],
	['text', /^(text_|json|number|source_text_codec|gvariant|toml|identifiers|unicode)/],
	[
		'ui',
		/^(ui_style|webview_|native_dialogs?|native_folder_picker|native_presentation|native_sleep|native_timer|dialog_util|window_utils|tray_|app_picker|notifications|display_server|gui_stack|open_target|quit_request)/
	]
];

const ADAPTER_DOMAINS = [
	[
		'diagnostics',
		/^(boot_fatal|boot_journal|log_transport|diagnostics_control|driver_control|reload_breadcrumb|field_\w+_ports|runtime_\w+_ports?|event_provenance|foreign_ledger|metadata_command_stats|crash_report|release_stage|console_window)/
	],
	[
		'clipboard',
		/^(clipboard|selection_transaction|wayland_selection|x11_selection|editor_replace|accessibility_copies|unicode_carrier)/
	],
	[
		'input',
		/^(keyboard_hook|key_state|hotkey_registrar|text_sender|synthetic_input|modifier_|mouse_control|uinput_writer|evdev_reader|one_shot_shift|input_source|input_probe|xkb_|x11_keymap|keyboard_(layout|source|geometry)|installed_physical_source|layout_|physical_shortcut_hook|system_switcher|native_text|native_number|send_input|terminal_output)/
	],
	[
		'network',
		/^(http_client|curl_http_client|system_curl|network_|proxy_override|system_proxy|tcp_probe|updater_curl|ollama_identity|managed_ollama)/
	],
	[
		'processes',
		/^(process_|shell_runner|owned_|program_|task_|app_launcher|desktop_opener|sqlite_process_worker|uia_worker|crash_report_worker|native_bootstrap_pty|python_|native_python|llm_|bundled_apps|update_launcher)/
	],
	[
		'storage',
		/^(storage|sqlite_native|toml_cache|ledger_append|file_|write_lock_path|json_codec|crypto|keyboard_layout_files|legacy_folder)/
	],
	[
		'focus',
		/^(window_|own_window|running_application|atspi_|compositor_focus|cosmic_toplevel|x11_focus|secure_field|physical_|accessibility_permission|application_notifier|apple_shortcuts)/
	],
	[
		'system',
		/^(system_|screen_|power_source|wake_watcher|notifier|notify_icon|privacy_settings|tcc_grant|event_clock|boot_clock|timer_scheduler|event_loop|tap_to_click|karabiner|graphics_renderer|tooltip_renderer|prediction_tooltip|tray_|spotlight_overlay|wpm_surface|webview_|native_folder_picker)/
	]
];

// The ui/ groups and the window or file names they hold. A ui/ entry that
// matches none stays where it is and is reported.
const UI_GROUPS = [
	['menu', /^(menu|tray_menu)$/],
	[
		'panels',
		/^(changelog|update_check|download_window|model_browser|healthcheck|field_check|onboarding|config_cleanup|metrics_apps|metrics_typing|bundled_apps)$/
	],
	[
		'editors',
		/^(layer_editor|layout_manager|hotstring_editor|hotstrings_config_window|personal_info_editor|personal_toml_editor(_webview)?|paths_editor|prompt_editor|physical_shortcuts|action_picker(_webview)?|user_action_editor|editors|config_dir_picker|app_chooser)$/
	],
	[
		'dialogs',
		/^(error_dialog|permission_dialog|numeric_prompt|token_prompt|text_prompt|choice_prompt|modal|native_dialog|dialog_host|reload_refusal|llm_enable_refusal|vision_parameter_prompt|app_cloner_python_offer|python_runtime_offer|owned_runtime_install|virtual_hid_update|legacy_rules_cleanup|gesture_conflicts?|gesture_conflict_notice|proxy_override)$/
	],
	['overlays', /^(tooltip|wpm|spotlight)$/],
	[
		'shell',
		/^(webview_manager|webkit_host|webview_controller_pool|webview_close_owner|ui_builder|console_window|log_openers|window_toggle|desktop_application_resolution(_worker)?|metrics_flush_bridge)$/
	]
];

// ──────────────────────────────────────────────────────────────────────────────
// Sub-module splits of oversized feature folders
// ──────────────────────────────────────────────────────────────────────────────

const KEYSTATS_SUBMODULES = [
	['reader', /^(reader|sqlite_reader|ledger_replay|rebuild|export|ngrams?|frames|partial)/],
	['apps', /^(app_categor|apps_editor)/],
	[
		'system',
		/^(system_|session_events|virtual_desktop|window_topology|topology|watchers|network|shutdown|health)/
	],
	['privacy', /^(roi_|trigger_roi|privacy|text_cipher|text_migration|password)/],
	[
		'journal',
		/^(journal|llm_journal|hotstring_log|hotstring_units|log_manager|rotation|rollover|sql|sqlite_writer|maintenance|prefetch|buffer_snapshot|event_id|timestamp|ingest)/
	],
	['walker', /^walker/],
	[
		'capture',
		/^(hook|mouse|device|clipboard|physical|kc_bridge|sensors|collection|password|av_state|host_signature)/
	],
	['context', /^(context|ergonomics|json|constants)/],
	['ui', /^(ui|webview)/],
	['aggregator', /^aggregator/]
];

const LLM_SUBMODULES = [
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
		'settings',
		/^(profiles?|profile_settings|settings|.*_settings|enable_admission|api_key_migration|api_entries|api_token_store|error_log|display|models)/
	]
];

const MENU_SUBMODULES = [
	['llm', /^(llm_|ai_parent|agent_rows|menu_agent|local_server_rows|llm_backend_rows|chatgpt_url)/],
	['hotstrings', /^(menu_hotstring|hotstring|programmatic_hotstrings|magic_key)/],
	[
		'keyboard',
		/^(menu_(keyboard|layout|tap|taphold|caps_word)|active_layout_rows|pause_layout_rows|key_combinations|quit_layout|keymap_lifecycle|base_delay)/
	],
	[
		'features',
		/^(menu_(apps|gestures|metrics|shortcuts|paths)|app_exclusion_rows|metrics_scope|gesture_scope|shortcut_utils|shortcuts_scope|hotstrings_scope|llm_scope)/
	],
	[
		'transactions',
		/_transaction$|^(scoped_preferences|session_demotions|recoverable_file_moves|refresh_scope|global_scope|unused_keys_cleanup|uninstall|start_at_login|profile_editor_request)/
	],
	[
		'engine',
		/^(builder|init|menu_(engine|init|rebuild|submenus|state|utils|watchers|actions|about|configuration|debug|dialogs|language|quit|reload)|branch_rows|canvas_badge|click_gate|rebuild_owner|timed_build|feature_notice)/
	]
];

const MENU_LLM_SUBMODULES = [
	['models', /^(models?_|custom_models|mlx_|ollama_|menu_models)/],
	['panels', /_panel$/]
];

const CONFIG_SUBMODULES = [
	[
		'migration',
		/^(config_(migrate|obsolete|outdated|unused|file_inverse|cleanup|transition)|legacy_)/
	],
	[
		'publication',
		/(_publication$|^config_(binding|reset|save|write_lease|registry_cache|user_models|defaults|keyboard))/
	],
	['scope', /(_scope$|^scope_|^config_scope|^config_global_scope|^global_scope|^script_scope)/],
	[
		'preferences',
		/(preferences$|^script_settings|^personal_|^feature_(io|state)|^program_binding|^owned_programs)/
	]
];

const LIFECYCLE_SUBMODULES = [
	['reload', /^(reload|restart|daemon_restart|single_instance|instance_admission|suspend_)/],
	[
		'shutdown',
		/^(quit|shutdown|termination|teardown|signal_handlers|emergency_exit|libuv_exit|session_lock|uninstall)/
	]
];

const REMAP_SUBMODULES = [
	['tap_hold', /^tap_hold/],
	[
		'keys',
		/^(altgr|backspace|capslock|delete|enter|escape|lalt|lshift|rctrl|rshift|space|tab|win|one_shot_shift|key_combination)/
	],
	[
		'runtime',
		/^(runtime_|ke_|lease_|deploy_pacing|managed_rule|token_reuse|legacy_release|guardian)/
	],
	['layers', /^(nav_layer|layers_loader|scope_layer|script_chord)/]
];

const HOTSTRINGS_SUBMODULES = [
	['engine', /^(hotstring_|terminator|preview_switches)/],
	['catalogue', /^(hotstrings_|personal_|extension_packs|common_autocorrection)/]
];

/** Folder-specific splits, keyed by tree-relative folder (driver or _shared). */
const SUBMODULE_SPLITS = {
	'infra/config': { strip: null, table: CONFIG_SUBMODULES },
	'infra/lifecycle': { strip: null, table: LIFECYCLE_SUBMODULES },
	'platform/remap': { strip: null, table: REMAP_SUBMODULES },
	'modules/hotstrings': { strip: null, table: HOTSTRINGS_SUBMODULES },
	'ui/menu/llm': { strip: /^menu_/, table: MENU_LLM_SUBMODULES },
	'modules/keystats': { strip: /^keystats_/, table: KEYSTATS_SUBMODULES },
	'infra/text': { strip: null, table: [['toml', /^toml/]] },
	'modules/llm': { strip: /^llm_(?!request)/, table: LLM_SUBMODULES },
	'ui/menu': { strip: null, table: MENU_SUBMODULES }
};

// Flat test data folders (fixtures, support, hardware proofs, the shared Lua
// tests) split by the feature their file names start with.
const TEST_DATA_FEATURES = [
	['keystats', /^(keystats|metrics|wpm|roi|ngram)/],
	['llm', /^(llm|ollama|mlx|model|prompt|prediction|agent|translate|vision)/],
	['layout', /^(layout|keylayout|xkb|xi2|keymap|phys|physical|keyboard|led|magic)/],
	['updater', /^(updater|update|release|download|bundle)/],
	['gestures', /^(gesture|touchpad|trackpad)/],
	['hotstrings', /^(hotstring|personal|terminator|sendinstant|wrap|user)/],
	['menu', /^(menu|tray|sni)/],
	['config', /^(config|toml|paths|profile|pause|onboarding|script|scope)/],
	[
		'input',
		/^(input|sticky|clipboard|synthetic|virtual|fake|key|tap|chord|text|plain|native|context|action)/
	],
	[
		'ui',
		/^(webview|ui|tooltip|window|healthcheck|application|screen|wayland|secure|atspi|desktop)/
	],
	[
		'system',
		/^(system|managed|winhttp|network|proxy|sqlite|session|startup|logger|lib|validate|runner|local|hotpath)/
	]
];

// ──────────────────────────────────────────────────────────────────────────────
// OS-specific folders allowed on one driver only
// ──────────────────────────────────────────────────────────────────────────────

// Each entry names a folder that exists on its driver only, and why the name
// says so. A folder on one or two drivers that is not listed is a mismatch.
const OS_SPECIFIC = {
	macos: {
		launcher: 'the Swift host application of the macOS runtime',
		'platform/remap/data': 'Karabiner remap data that only the macOS remap runtime reads',
		'ui/dialogs/permission_dialog': 'a macOS privacy (TCC) grant walkthrough'
	},
	linux: {
		install: 'the shell installers and launcher the Linux package runs before LuaJIT',
		'platform/desktop_focus': 'GNOME Shell and KWin code reading the focused window under Wayland',
		'native/archive_output': 'the O_TMPFILE/linkat archive publication of the Linux updater',
		'ui/dialogs/numeric_prompt':
			'Linux has no toolkit number prompt (hs.dialog, InputBox elsewhere)',
		'ui/dialogs/token_prompt': 'Linux has no toolkit secret prompt'
	},
	windows: {
		'native/keyboard_layout': 'the keyboard DLL sources generated from the .keylayout',
		'native/nav_event_owner': 'the WH_KEYBOARD_LL component owning navigation events',
		'ui/overlays/spotlight': 'the Windows spotlight overlay (macOS and Linux use the OS overlay)'
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

/** The ui/ group of a ui-relative first segment, or null. */
function uiGroup(segment) {
	return classify(UI_GROUPS, segment.replace(/\.[^.]+$/, ''));
}

/**
 * Maps the code part of a driver path (relative to the driver root, tests
 * prefix removed) to its target.
 * @param {string} rel e.g. "infra/logger.lua" or "ui/changelog/bridge.lua".
 * @param {boolean} isTest The path sits under tests/, so file stems carry test markers.
 * @returns {string} The target relative path.
 */
function mapCode(rel, isTest) {
	const parts = rel.split('/');
	const layer = parts[0];
	const name = parts[parts.length - 1];

	// Rule 3: ui/ groups. A ui-relative first segment names a window or a file.
	if (layer === 'ui' && parts.length >= 2) {
		const first = parts.length === 2 ? classStem(parts[1]) : parts[1];
		const group = uiGroup(first);
		if (parts[1] === 'menu' && parts[2] === 'menu_llm')
			return applySplits(['ui', 'menu', 'llm', ...parts.slice(3)].join('/'), isTest);
		if (group && group !== parts[1])
			return applySplits(['ui', group, ...parts.slice(1)].join('/'), isTest);
		return applySplits(rel, isTest);
	}

	// Rule 2: flat infra/ and adapters/ files split by domain.
	if ((layer === 'infra' || layer === 'adapters') && parts.length === 2) {
		const table = layer === 'infra' ? INFRA_DOMAINS : ADAPTER_DOMAINS;
		const domain = classify(table, classStem(name));
		if (domain === 'diagnostics' && layer === 'infra') return `modules/diagnostics/${name}`;
		if (domain === 'hotstrings' && layer === 'infra')
			return applySplits(`modules/hotstrings/${name}`, isTest);
		if (domain) return applySplits(`${layer}/${domain}/${name}`, isTest);
		return rel;
	}
	if (layer === 'modules' && parts[1] === 'diagnostics') return rel;

	// The canonical `layout` feature (features.json) is spread through keymap.
	if (layer === 'modules' && parts[1] === 'keymap' && parts.length >= 3) {
		if (parts.length >= 4 && parts[2] === 'layout')
			return ['modules', 'layout', ...parts.slice(3)].join('/');
		if (parts.length >= 4 && parts[2] === 'keylayout')
			return ['modules', 'layout', ...parts.slice(2)].join('/');
		if (parts.length === 3 && LAYOUT_STEM.test(classStem(name))) return `modules/layout/${name}`;
	}
	// Existing infra/ sub-folders that have a domain name elsewhere.
	if (layer === 'infra' && parts.length >= 3 && !(isTest && parts[1] === 'toml')) {
		const renamed = {
			timings: 'infra/config',
			toml: 'infra/text/toml',
			metrics: 'modules/keystats'
		}[parts[1]];
		if (renamed) return [renamed, ...parts.slice(2)].join('/');
	}
	// Windows keeps the hotstring engine under infra/; the other drivers under modules/.
	if (layer === 'infra' && parts[1] === 'hotstrings')
		return applySplits(['modules', ...parts.slice(1)].join('/'), isTest);
	return applySplits(rel, isTest);
}

const LAYOUT_STEM =
	/^(layout|composer_check|input_sources|pending_layout|number_row|pause_layout|x11_layout|system_layout|keylayout|managed_python)/;

/** Applies the sub-module split of the folder a file sits directly in. */
function applySplits(rel, isTest) {
	const parts = rel.split('/');
	const folder = parts.slice(0, -1).join('/');
	const normalised = folder.replace(/^ui\/menu$/, 'ui/menu');
	const split = SUBMODULE_SPLITS[normalised];
	if (!split) return rel;
	const name = parts[parts.length - 1];
	if (/^(README\.md|init\.(lua|ahk))$/.test(name)) return rel;
	const sub = classify(split.table, classStem(name, split.strip));
	return sub ? `${folder}/${sub}/${name}` : rel;
}

/**
 * Maps one tree-relative path ("linux/infra/logger_sink.lua") to its target,
 * before the singleton pass.
 */
function mapPath(treeRel) {
	const [tree, ...restParts] = treeRel.split('/');
	const rest = restParts.join('/');
	if (tree === '_shared') return `_shared/${mapShared(rest)}`;
	if (!DRIVERS.includes(tree)) return treeRel;

	// Linux-only folders folded into the canonical layers (see OS_SPECIFIC).
	if (tree === 'linux' && rest.startsWith('desktop_focus/')) return `linux/platform/${rest}`;
	if (tree === 'linux' && rest.startsWith('bin/')) return `linux/install/${rest.slice(4)}`;

	const test = rest.match(/^tests\/(unit|meta|integration|contract|e2e)\/(.+)$/);
	if (test) return `${tree}/tests/${test[1]}/${mapCode(test[2], true)}`;
	const data = rest.match(/^tests\/(fixtures|support|hardware)\/([^/]+)$/);
	if (data) {
		const feature = classify(TEST_DATA_FEATURES, classStem(data[2]));
		return feature ? `${tree}/tests/${data[1]}/${feature}/${data[2]}` : treeRel;
	}
	if (rest.startsWith('tests/')) return treeRel;
	return `${tree}/${mapCode(rest, false)}`;
}

// Where each existing _shared/lua folder lands: the driver layer and the name
// it has there, so _shared/lua mirrors <driver>/<layer>/<domain>.
const SHARED_LUA_FOLDERS = {
	actions: 'modules/actions',
	app_parameter: 'modules/actions',
	caps_word: 'modules/keymap',
	chord: 'modules/keymap',
	color: 'ui/shell',
	compat: 'infra/lifecycle',
	control: 'infra/field_check',
	core: 'infra/lifecycle',
	crypto: 'adapters/storage',
	desktop_navigation: 'modules/shortcuts',
	diagnostics: 'modules/diagnostics',
	dynamic_hotstrings: 'modules/dynamic_hotstrings',
	error_dialog: 'ui/dialogs',
	features: 'infra/config',
	file_selection: 'ui/editors',
	file_system: 'infra/file_system',
	gestures: 'modules/gestures',
	healthcheck: 'ui/panels/healthcheck',
	hotstring_engine: 'modules/hotstrings/engine',
	hotstring_priority: 'modules/hotstrings',
	hotstrings: 'modules/hotstrings',
	input: 'infra/input',
	keycodes: 'infra/input/keycodes',
	keymap: 'modules/keymap',
	keystats: 'modules/keystats',
	layout: 'modules/layout',
	layouts: 'modules/layout/registry',
	llm: 'modules/llm',
	locale: 'infra/i18n',
	logger: 'infra/logger',
	menu: 'ui/menu',
	network: 'infra/network',
	open_target: 'infra/ui',
	personal_info: 'modules/dynamic_hotstrings',
	process: 'adapters/processes',
	send_input: 'infra/input',
	shell: 'adapters/processes',
	shortcuts: 'modules/shortcuts',
	sqlite: 'infra/file_system/sqlite',
	tap_hold: 'platform/remap/tap_hold',
	test: 'test',
	text_utils: 'infra/text/text_utils',
	toml_codec: 'infra/text/toml',
	tooltip: 'ui/overlays/tooltip',
	tray: 'platform/tray',
	unicode_case: 'infra/text',
	updater: 'modules/updater',
	webview: 'ui/shell',
	wpm_widget: 'ui/overlays/wpm',
	wrap_pair: 'infra/input'
};

// Flat _shared/lua files the infra vocabulary does not place.
const SHARED_LUA_FLAT = [
	['modules/actions', /^(action_parameter_label|user_action_parameter|brightness_actions)/],
	['ui/panels/onboarding', /^onboarding_/],
	['ui/shell', /^(window_titles|cursor_window_policy|native_theme_data|native_app_switcher_owner)/],
	['ui/menu', /^feature_notice/],
	['infra/config', /^(script_|scope_owner|program_provider|program_parameter|adapter_errors)/],
	[
		'infra/lifecycle',
		/^(module_source_|native_worker_owner|owned_timer_slots|reload_gate|quit_admission)/
	],
	['infra/file_system', /^(app_dirs|storage_owned|native_path)/],
	['infra/text', /^(table_util|number_policy)/],
	['infra/menu', /^application_notifier/]
];

// The _shared/ui page folders take the same groups as the driver ui/ trees;
// the page-independent scripts go to ui/lib/.
function mapSharedUi(parts) {
	const [, first, ...rest] = parts;
	if (first === '_generated' || first === 'vendor') return parts.join('/');
	if (rest.length === 0) return ['ui', 'lib', first].join('/');
	const group =
		uiGroup(first) ||
		(/^(layout_composer|layout_editor)$/.test(first) ? 'editors' : null) ||
		(first === 'release_notes' ? 'panels' : null);
	return group ? ['ui', group, first, ...rest].join('/') : parts.join('/');
}

/** _shared/lua and _shared/ui mirror the driver trees; the other roots stay. */
function mapShared(rest) {
	const parts = rest.split('/');
	if (parts[0] === 'ui') return mapSharedUi(parts);
	if (parts[0] !== 'lua') return rest;
	if (parts.length === 2) {
		const name = parts[1];
		const stem = classStem(name);
		const flat = classify(SHARED_LUA_FLAT, stem);
		if (flat) return `lua/${flat}/${name}`;
		const domain = classify(INFRA_DOMAINS, stem);
		if (domain === 'diagnostics') return `lua/modules/diagnostics/${name}`;
		if (domain === 'hotstrings') return `lua/modules/hotstrings/${name}`;
		if (domain) return applySplitsShared(`infra/${domain}/${name}`);
		return rest;
	}
	if (parts[1] === 'test') {
		if (parts.length !== 3) return rest;
		const stem = classStem(parts[2]);
		const domain = classify(TEST_DATA_FEATURES, stem) || classify(INFRA_DOMAINS, stem);
		return domain ? `lua/test/${domain}/${parts[2]}` : rest;
	}
	const target = SHARED_LUA_FOLDERS[parts[1]];
	if (!target) return rest;
	const tail = parts.slice(2);
	// A folder keeps its name under its target unless the target already ends
	// with it; the singleton pass then turns a one-file folder into <name>.lua,
	// which keeps the module's last name.
	const absorbed = target.split('/').pop() === parts[1];
	return applySplitsShared(
		['lua', ...target.split('/'), ...(absorbed ? [] : [parts[1]]), ...tail].join('/')
	);
}

/** Applies a sub-module split to a _shared/lua path, which mirrors driver paths. */
function applySplitsShared(rel) {
	const lua = rel.startsWith('lua/');
	const inner = lua ? rel.slice(4) : rel;
	return `lua/${applySplits(inner, false)}`;
}

module.exports = {
	INFRA_DOMAINS,
	ADAPTER_DOMAINS,
	UI_GROUPS,
	SUBMODULE_SPLITS,
	OS_SPECIFIC,
	classStem,
	mapPath
};
