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
; SCOPE: source introspection of lib/updater.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ Source scan helpers ==================
; =================================================
; =================================================

_UCSG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	SplitPath(WindowsDir, , &Root)
	Path := Root . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}

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
	Src := _UCSG_ReadSource("lib/updater.ahk")
	Assert(Src != "", "lib/updater.ahk must be readable")

	Body := _UCSG_FuncBody(Src, FnDecl)
	Assert(Body != "", FnDecl . " must be present in updater.ahk")

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

Test("meta updater-callback-suspend: _Updater_ShowAvailableUpdateCallback guards A_IsSuspended",
	() => _UCSG_CheckFnHasSuspendGuard("_Updater_ShowAvailableUpdateCallback(Json) {"))
