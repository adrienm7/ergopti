; _generated/update_schedule.ahk
; AUTO-GENERATED from _shared/modules/updater/defaults.json.
; DO NOT EDIT BY HAND — run `npm run codegen:update-schedule` to refresh.
#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: Update-Check Schedule Data (Windows)
; DESCRIPTION:
; The automatic update-check timing of the shared defaults, as the data
; modules/updater/schedule.ahk interprets. A compiled build has no JSON reader
; at include time, and a hand-maintained copy would drift.
; ==============================================================================

; A function rather than a global initialiser so include ORDER cannot matter:
; the schedule port reads it on first use, after every #Include was processed.
UpdateScheduleData() {
	return Map(
		"default_check_interval_sec", 86400,
		"boot_check_delay_sec", 30,
		"check_interval_presets", [
			Map("code", "5m", "seconds", 300),
			Map("code", "30m", "seconds", 1800),
			Map("code", "1h", "seconds", 3600),
			Map("code", "6h", "seconds", 21600),
			Map("code", "12h", "seconds", 43200),
			Map("code", "1d", "seconds", 86400),
			Map("code", "3d", "seconds", 259200),
			Map("code", "1w", "seconds", 604800),
			Map("code", "1mo", "seconds", 2592000),
			Map("code", "never", "seconds", 0)
		],
		"jitter_percent", 10,
		"jitter_max_sec", 3600,
		"failure_backoff_sec", [300, 900, 3600],
		"reevaluate_sec", 300,
		"state_storage_key", "updater.check_state")
}
