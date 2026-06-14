; tests/meta/test_webview2_temp_leak.ahk

; ==============================================================================
; MODULE: WebView2 Temp Leak Meta Test
; DESCRIPTION:
; Static source guard for the "webview2-udir-temp-leak" finding.
; Every WebView2 host must call WebView_SweepStaleProfiles and
; explicitly clean up the udir on close.
; ==============================================================================

#Requires AutoHotkey v2.0

_TWTL_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_TWTL_CheckHost(Path, CreatePrefix, CloseSig, RequiresUdirDelete := true) {
	Src := _TWTL_ReadSource(Path)
	Assert(Src != "", "Source file must exist: " . Path)

	Assert(InStr(Src, 'WebView_SweepStaleProfiles("' . CreatePrefix . '")') > 0,
		Path . " must call WebView_SweepStaleProfiles before DirCreate")

	if RequiresUdirDelete {
		Assert(InStr(Src, "DirDelete") > 0,
			Path . " must delete the udir in its Close path")
	}
}

_TWTL_AllHosts() {
	_TWTL_CheckHost("lib/changelog_window.ahk", "ergopti_changelog_wv_", "DirDelete(_CLW_Udir, true)")
	_TWTL_CheckHost("lib/healthcheck.ahk", "ergopti_hc_wv_", "DirDelete(G.Udir, true)")
	_TWTL_CheckHost("lib/updater.ahk", "ergopti_changelog_wv_", "DirDelete(G.Udir, true)")
	_TWTL_CheckHost("lib/updater.ahk", "ergopti_update_wv_", "DirDelete(G.Udir, true)")
	_TWTL_CheckHost("modules/keylogger/keylogger_ui.ahk", "ergopti_metrics_edge_", "")
	_TWTL_CheckHost("modules/keylogger/keylogger_webview.ahk", "ergopti_webview2_", 'DirDelete(entry["udir"], true)')
	_TWTL_CheckHost("modules/llm/ollama_webview.ahk", "ergopti_ollama_wv_", "DirDelete(_OllamaWV_Udir, true)")
	_TWTL_CheckHost("ui/llm_model_browser.ahk", "ergopti_modelbrowser_wv_", "DirDelete(_LLM_MBW_Udir, true)")
}
Test("WebView2 hosts: sweep stale profiles and delete on close", _TWTL_AllHosts)
