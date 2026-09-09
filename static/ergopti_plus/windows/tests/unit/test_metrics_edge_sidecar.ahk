; static/ergopti_plus/windows/tests/unit/test_metrics_edge_sidecar.ahk

; ==============================================================================
; MODULE: Metrics Edge Sidecar Tests
; DESCRIPTION: The fallback page must read the sidecar its worker publishes.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../../modules/keylogger/keylogger_ui.ahk

_MES_UrlMatchesPublication(Which) {
	SavedTyping := KLUI.typing_url
	SavedApps := KLUI.apps_url
	try {
		_KLRDC_EnsureSharedDir()
		KLUI.typing_url := ""
		KLUI.apps_url := ""
		KLUI_EnsureUrls()
		Url := Which = "typing" ? KLUI.typing_url : KLUI.apps_url
		Parts := StrSplit(Url, "#prefetch=")
		AssertEqual(2, Parts.Length, "the fallback URL must carry one explicit sidecar")
		AssertTrue(InStr(Parts[1], "/metrics_" . Which . "/index.html") > 0,
			"the page asset must retain its metrics-prefixed folder")
		AssertEqual("file:///" . StrReplace(KLPF_PrefetchPath(Which), "\", "/"), Parts[2],
			"the URL must read the canonical sidecar published for this dashboard")
	} finally {
		KLUI.typing_url := SavedTyping
		KLUI.apps_url := SavedApps
	}
}
for Which in ["typing", "apps"]
	Test("metrics Edge: " . Which . " URL matches worker sidecar (metrics-edge-sidecar)",
		_MES_UrlMatchesPublication.Bind(Which))
