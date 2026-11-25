; _generated/registry_limits.ahk
; AUTO-GENERATED from _shared/core/timing/data/constants.toml.
; DO NOT EDIT BY HAND — run `npm run codegen:registry-constants` to refresh.
#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: Registry Byte Limits (Windows)
; DESCRIPTION:
; The [limits] section of the timing registry as a dependency-free function,
; for code that runs before TimingsLoadShared(): the detached keystats
; projection worker leaves the driver entry before the boot loads the registry,
; and class static initializers run before any auto-execute body.
; ==============================================================================

/**
 * The value of one [limits] key, failing fast on a key the registry lacks.
 * @param {String} Section Always "limits": the call shape of TimingsGet.
 * @param {String} Key The [limits] key.
 * @returns {Integer}
 */
RegistryLimitsCount(Section, Key) {
	static Values := Map(
		"process_output_bytes", 65536,
		"ocr_output_bytes", 786432,
		"proc_cmdline_bytes", 65536,
		"kde_layout_monitor_line_bytes", 1024,
		"declaration_file_bytes", 65536,
		"changelog_source_bytes", 4194304,
		"journal_recovery_turn_bytes", 65536,
		"layer_file_bytes", 65536,
		"number_row_level_text_bytes", 1024,
		"release_list_body_bytes", 8388608,
		"ollama_install_free_space_margin_bytes", 1073741824,
		"ollama_install_errors_file_bytes", 65536,
		"update_asset_download_bytes", 268435456,
		"ollama_runtime_seal_bytes", 131072,
		"file_digest_output_bytes", 1024,
		"crash_report_head_bytes", 65536,
		"input_source_id_bytes", 1024,
		"network_check_body_bytes", 1048577,
		"program_catalogue_bytes", 65536,
		"http_diagnostic_bytes", 65536,
		"proxy_packet_bytes", 65536,
		"shortcuts_reply_bytes", 65536,
		"user_action_output_bytes", 65536,
		"log_prepare_tick_bytes", 65536,
		"shell_captured_output_bytes", 4194304,
		"registry_cache_payload_bytes", 4194304,
		"sqlite_child_read_bytes", 65536,
		"toml_source_chunk_bytes", 65536,
		"metrics_overlay_slack_bytes", 268435456)
	if Section != "limits"
		throw ValueError("[registry_limits] only [limits] is generated, not [" . Section . "]")
	if !Values.Has(Key)
		throw ValueError("[registry_limits] missing key [limits]." . Key . " in constants.toml")
	return Values[Key]
}
