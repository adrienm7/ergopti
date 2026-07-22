; tests/meta/test_webview2_temp_leak.ahk

; ==============================================================================
; MODULE: WebView2 Temp Leak Meta Test
; DESCRIPTION:
; Static source guard for the "webview2-udir-temp-leak" finding.
;
; Two host families after the shared-environment optimisation:
;  - SHARED-ENV hosts (short-lived info windows) take their controller from
;    WebView_SharedEnvironment and create NO per-open user-data folder, so they
;    cannot leak by construction. Guarded by _TWTL_CheckSharedHost.
;  - LEGACY hosts (interactive/long-lived: keylogger, ollama) still create a
;    per-launch folder; they must sweep stale profiles and DirDelete on close.
; ==============================================================================

#Requires AutoHotkey v2.0

_TWTL_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; SHARED-ENV host: must take its controller from the shared environment and must
; NOT build a per-open "<OldPrefix><tick>" folder (the leak-prone pattern the
; original finding was about -- now eliminated by construction, not merely cleaned).
_TWTL_CheckSharedHost(Path, OldPrefix) {
	Src := _TWTL_ReadSource(Path)
	Assert(Src != "", "Source file must exist: " . Path)
	Assert(InStr(Src, "WebView_SharedEnvironment(") > 0,
		Path . " must obtain its WebView2 controller from WebView_SharedEnvironment")
	Assert(InStr(Src, OldPrefix) = 0,
		Path . " must NOT create a per-open '" . OldPrefix . "<tick>' folder (replaced by the leak-free shared env)")
}

; The updater module's two shared-env hosts (changelog window, update prompt)
; live across sibling files after the lib/updater split -- verify at MODULE scope.
_TWTL_CheckSharedUpdaterModule() {
	Src := _DriverDirConcat("lib/updater")
	Assert(InStr(Src, "WebView_SharedEnvironment(") > 0,
		"lib/updater module must obtain WebView2 controllers from WebView_SharedEnvironment")
	Assert(InStr(Src, "ergopti_changelog_wv_") = 0,
		"lib/updater must NOT create a per-open ergopti_changelog_wv_<tick> folder (replaced by the shared env)")
	Assert(InStr(Src, "ergopti_update_wv_") = 0,
		"lib/updater must NOT create a per-open ergopti_update_wv_<tick> folder (replaced by the shared env)")
}

; LEGACY host: still creates a per-launch folder, so it must sweep stale profiles
; before DirCreate and DirDelete on close.
_TWTL_CheckLegacyHost(Path, CreatePrefix) {
	Src := _TWTL_ReadSource(Path)
	Assert(Src != "", "Source file must exist: " . Path)
	Assert(InStr(Src, 'WebView_SweepStaleProfiles("' . CreatePrefix . '")') > 0,
		Path . " must call WebView_SweepStaleProfiles before DirCreate")
	Assert(InStr(Src, "DirDelete") > 0,
		Path . " must delete the per-launch udir in its Close path")
}

; The single shared user-data folder must be a FIXED path (no A_TickCount), so it
; cannot accumulate -- exactly one folder, reused for the whole session.
_TWTL_SharedFolderIsFixed() {
	Src := _TWTL_ReadSource("lib/webview_utils.ahk")
	Assert(InStr(Src, "WebView_SharedEnvironment") > 0,
		"lib/webview_utils.ahk must define the shared environment helper")
	Assert(InStr(Src, 'WEBVIEW_SHARED_UDIR := A_Temp . "\ergopti_wv_shared"') > 0,
		"WEBVIEW_SHARED_UDIR must be a single fixed path (leak-free by construction)")
}

_TWTL_AllHosts() {
	; Shared-env hosts (leak-free by construction).
	_TWTL_CheckSharedHost("ui/changelog/init.ahk", "ergopti_changelog_wv_")
	_TWTL_CheckSharedHost("ui/healthcheck/core.ahk", "ergopti_hc_wv_")
	_TWTL_CheckSharedHost("ui/model_browser/init.ahk", "ergopti_modelbrowser_wv_")
	_TWTL_CheckSharedUpdaterModule()
	_TWTL_SharedFolderIsFixed()
	; Legacy per-launch hosts (interactive/long-lived) -- still sweep + delete.
	_TWTL_CheckLegacyHost("modules/keylogger/keylogger_ui.ahk", "ergopti_metrics_edge_")
	_TWTL_CheckLegacyHost("modules/keylogger/keylogger_webview.ahk", "ergopti_webview2_")
	_TWTL_CheckLegacyHost("modules/llm/ollama_webview.ahk", "ergopti_ollama_wv_")
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

_TWTL_KeyloggerWVDeferredDelete() {
	Src := _TWTL_ReadSource("modules/keylogger/keylogger_webview.ahk")
	Close := _DriverFuncBody("KLWV_Close")
	Assert(InStr(Close, "KLWV_DeferredDirDelete") > 0,
		"KLWV_Close must defer user-data cleanup until Edge releases its profile lock")
	Assert(InStr(Close, 'DirDelete(entry["udir"], true)') = 0,
		"KLWV_Close must not recursively delete the profile inline on the UI callback")
	Assert(InStr(Src, "KLWV_DeferredDirDelete(udir, attempts := 0)") > 0,
		"Keylogger WebView cleanup must expose a bounded deferred deletion helper")
}

Test("WebView2 hosts: sweep stale profiles and delete on close", _TWTL_AllHosts)
Test("OllamaWV_Close: udir deletion is deferred via SetTimer to avoid Edge file lock race", _TWTL_OllamaWVDeferredDelete)
Test("KLWV_Close: udir deletion is deferred via SetTimer to avoid Edge file lock race", _TWTL_KeyloggerWVDeferredDelete)
