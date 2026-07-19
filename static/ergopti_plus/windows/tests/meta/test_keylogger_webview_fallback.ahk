; tests/meta/test_keylogger_webview_fallback.ahk
;
; ==============================================================================
; MODULE: Keylogger WebView Required-Setup Fallback Meta Test
; DESCRIPTION:
; A WebView runtime being discoverable does not guarantee that a controller can
; be created or that its dashboard can navigate. The previous toggle returned
; immediately after KLWV_Open(), ignoring false and silently losing the user
; action behind a blank/absent WebView. The Edge --app= fallback must remain
; reachable exactly when the required WebView setup transaction fails.
; ==============================================================================

#Requires AutoHotkey v2.0

_KWF_WebViewFailureFallsBackToEdge() {
	Body := _DriverFuncBody("KLUI_ToggleDashboard")
	Assert(Body != "", "KLUI_ToggleDashboard must exist in modules/keylogger/keylogger_ui.ahk")
	OpenPos := InStr(Body, "if KLWV_Open(which, metrics_dir)")
    FallbackPos := InStr(Body, "KLUI.typing_pid := KLUI_LaunchWindow")
	Assert(OpenPos > 0 and FallbackPos > OpenPos,
		"a false KLWV_Open result must fall through to the legacy Edge launcher instead of returning after runtime availability")
	Assert(InStr(Body, "if KLWV_Open(which, metrics_dir)`n            return") > 0,
		"only a successful KLWV_Open may return before the Edge fallback; this encodes the caller-enforced Boolean contract")
}

_KWF_RequiredSetupFailsClosed() {
    Body := _DriverFuncBody("KLWV_Open")
    Assert(Body != "", "KLWV_Open must exist in modules/keylogger/keylogger_webview.ahk")
    Assert(InStr(Body, "asset_path := KLWV_AssetPath(which)") > 0
        and InStr(Body, "if !FileExist(asset_path)") > 0,
        "KLWV_Open must reject a missing local dashboard asset before publishing a blank file:/// host")
    Assert(InStr(Body, "catch as err {") > 0
        and InStr(Body, "KLWV_AbortOpen(g, controller, udir)") > 0,
        "controller bridge/navigation failures must close the unpublished host and return false to the caller")
    Abort := _DriverFuncBody("KLWV_AbortOpen")
    Assert(Abort != "" and InStr(Abort, "controller.Close()") > 0 and InStr(Abort, "gui.Destroy()") > 0,
        "KLWV_AbortOpen must release both the controller and its GUI before the Edge fallback is launched")
}

Test("keylogger: failed WebView open falls back to Edge exactly once (webview-required-setup-fallback)",
    _KWF_WebViewFailureFallsBackToEdge)
Test("keylogger: unpublished WebView setup failures fail closed (webview-required-setup-fallback)",
    _KWF_RequiredSetupFailsClosed)
