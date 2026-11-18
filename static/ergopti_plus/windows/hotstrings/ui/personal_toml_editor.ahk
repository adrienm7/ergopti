; hotstrings/ui/personal_toml_editor.ahk

; ==============================================================================
; MODULE: Personal TOML Editor
; DESCRIPTION:
; Public entry point of the personal-hotstrings editor and owner of its
; persisted UI preferences. The editor itself is the shared WebView page hosted
; by personal_toml_editor_webview.ahk, the same page the macOS driver shows.
;
; FEATURES & RATIONALE:
; 1. OpenPersonalEditor: the one entry point every menu row, gesture and
;    hotkey calls. WebView only (maintainer decision 2026-11-11): when WebView2
;    cannot open the page, the user is told WebView2 is required and the reason
;    is logged; no native form is built.
; 2. Preference persistence: default section, compact view and close-on-add are
;    stored under [personal_editor] in config.toml so they survive reloads.
; ==============================================================================

#Include ../engine/catalogue/personal_toml_io.ahk






; =========================================
; =========================================
; ======= 1/ Preference persistence =======
; =========================================
; =========================================

; Whether the editor closes after an add. An absent key means off, the one
; default the tray menu, the editor and the macOS and Linux drivers share.
_EditorCloseOnAddEnabled() {
	return _EditorPrefGet("close_on_add", "0") == "1"
}

; Keys under [personal_editor] in the v2 config TOML.
_EditorPrefGet(Key, Default) {
	global ConfigurationFile
	if !IsSet(ConfigurationFile) or !FileExist(ConfigurationFile) {
		return Default
	}
	; Preference keys can be owned by dotted assignments or an inline namespace.
	Cache := ConfigTomlDecodeSnapshotShared(FSReadStrict(ConfigurationFile)).Cache
	Val := IniCacheGet(Cache, "personal_editor", Key, "_MISSING_")
	return (Val == "_MISSING_") ? Default : Val
}
_EditorPrefSet(Key, Value, WriterFn := 0, NotifyFn := 0) {
	global ConfigurationFile
	if !IsSet(ConfigurationFile)
		return ConfigReportPersistenceFailure("the personal-editor preference", NotifyFn,
			"ConfigurationFile is not initialized")
	Updates := [{ Section: "personal_editor", Key: Key, Value: Value }]
	return ConfigCommitUpdates(ConfigurationFile, Updates,
		"the personal-editor preference '" . Key . "'", WriterFn, NotifyFn)
}






; =====================================
; =====================================
; ======= 2/ Opening the editor =======
; =====================================
; =====================================

; Personal source-default priority read from the shared single source
; (_shared/hotstrings/data/catalogue/priority.json) so the editor never hardcodes it. Falls back
; to the engine constant — which the parity gate keeps identical to that file —
; if the shared file cannot be read.
_GetSharedPersonalDefault() {
	global _SharedDir
	try {
		if IsSet(_SharedDir) {
			Path := _SharedDir . "\hotstrings\data\catalogue\priority.json"
			if FileExist(Path) {
				Data := JsonParse(FileRead(Path, "UTF-8"))
				if (Data is Map and Data.Has("personal")) {
					return Data["personal"]
				}
			}
		}
	}
	return _HSE_SourcePriority("personal")
}

; Open the editor, optionally jumping to a specific section.
; DefaultSection — if set, the editor pre-selects that section.
; @returns {Boolean} False when WebView2 refused the opening.
OpenPersonalEditor(DefaultSection := "") {
	if _HsEdWeb_TryOpen(DefaultSection, &FailureReason)
		return true
	return WebView_RefuseUnavailable("personal hotstrings editor", FailureReason)
}
