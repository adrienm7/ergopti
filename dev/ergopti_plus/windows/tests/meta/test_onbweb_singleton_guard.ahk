; tests/meta/test_onbweb_singleton_guard.ahk

; ==============================================================================
; MODULE: Onboarding WebView2 Singleton Guard Meta Test
; DESCRIPTION:
; Regression guard for F35 (AUDIT_AHK_2026-07-01.md): _Onboarding_TryWeb was the
; only WebView2 host in the driver missing the "if (_XxxWeb_Gui != 0) { WinActivate;
; return true }" singleton guard present in every sibling (paths_editor,
; personal_info_editor, prompt_editor, hotstrings_config_window). A second
; tray-menu click while the wizard was open silently overwrote the shared
; _ob_gui sentinel with a NEW window, orphaning the first one; on close,
; _OnbWeb_OnClose always read whichever Gui _ob_gui currently pointed to, so it
; tore down the SECOND (live) window instead of the orphaned first one.
;
; SCOPE: source introspection only — exercising a real double-open needs a live
; WebView2 runtime unavailable in the headless test harness (same rationale as
; tests/meta/test_hsedweb_reset_idempotent.ahk and
; tests/meta/test_webview_reset_idempotent_siblings.ahk).
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers =====================
; ====================================================
; ====================================================

_ONBWSG_TryWebBody() {
	return _DriverFuncBody("_Onboarding_TryWeb")
}




; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_ONBWSG_GuardPresentAndActivatesExisting() {
	Body := _ONBWSG_TryWebBody()
	Assert(Body != "", "_Onboarding_TryWeb must be defined in ui/onboarding/webview.ahk")

	Assert(InStr(Body, "_ob_gui != 0") > 0,
		"_Onboarding_TryWeb must check '_ob_gui != 0' — the singleton guard every sibling WebView2 host (paths_editor, personal_info_editor, prompt_editor, hotstrings_config_window) already has (onbweb-singleton-guard)")
	Assert(InStr(Body, "WinActivate") > 0,
		"_Onboarding_TryWeb must WinActivate the existing wizard window when _ob_gui is already set, instead of silently building a second one (onbweb-singleton-guard)")
	Assert(InStr(Body, "return true") > 0,
		"_Onboarding_TryWeb must return true from the singleton branch so the caller (Onboarding_Run / Onboarding_ShowFromMenu) treats the existing window as the active wizard and does not also fall back to the native pages (onbweb-singleton-guard)")
}

Test("onbweb_singleton_guard: _Onboarding_TryWeb checks _ob_gui != 0 and activates the existing window (onbweb-singleton-guard)",
	_ONBWSG_GuardPresentAndActivatesExisting)


_ONBWSG_GuardRunsBeforeSecondGuiIsBuilt() {
	Body := _ONBWSG_TryWebBody()

	IdxGuard  := InStr(Body, "_ob_gui != 0")
	IdxReturn := InStr(Body, "return true", , IdxGuard)
	IdxGuiNew := InStr(Body, "g := Gui(")
	Assert(IdxGuard > 0 and IdxReturn > 0 and IdxGuiNew > 0 and IdxGuard < IdxGuiNew and IdxReturn < IdxGuiNew,
		"_Onboarding_TryWeb must check '_ob_gui != 0' and return true BEFORE 'g := Gui(' builds a second window — checking after the new Gui is already created would still orphan the first one and overwrite _ob_gui out from under it (onbweb-singleton-guard)")
}

Test("onbweb_singleton_guard: the singleton check runs before a second wizard Gui is built (onbweb-singleton-guard)",
	_ONBWSG_GuardRunsBeforeSecondGuiIsBuilt)


_ONBWSG_DuplicateOpenPreservesExistingSessionOwner() {
	Body := _ONBWSG_TryWebBody()

	IdxGuard := InStr(Body, "_ob_gui != 0")
	IdxReturn := InStr(Body, "return true", , IdxGuard)
	IdxEpoch := InStr(Body, "_OnbWeb_SessionEpoch += 1")
	IdxResetDone := InStr(Body, "_OnbWeb_ResetDone := false")
	Assert(IdxGuard > 0 and IdxReturn > 0 and IdxEpoch > 0 and IdxResetDone > 0 and IdxReturn < IdxEpoch and IdxReturn < IdxResetDone,
		"_Onboarding_TryWeb must return from its singleton branch before advancing the WebView session epoch or resetting teardown ownership — otherwise a duplicate open revokes every callback already bound to the live wizard (AHK-164)")
}

Test("onbweb_singleton_guard: duplicate open preserves the existing WebView session owner (AHK-164)",
	_ONBWSG_DuplicateOpenPreservesExistingSessionOwner)
