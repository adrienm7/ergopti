; tests/meta/test_ext_builder_fn_dynamic_call_swallow.ahk

; ==============================================================================
; MODULE: Extension Builder Fail-Loud Meta Test
; DESCRIPTION:
; Static source guard for finding ext-builder-fn-dynamic-call-swallow.
;
; _SC_Extensions() invokes each extension's BuildExtMenu_<id> via dynamic
; %BuilderFn% during menu build. The old code caught a thrown builder with a
; LoggerWarn only, so a broken extension produced a present-but-empty submenu
; indistinguishable from an absent one -- the only trace was a WARNING line the
; user never reads. That violates the project's fail-loud convention for
; user-actionable surfaces.
;
; The fix: on catch, log an ERROR (not a Warn) and add a visible disabled error
; row to the extension submenu; additionally, after a non-throwing call, count
; the items the builder actually added (via _ExtMenuItemCount) and show the same
; marker when it populated nothing. This test asserts those guards are present.
;
; Meta-static because ui/tray_menu.ahk registers top-level menu hooks and is not
; part of the headless run_all include graph; it cannot be #Included by the
; runner without side effects.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_EBFD_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Returns the function body from its declaration to the first flush-left closing
; brace. Returns "" when the declaration is absent.
_EBFD_FuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		return SubStr(Rest, 1, End + 1)
	return Rest
}




; ==================================================
; ==================================================
; ======= 2/ Fail-loud guard assertions ============
; ==================================================
; ==================================================

_EBFD_CatchFailsLoud() {
	Src := _EBFD_ReadSource("ui/tray_menu.ahk")
	Seg := _EBFD_FuncBody(Src, "_SC_Extensions(SubMenu, _Cat) {")
	Assert(Seg != "", "_SC_Extensions(SubMenu, _Cat) declaration must exist in tray_menu.ahk")
	; The thrown-builder branch must log an ERROR, not merely a Warn the user
	; never reads.
	Assert(InStr(Seg, "LoggerError(" . Chr(34) . "Extensions") > 0,
		"_SC_Extensions must LoggerError (not just Warn) when a BuildExtMenu_<id> throws -- a broken extension is user-actionable")
}
Test("tray_menu: extension builder failure logs an ERROR (ext-builder-fn-dynamic-call-swallow)", _EBFD_CatchFailsLoud)

_EBFD_RendersVisibleErrorRow() {
	Src := _EBFD_ReadSource("ui/tray_menu.ahk")
	Seg := _EBFD_FuncBody(Src, "_SC_Extensions(SubMenu, _Cat) {")
	Assert(Seg != "", "_SC_Extensions(SubMenu, _Cat) declaration must exist in tray_menu.ahk")
	; A failed/empty builder must produce a visible disabled marker built from a
	; localised error prefix plus the ExtId, so it is not mistaken for an absent
	; extension.
	Assert(InStr(Seg, "common.error_prefix") > 0,
		"_SC_Extensions must add a visible disabled error row (localised common.error_prefix + ExtId) when an extension builder fails or adds nothing")
}
Test("tray_menu: extension builder failure shows a visible disabled row (ext-builder-fn-dynamic-call-swallow)", _EBFD_RendersVisibleErrorRow)

_EBFD_ValidatesItemsPopulated() {
	Src := _EBFD_ReadSource("ui/tray_menu.ahk")
	Seg := _EBFD_FuncBody(Src, "_SC_Extensions(SubMenu, _Cat) {")
	Assert(Seg != "", "_SC_Extensions(SubMenu, _Cat) declaration must exist in tray_menu.ahk")
	; A builder may return without throwing yet populate nothing; the fix counts
	; the items added and treats zero as a failure.
	Assert(InStr(Seg, "_ExtMenuItemCount(") > 0,
		"_SC_Extensions must validate the builder populated at least one item (via _ExtMenuItemCount) so a silently-empty submenu also surfaces the error marker")
	; And the counting helper itself must exist.
	Assert(InStr(Src, "_ExtMenuItemCount(MenuObj) {") > 0,
		"tray_menu.ahk must define the _ExtMenuItemCount helper used to detect an empty extension submenu")
}
Test("tray_menu: extension builder result is validated for emptiness (ext-builder-fn-dynamic-call-swallow)", _EBFD_ValidatesItemsPopulated)
