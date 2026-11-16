; tests/meta/core/ui/webview/test_low_ram_native_fallback.ahk

; ==============================================================================
; MODULE: WebView Low-RAM Native Fallback Meta Test
; DESCRIPTION:
; Static source guard for the low-RAM WebView fallback feature.
;
; On a RAM-starved machine the Edge/Chromium cold start costs many seconds, so
; WebView windows that have a native equivalent skip WebView2 and use that native
; view when free RAM is below WEBVIEW_MIN_AVAIL_RAM_MB. This test pins:
;   1. the shared gate helper exists in core/ui/engine/webview/utils.ahk,
;   2. cold-start gating never suppresses an already-running browser,
;      and diagnostics always attempt their structured shared page,
;   3. updater/changelog has a real native notes fallback (an Edit), so gating
;      it cannot leave the notes pane blank.
; ==============================================================================

#Requires AutoHotkey v2.0

_TWLR_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; The shared gate helper + tunable threshold must live in webview_utils.ahk.
_TWLR_GateHelperExists() {
	Src := _TWLR_ReadSource("core/ui/engine/webview/utils.ahk")
	Assert(InStr(Src, "WebView_ShouldUseNativeFallback") > 0,
		"core/ui/engine/webview/utils.ahk must define WebView_ShouldUseNativeFallback")
	Assert(InStr(Src, "WEBVIEW_MIN_AVAIL_RAM_MB") > 0,
		"core/ui/engine/webview/utils.ahk must define the tunable WEBVIEW_MIN_AVAIL_RAM_MB threshold")
	Assert(InStr(Src, "GlobalMemoryStatusEx") > 0,
		"WebView_AvailRamMb must read free RAM via GlobalMemoryStatusEx")
}
Test("webview-lowram: gate helper + threshold defined in webview_utils", _TWLR_GateHelperExists)

; Diagnostics must attempt the shared page; RAM alone is no browser failure.
_TWLR_HealthcheckAttempted() {
	Src := _DriverDirConcat("ui/healthcheck")
	Assert(Src != "", "healthcheck source must exist")
	Assert(InStr(Src, "WebView_ShouldUseNativeFallback") = 0,
		"diagnostics must attempt the installed browser even under memory pressure")
	Assert(InStr(Src, "_HC_ShowNativeSnapshot(G, Snapshot)") > 0,
		"a real browser failure must retain structured native diagnostics")
}
Test("webview-lowram: diagnostics attempt WebView2 regardless of free RAM", _TWLR_HealthcheckAttempted)

; The updater module (changelog pane + update prompt) must gate the same way.
_TWLR_UpdaterModuleGated() {
	Src := _DriverDirConcat("modules/updater")
	Assert(InStr(Src, "WebView_ShouldUseNativeFallback") > 0,
		"modules/updater must gate WebView2 on WebView_ShouldUseNativeFallback")
}
Test("webview-lowram: updater module gates WebView2 on free RAM", _TWLR_UpdaterModuleGated)

; changelog_window must redirect to the native changelog window when RAM is low.
_TWLR_ChangelogWindowGated() {
	Src := _TWLR_ReadSource("ui/changelog/init.ahk")
	Assert(InStr(Src, "WebView_ShouldUseNativeFallback") > 0,
		"changelog_window must redirect to the native changelog window when free RAM is low")
}
Test("webview-lowram: changelog_window redirects to native window on low RAM", _TWLR_ChangelogWindowGated)

; The model browser already ships a native ListView; it must prefer that over
; WebView2 when free RAM is low (the web path is gated, native Build is the fallback).
_TWLR_ModelBrowserGated() {
	Src := _TWLR_ReadSource("ai/ui/model_browser/init.ahk")
	Assert(InStr(Src, "WebView_ShouldUseNativeFallback") > 0,
		"model_browser must gate its WebView2 path on WebView_ShouldUseNativeFallback (low RAM -> native ListView)")
}
Test("webview-lowram: model_browser prefers native ListView on low RAM", _TWLR_ModelBrowserGated)

; Gating updater/changelog only helps if its non-WebView path actually renders the
; notes. Before this feature ShowBody returned 0 with WebView2 off, leaving the
; pane blank. Pin the native Edit fallback so that regression cannot return.
_TWLR_UpdaterChangelogHasNativeNotes() {
	Src := _DriverDirConcat("modules/updater")
	Assert(InStr(Src, "RightPaneEdit") > 0,
		"updater changelog must build a native RightPaneEdit fallback when WebView2 is off")
	Assert(InStr(Src, "RightPaneEdit.Value := _Updater_ReleaseNotesToPlain(md)") > 0,
		"ShowBody must render the changelog section into the native Edit via _Updater_ReleaseNotesToPlain (not raw md, not a no-op)")
}
Test("webview-lowram: updater changelog renders notes natively when WebView2 is off", _TWLR_UpdaterChangelogHasNativeNotes)

