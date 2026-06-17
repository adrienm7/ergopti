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

; Regression guard: OllamaWV_Close() used to call DirDelete synchronously right
; after Controller.Close() (which is async). Edge's child processes still held a
; file lock for a few hundred ms, so DirDelete failed silently and the temp folder
; leaked. The fix defers deletion via SetTimer. This test verifies the deferred
; pattern is present so the synchronous race cannot be reintroduced.
_TWTL_OllamaWVDeferredDelete() {
	Src := _TWTL_ReadSource("modules/llm/ollama_webview.ahk")
	Assert(InStr(Src, "SetTimer") > 0,
		"OllamaWV_Close must use SetTimer to defer udir deletion (async Edge lock race)")
	Assert(InStr(Src, "_OllamaWV_DeferredDirDelete") > 0,
		"OllamaWV_Close must call _OllamaWV_DeferredDirDelete via SetTimer (not DirDelete inline)")
}

Test("WebView2 hosts: sweep stale profiles and delete on close", _TWTL_AllHosts)
Test("OllamaWV_Close: udir deletion is deferred via SetTimer to avoid Edge file lock race", _TWTL_OllamaWVDeferredDelete)
