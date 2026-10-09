; tests/meta/test_hook_dispatcher_critical_save_restore.ahk

; ==============================================================================
; MODULE: HookDispatcher Critical Save/Restore Meta Test
; DESCRIPTION:
; Regression guard ensuring HookDispatcher.Register and HookDispatcher.Unregister
; save the caller's Critical state before entering their own Critical section and
; restore it in the finally block, rather than unconditionally calling Critical("Off")
; which would clobber a caller already inside a Critical section.
;
; SCOPE: source introspection of infra/hook_dispatcher.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_HDCS_FuncBody(Src, FnDecl) {
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


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_HDCS_CheckRegisterSaveRestore() {
	Src := _DriverDirConcat("infra")

	RegBody := _HDCS_FuncBody(Src, "static Register(")
	Assert(RegBody != "", "HookDispatcher.Register must be present")

	Assert(!InStr(RegBody, 'Critical("Off")'),
		"Register must not call Critical(Off) unconditionally — must restore prior state via saved return value")
	Assert(InStr(RegBody, "_prev_crit"),
		'Register must save Critical return value in _prev_crit and restore it in finally')
}

_HDCS_CheckUnregisterSaveRestore() {
	Src := _DriverDirConcat("infra")

	UnregBody := _HDCS_FuncBody(Src, "static Unregister(")
	Assert(UnregBody != "", "HookDispatcher.Unregister must be present")

	Assert(!InStr(UnregBody, 'Critical("Off")'),
		"Unregister must not call Critical(Off) unconditionally — must restore prior state via saved return value")
	Assert(InStr(UnregBody, "_prev_crit"),
		'Unregister must save Critical return value in _prev_crit and restore it in finally')
}


Test("meta hook-dispatcher: Register saves/restores caller Critical state",
	_HDCS_CheckRegisterSaveRestore)

Test("meta hook-dispatcher: Unregister saves/restores caller Critical state",
	_HDCS_CheckUnregisterSaveRestore)