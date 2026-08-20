; tests/meta/test_bypass_dispatch_arity.ahk

; ==============================================================================
; MODULE: Bypass Dispatch Arity Meta Test
; DESCRIPTION:
; Static source guard for the "bypass-dispatch-wrong-arity" finding (T-W06).
;
; _DispatchIfMissed() in infra/menu_dispatcher.ahk previously called the stored
; callback with a single string argument: Callback.Call("bypass_dispatch").
; AHK menu callbacks registered via Menu.Add receive three positional params
; (ItemName, ItemPos, MenuObj), so passing only one argument causes AHK to
; throw a "too few arguments" error at the call site, silently swallowed by
; the surrounding try block — the bypass fires but the real callback never
; runs, giving the user no feedback that anything happened.
;
; The fix: call Callback.Call("", 0, 0) to satisfy the three-parameter
; contract expected by every menu-item callback in the codebase.
;
; These tests assert the old single-argument form is gone and the correct
; three-argument form is present in the _DispatchIfMissed body.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================
; =====================================================
; ======= 1/ Source scan helpers ====================
; =====================================================
; =====================================================

_BDA_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; =====================================================
; =====================================================
; ======= 2/ Arity assertions =======================
; =====================================================
; =====================================================

_BDA_OldOneArgCallAbsent() {
	Src := _BDA_ReadSource("infra/menu_dispatcher.ahk")
	Seg := _DriverFuncBody("_DispatchIfMissed")
	Assert(Seg != "", "_DispatchIfMissed must exist in menu_dispatcher.ahk")
	; The old broken form passed a single string — any match here means the
	; regression has been reintroduced and the callback will always throw.
	Assert(InStr(Seg, 'Callback.Call("bypass_dispatch")') == 0,
		"_DispatchIfMissed must NOT call Callback.Call with a single string argument")
}
Test("menu_dispatcher: _DispatchIfMissed does not use old single-arg Callback.Call", _BDA_OldOneArgCallAbsent)

_BDA_ThreeArgCallPresent() {
	Src := _BDA_ReadSource("infra/menu_dispatcher.ahk")
	Seg := _DriverFuncBody("_DispatchIfMissed")
	Assert(Seg != "", "_DispatchIfMissed must exist in menu_dispatcher.ahk")
	; The correct form satisfies the (ItemName, ItemPos, MenuObj) arity that
	; every AHK menu callback expects, preventing a "too few arguments" throw.
	Assert(InStr(Seg, 'Callback.Call("", 0, 0)') > 0,
		"_DispatchIfMissed must call Callback.Call with 3 args matching the menu callback contract")
}
Test("menu_dispatcher: _DispatchIfMissed calls Callback with 3 args not 1", _BDA_ThreeArgCallPresent)