; The native notes must RENDER the Markdown (strip ## / ** etc.), not dump raw
; markup -- the reported regression. Exercise the converter directly.
_TWLR_MarkdownToPlainStripsMarkup() {
	out := _Updater_MarkdownToPlain("## Changes`n" . "**bold** and *italic* and " . '``code``' . "`n- one`n[site](https://x.io)")
	Assert(InStr(out, "##") = 0, "headings must not keep ## markup")
	Assert(InStr(out, "**") = 0, "bold must not keep ** markup")
	Assert(InStr(out, "Changes") > 0, "heading text must survive")
	Assert(InStr(out, "bold") > 0, "bold text must survive")
	Assert(InStr(out, "italic") > 0, "italic text must survive")
	Assert(InStr(out, "code") > 0, "inline code text must survive")
	Assert(InStr(out, "https://x.io") > 0, "link URL must survive as plain text")
}
Test("webview-lowram: _Updater_MarkdownToPlain strips markup for the native notes view", _TWLR_MarkdownToPlainStripsMarkup)

_TWLR_ColdAndWarmDecisions() {
	global _WebView_SharedEnv, WEBVIEW_MIN_AVAIL_RAM_MB
	SavedEnvironment := _WebView_SharedEnv
	try {
		_WebView_SharedEnv := 0
		for Available in [0, 1512222720 / 1048576, WEBVIEW_MIN_AVAIL_RAM_MB - 1]
			AssertTrue(WebView_ShouldUseNativeFallback(_TWLR_MemoryReading.Bind(Available)),
				"an optional cold-start native equivalent still respects low memory")
		for Available in [-1, WEBVIEW_MIN_AVAIL_RAM_MB, WEBVIEW_MIN_AVAIL_RAM_MB + 1]
			AssertFalse(WebView_ShouldUseNativeFallback(_TWLR_MemoryReading.Bind(Available)),
				"unknown readings and sufficient memory must attempt the browser")
		_WebView_SharedEnv := {name: "warm-browser"}
		AssertFalse(WebView_ShouldUseNativeFallback(_TWLR_UnexpectedMemoryQuery),
			"a warm browser must be reused without querying cold-start headroom")
	} finally {
		_WebView_SharedEnv := SavedEnvironment
	}
}

_TWLR_MemoryReading(Available) {
	return Available
}

_TWLR_UnexpectedMemoryQuery() {
	throw Error("a warm environment must not query free memory")
}
Test("webview-lowram: cold-start boundaries and warm browser reuse",
	_TWLR_ColdAndWarmDecisions)

_TWLR_Value(Value) {
	return Value
}

_TWLR_RecordNotice(Notices, Text) {
	Notices.Push(Text)
}

; The minimum is compared part by part: "100.0" is newer than "87.0.664.8" though
; a string comparison says otherwise. The refusal speaks once per run.
_TWLR_RuntimeMinimum() {
	global _WebView_RuntimeRefusalShown, _WebView_SharedEnv, WEBVIEW_MIN_RUNTIME_VERSION
	SavedShown := _WebView_RuntimeRefusalShown
	SavedEnvironment := _WebView_SharedEnv
	Notices := []
	Notice := _TWLR_RecordNotice.Bind(Notices)
	try {
		_WebView_RuntimeRefusalShown := false
		_WebView_SharedEnv := 0
		for Version in ["", WEBVIEW_MIN_RUNTIME_VERSION, "87.0.664.9", "100.0.0.0", "141.0.3537.71"]
			AssertFalse(WebView_RuntimeIsRefused(_TWLR_Value.Bind(Version), Notice), "version '" . Version . "' is admitted")
		AssertEqual(0, Notices.Length, "an admitted runtime says nothing")
		for Version in ["87.0.664.7", "86.0.622.38", "9.0.0.0"]
			AssertTrue(WebView_RuntimeIsRefused(_TWLR_Value.Bind(Version), Notice), "version " . Version . " is refused")
		AssertEqual(1, Notices.Length, "the refusal speaks once")
		AssertContains(Notices[1], WEBVIEW_MIN_RUNTIME_VERSION, "it names the minimum")
		AssertContains(Notices[1], "87.0.664.7", "and the version found")
		AssertTrue(WebView_ShouldUseNativeFallback(_TWLR_UnexpectedMemoryQuery, _TWLR_Value.Bind(true)),
			"a refused runtime takes the native fallback before reading the memory")
		AssertFalse(WebView_ShouldUseNativeFallback(_TWLR_MemoryReading.Bind(-1), _TWLR_Value.Bind(false)),
			"an admitted runtime goes on to the memory reading")
	} finally {
		_WebView_RuntimeRefusalShown := SavedShown
		_WebView_SharedEnv := SavedEnvironment
	}
}
Test("webview-runtime: a runtime below the minimum is refused in words, native fallback kept",
	_TWLR_RuntimeMinimum)
