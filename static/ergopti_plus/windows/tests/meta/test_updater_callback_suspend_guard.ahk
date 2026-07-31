; tests/meta/test_updater_callback_suspend_guard.ahk

; ==============================================================================
; MODULE: Updater Async Callback Suspend Guard Meta Test
; DESCRIPTION:
; Regression guard ensuring async updater callbacks check A_IsSuspended before
; performing UI or install operations.
;
; The bug: _Updater_OneClickUpdateCallback and _Updater_ShowAvailableUpdateCallback
; are fired by the JSON-fetch poll timer.  AHK pseudo-threads spawned by timers
; bypass native Suspend, so the callbacks could pop update dialogs, display tray
; tips, or trigger an installer download even while the script was intentionally
; paused. The correct behaviour is to silently skip when A_IsSuspended is true.
;
; The fix: add `if A_IsSuspended return` at the top of both callbacks, mirroring
; the existing guard in the background-check timer body.
;
; SCOPE: source introspection of modules/updater.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ Source scan helpers ==================
; =================================================
; =================================================

_UCSG_FuncBody(Src, FnDecl) {
	FnPos := InStr(Src, FnDecl)
	if (!FnPos)
		return ""
	depth := 0
	i := FnPos
	Len := StrLen(Src)
	while (i <= Len) {
		ch := SubStr(Src, i, 1)
		if (ch == "{")
			depth++
		else if (ch == "}") {
			depth--
			if (depth <= 0)
				return SubStr(Src, FnPos, i - FnPos + 1)
		}
		i++
	}
	return SubStr(Src, FnPos)
}

_UCSG_CheckFnHasSuspendGuard(FnDecl) {
	Src := _DriverDirConcat("modules/updater")
	Assert(Src != "", "the modules/updater module must be readable")

	Body := _UCSG_FuncBody(Src, FnDecl)
	Assert(Body != "", FnDecl . " must be present in the modules/updater module")

	; The guard must appear before any UI/install operation
	SuspendPos := InStr(Body, "A_IsSuspended")
	Assert(SuspendPos > 0,
		FnDecl . " must check A_IsSuspended — async callbacks bypass native Suspend")

	; A_IsSuspended must precede the first MsgBox, TrayTip, or install trigger
	FirstAction := 0
	for _, Tok in ["MsgBox", "TrayTip", "Updater_StartInstall"] {
		p := InStr(Body, Tok)
		if (p > 0 and (FirstAction == 0 or p < FirstAction))
			FirstAction := p
	}
	if (FirstAction > 0)
		Assert(SuspendPos < FirstAction,
			"A_IsSuspended guard must precede the first UI/install call in " . FnDecl)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

Test("meta updater-callback-suspend: _Updater_OneClickUpdateCallback guards A_IsSuspended",
	() => _UCSG_CheckFnHasSuspendGuard("_Updater_OneClickUpdateCallback(Json, Current) {"))

_UCSG_SuspendedOneClickFinalisesMenu() {
	Body := _UCSG_FuncBody(_DriverDirConcat("modules/updater"), "_Updater_OneClickUpdateCallback(Json, Current) {")
	RebuildPos := InStr(Body, "_Updater_RebuildMenu()")
	SuspendPos := InStr(Body, "if A_IsSuspended")
	Assert(RebuildPos > 0 && SuspendPos > RebuildPos,
		"One-click updater callback must schedule tray reconciliation before its suspended-result return")
}
Test("meta updater-callback-suspend: suspended one-click callback reconciles tray state", _UCSG_SuspendedOneClickFinalisesMenu)

Test("meta updater-callback-suspend: _Updater_ShowAvailableUpdateCallback guards A_IsSuspended",
	() => _UCSG_CheckFnHasSuspendGuard("_Updater_ShowAvailableUpdateCallback(Json) {"))

Test("meta updater-callback-suspend: _Updater_HandleBackgroundResult guards A_IsSuspended",
	() => _UCSG_CheckFnHasSuspendGuard("_Updater_HandleBackgroundResult(Json, Current) {"))

; _Updater_BuildChangelogGui answers an async WinHTTP fetch (Pattern 1, 1e) —
; same bypass-Suspend exposure as the callbacks above, but it pops a Gui
; window rather than a MsgBox/TrayTip/install call, so it is checked directly
; here instead of through the FirstAction token list _UCSG_CheckFnHasSuspendGuard
; uses (that check is a no-op when none of its tokens are present).
_UCSG_CheckBuildChangelogGuiHasSuspendGuard() {
	Src := _DriverDirConcat("modules/updater")
	Assert(Src != "", "the modules/updater module must be readable")

	Body := _UCSG_FuncBody(Src, "_Updater_BuildChangelogGui(Json, Channel) {")
	Assert(Body != "", "_Updater_BuildChangelogGui must be present in the modules/updater module")

	SuspendPos := InStr(Body, "A_IsSuspended")
	Assert(SuspendPos > 0,
		"_Updater_BuildChangelogGui must check A_IsSuspended — it answers an async WinHTTP fetch that bypasses native Suspend")

	; Search for the actual Gui-construction call (opening quote right after
	; the paren) rather than a bare "Gui(" — the function's OWN name ends in
	; "...ChangelogGui(Json" at the very top of Body, which would otherwise
	; false-match "Gui(" one character into the function signature itself.
	GuiPos := InStr(Body, 'Gui("')
	if (GuiPos > 0)
		Assert(SuspendPos < GuiPos,
			"_Updater_BuildChangelogGui: A_IsSuspended guard must precede Gui construction")
}
Test("meta updater-callback-suspend: _Updater_BuildChangelogGui guards A_IsSuspended (suspend-guard-pattern-1)",
	_UCSG_CheckBuildChangelogGuiHasSuspendGuard)

; _Updater_OnTrayMsg (Pattern 1, 1i): an OnMessage handler for WM_TRAYICON
; balloon clicks, which bypasses native Suspend() entirely (not just async
; callbacks). Deliberately narrower than the tests above: the guard must gate
; the balloon-click branch specifically, not Updater_ShowAvailableUpdate
; itself, which also backs the tray menu's "check for updates" item and must
; keep working while paused.
_UCSG_CheckOnTrayMsgHasSuspendGuard() {
	Src := _DriverDirConcat("modules/updater")
	Assert(Src != "", "the modules/updater module must be readable")

	Body := _UCSG_FuncBody(Src, "_Updater_OnTrayMsg(wParam, lParam, msg, hwnd) {")
	Assert(Body != "", "_Updater_OnTrayMsg must be present in the modules/updater module")

	SuspendPos := InStr(Body, "A_IsSuspended")
	Assert(SuspendPos > 0,
		"_Updater_OnTrayMsg must check A_IsSuspended — an OnMessage handler bypasses native Suspend() entirely")

	CallPos := InStr(Body, "Updater_ShowAvailableUpdate()")
	Assert(CallPos > 0, "_Updater_OnTrayMsg must still call Updater_ShowAvailableUpdate() on a genuine balloon click")
	Assert(SuspendPos < CallPos,
		"_Updater_OnTrayMsg: A_IsSuspended guard must appear BEFORE the Updater_ShowAvailableUpdate() call")
}
Test("meta updater-callback-suspend: _Updater_OnTrayMsg guards A_IsSuspended (suspend-guard-pattern-1)",
	_UCSG_CheckOnTrayMsgHasSuspendGuard)
