; _generated/value_schema.ahk
; AUTO-GENERATED from _shared/settings/data/value_schema/value_schema.json.
; DO NOT EDIT BY HAND — run `npm run codegen:value-schema` to refresh.
#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: User Value Schema Data (Windows)
; DESCRIPTION:
; The declaration of every user-entered setting value, as the data
; infra/value_check.ahk checks against. A compiled build has no JSON reader
; at include time, and a hand-maintained copy would drift.
; ==============================================================================

; A function rather than a global initialiser so include ORDER cannot matter;
; the Map is built once and shared by every caller.
ValueSchemaData() {
	static Data := 0
	if IsObject(Data)
		return Data
	Data := Map("version", 1, "settings", Map(
		"hotstrings.cascade_max_arrows", Map(
			"file", "config.toml",
			"type", "integer",
			"min", 1,
			"max", 10,
			"default_from", Map(
				"manifest", "hotstrings.cascade_max_arrows")),
		"hotstrings.dynamic.user_code.time_activation_seconds", Map(
			"file", "config.toml",
			"type", "decimal",
			"unit", "s",
			"min", 0,
			"max", 3600,
			"entry_scale", 1000,
			"entry_type", "integer",
			"entry_unit", "ms"),
		"hotstrings.expansion_delay", Map(
			"file", "config.toml",
			"type", "decimal",
			"unit", "s",
			"min", 0,
			"max", 3600,
			"entry_scale", 1000,
			"entry_type", "integer",
			"entry_unit", "ms",
			"special", [Map(
				"value", 0,
				"label_key", "value_check.special.no_time_limit")],
			"default_from", Map(
				"manifest", "hotstrings.expansion_delay")),
		"hotstrings.idle_reset_seconds", Map(
			"file", "config.toml",
			"type", "decimal",
			"unit", "s",
			"min", 0,
			"max", 3600,
			"special", [Map(
				"value", 0,
				"label_key", "value_check.special.never")],
			"default_from", Map(
				"manifest", "hotstrings.idle_reset_seconds")),
		"hotstrings_config.*.*.delay", Map(
			"file", "hotstrings_config.toml",
			"type", "decimal",
			"unit", "s",
			"min", 0,
			"max", 3600,
			"entry_scale", 1000,
			"entry_type", "integer",
			"entry_unit", "ms"),
		"hotstrings_config.*.*.priority", Map(
			"file", "hotstrings_config.toml",
			"type", "integer",
			"min", 0,
			"max", 100),
		"hotstrings_config.*.delay", Map(
			"file", "hotstrings_config.toml",
			"type", "decimal",
			"unit", "s",
			"min", 0,
			"max", 3600,
			"entry_scale", 1000,
			"entry_type", "integer",
			"entry_unit", "ms"),
		"hotstrings_config.*.priority", Map(
			"file", "hotstrings_config.toml",
			"type", "integer",
			"min", 0,
			"max", 100),
		"mod_combos.simultaneous_threshold_ms", Map(
			"file", "config.toml",
			"type", "integer",
			"unit", "ms",
			"min", 1,
			"max", 1000,
			"default_from", Map(
				"manifest", "mod_combos.simultaneous_threshold_ms")),
		"tap_hold.keys.*.time_activation_seconds", Map(
			"file", "tap_hold.toml",
			"type", "decimal",
			"unit", "s",
			"min", 0.001,
			"max", 10,
			"entry_scale", 1000,
			"entry_type", "integer",
			"entry_unit", "ms",
			"max_from", Map(
				"timing", "tap_hold.max_activation_ms",
				"scale", 0.001)),
		"tap_hold.time_activation_seconds", Map(
			"file", "tap_hold.toml",
			"type", "decimal",
			"unit", "s",
			"min", 0.001,
			"max", 10,
			"entry_scale", 1000,
			"entry_type", "integer",
			"entry_unit", "ms",
			"default_from", Map(
				"timing", "tap_hold.default_activation_ms",
				"scale", 0.001),
			"max_from", Map(
				"timing", "tap_hold.max_activation_ms",
				"scale", 0.001)),
		"tap_holds.lone_modifier_tap_max_ms", Map(
			"file", "config.toml",
			"type", "integer",
			"unit", "ms",
			"min", 0,
			"max", 10000,
			"special", [Map(
				"value", 0,
				"label_key", "value_check.special.off")],
			"default_from", Map(
				"manifest", "tap_holds.lone_modifier_tap_max_ms"))))
	return Data
}
