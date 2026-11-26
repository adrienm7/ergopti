; _generated/log_export_data.ahk
; AUTO-GENERATED from _shared/core/logger/data/log_export.toml.
; DO NOT EDIT BY HAND — run `npm run codegen:log-export` to refresh.
#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: Log Export Archive Data (Windows)
; DESCRIPTION:
; What « Export the logs (zip) » archives and the privacy rules each entry is
; copied through, read by diagnostics/engine/log_export.ahk.
;
; A function rather than a global initialiser so include ORDER cannot matter.
; ==============================================================================

LogExportData() {
	return Map(
		"days", 3,
		"name_prefix", "Ergopti-logs_",
		"extension", ".zip",
		"crash_report_extension", ".json",
		"withheld", "<text withheld>",
		"rules", [
			Map("marker", "Auto-expand: ", "cut", ""),
			Map("marker", "Terminator-expand: ", "cut", ""),
			Map("marker", "KL_LogHotstring: trigger=", "cut", ""),
			Map("marker", "Fire-log drain failed for trigger ", "cut", ""),
			Map("marker", "PROMPT (", "cut", " -> "),
			Map("marker", "STREAM chunk (", "cut", "): "),
			Map("marker", "KEEP: keystroke ", "cut", ""),
			Map("marker", "DISMISS: keystroke ", "cut", ""),
			Map("marker", "OnChar error for char ", "cut", ""),
			Map("marker", "UIA wrap error for char ", "cut", ""),
			Map("marker", "DBG calling TooltipShow: ", "cut", "first="),
			Map("marker", "Raw (", "cut", "c): "),
			Map("marker", "Opening the selected ", "cut", " "),
			Map("marker", "Handed the selected ", "cut", " "),
			Map("marker", "Registry navigation to ", "cut", ""),
			Map("marker", "inject(): bc=", "cut", "text="),
			Map("marker", "Cannot deliver '", "cut", ""),
			Map("marker", "selection window opened — typing ", "cut", ""),
			Map("marker", "«", "cut", ""),
		]
	)
}
