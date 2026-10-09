; _generated/logger_sub_files.ahk
; AUTO-GENERATED from _shared/modules/logger/sub_files.toml.
; DO NOT EDIT BY HAND — run `npm run codegen:logger-sub-files` to refresh.
#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: Logger Sub-file Routing Table (Windows)
; DESCRIPTION:
; The [[sub_files]] entries whose platforms list includes "ahk", as the array
; infra/logger.ahk fans log lines out with. A line is routed to a sub-file when
; ANY of its tags is a substring of the complete line; it is always also
; written to the main daily log.
;
; Both drivers used to parse the TOML themselves — two hand-rolled
; array-of-tables parsers, each of which had to have the same bug fixed
; separately (a "]" inside a quoted pattern closed the array early), plus a
; hardcoded fallback list that had already drifted from the source.
; ==============================================================================

; A function rather than a global initialiser so include ORDER cannot matter:
; the logger calls this when it initialises, long after every #Include has been
; processed. A global would have to be declared before infra/logger.ahk to be
; visible, which is a constraint the generated file has no way to enforce.
LoggerSubFilesData() {
	return [
		; Gesture recognition, probe loop, swipe events.
		Map("name", "ErgoptiPlus_gestures.log", "tags", ["[gestures", "gesture"]),
		; Ergopti keyboard layout shifts, caps, alt-gr processing.
		Map("name", "ErgoptiPlus_layout.log", "tags", ["[LayoutShift]", "[LayoutCaps]", "[LayoutAltGr]"]),
		; AHK tray-menu dispatch, script shortcuts, TOML loader events.
		Map("name", "ErgoptiPlus_dispatch.log", "tags", ["[Dispatch]", "[ScriptShortcuts]", "[TomlLoader]"]),
		; AHK tray-menu top-level lifecycle events.
		Map("name", "ErgoptiPlus_tray.log", "tags", ["[ErgoptiPlus]"]),
	]
}
