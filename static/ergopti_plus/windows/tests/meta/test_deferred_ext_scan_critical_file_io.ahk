; tests/meta/test_deferred_ext_scan_critical_file_io.ahk

; ==============================================================================
; MODULE: Deferred Extension-Scan Critical File-I/O Guard Meta Test
; DESCRIPTION:
; Static source guard for MEDIUM-03: bundled-extension I/O ran under Critical.
;
; _HS_Extensions built the bundled-extensions submenu by recursing the
; extensions tree (DirExist + Loop Files + FileRead of every manifest.toml and
; hotstrings TOML). It is invoked from initMenu()/InitSubMenus(), which
; BuildTrayMenuDeferred wraps in Critical("On"). Critical starves the message
; pump and the LL keyboard hook for its whole duration, so this unbounded file
; I/O — slow on a cloud-synced static dir or a spun-down drive — turned the
; menu build into a multi-second keyboard freeze.
;
; The fix warms a cache via _HS_PreScanExtensions() BEFORE Critical("On") and
; makes _HS_Extensions read that cache instead of doing direct I/O. This test
; asserts the prescan call precedes Critical in BuildTrayMenuDeferred and that
; _HS_Extensions no longer does Loop Files / FileRead(ManifestPath), so a
; regression that moves the I/O back under Critical fails CI.
;
; SCOPE: source introspection of ErgoptiPlus.ahk and ui/tray_menu.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Body delimited by the first closing brace flush-left (`\n}`).
_DESC_FuncBodyFlat(Src, FuncDef) {
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
; ======= 2/ Guard assertions ======================
; ==================================================
; ==================================================

; Strips ;-comments line by line so source-prose that mentions a token (e.g. a
; comment saying "Critical(On) starves the hook") cannot fool a positional or
; substring assertion. Only executable code remains.
_DESC_StripComments(Body) {
	out := ""
	loop parse, Body, "`n", "`r" {
		Line := A_LoopField
		Trimmed := LTrim(Line, " `t")
		if (SubStr(Trimmed, 1, 1) == ";")
			continue
		out .= Line . "`n"
	}
	return out
}

_DESC_PrescanRunsOutsideCritical() {
	Src := _DriverSourceConcat()
	Seg := _DESC_FuncBodyFlat(Src, "BuildTrayMenuDeferred() {")
	Assert(Seg != "", "BuildTrayMenuDeferred() must exist in ErgoptiPlus.ahk")

	; Strip comments so prose cannot fool the executable-code assertions.
	Code := _DESC_StripComments(Seg)
	PreScanPos := InStr(Code, "_HS_PreScanExtensions()")
	Assert(PreScanPos > 0,
		"_HS_PreScanExtensions() must be called in BuildTrayMenuDeferred")
	Assert(InStr(Code, 'Critical("On")') = 0,
		'BuildTrayMenuDeferred must not hold Critical around extension I/O; staging confines Critical to publication (MEDIUM-03)')
}

_DESC_ExtMenuDoesNoFileIO() {
	Body := _DriverFuncBody("_HS_Extensions")
	Assert(Body != "", "_HS_Extensions must exist in the driver source")

	; Strip comments so a comment that names "Loop Files" / "FileRead" (explaining
	; where the I/O moved to) cannot trip these assertions — only real code counts.
	Code := _DESC_StripComments(Body)
	Assert(InStr(Code, "Loop Files") = 0,
		"_HS_Extensions must NOT iterate the extensions tree with Loop Files — read the pre-warmed cache instead (MEDIUM-03)")
	Assert(InStr(Code, "FileRead(ManifestPath") = 0,
		"_HS_Extensions must NOT FileRead(ManifestPath) — manifest parsing must happen in the off-Critical prescan (MEDIUM-03)")
}

Test("meta deferred-ext-scan: BuildTrayMenuDeferred keeps extension scan outside Critical (MEDIUM-03)", _DESC_PrescanRunsOutsideCritical)
Test("meta deferred-ext-scan: _HS_Extensions does no file I/O at menu-build time (MEDIUM-03)", _DESC_ExtMenuDoesNoFileIO)
