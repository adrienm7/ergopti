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

_DESC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

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

; Body via balanced brace-walking (handles nested blocks).
_DESC_FuncBodyWalk(Src, FuncName) {
	Idx := InStr(Src, FuncName)
	if (!Idx)
		return ""
	OpenPos := InStr(Src, "{", , Idx)
	if (!OpenPos)
		return ""
	depth := 0
	i := OpenPos
	Len := StrLen(Src)
	while (i <= Len) {
		ch := SubStr(Src, i, 1)
		if (ch == "{")
			depth++
		else if (ch == "}") {
			depth--
			if (depth <= 0)
				return SubStr(Src, Idx, i - Idx + 1)
		}
		i++
	}
	return SubStr(Src, Idx)
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

_DESC_PrescanWarmedBeforeCritical() {
	Src := _DESC_ReadSource("ErgoptiPlus.ahk")
	Seg := _DESC_FuncBodyFlat(Src, "BuildTrayMenuDeferred() {")
	Assert(Seg != "", "BuildTrayMenuDeferred() must exist in ErgoptiPlus.ahk")

	; Strip comments so prose that mentions Critical("On") cannot fool the
	; positional check — only executable code lines count.
	Code := _DESC_StripComments(Seg)
	Q := Chr(34)
	CritPos := InStr(Code, "Critical(" . Q . "On" . Q . ")")
	PreScanPos := InStr(Code, "_HS_PreScanExtensions()")
	Assert(PreScanPos > 0,
		"_HS_PreScanExtensions() must be called in BuildTrayMenuDeferred")
	Assert(CritPos > 0,
		'Critical("On") must be called in BuildTrayMenuDeferred')
	Assert(PreScanPos < CritPos,
		'_HS_PreScanExtensions() must run BEFORE Critical("On") in BuildTrayMenuDeferred — warming the extensions cache off-Critical keeps the file I/O out of the keyboard-hook starvation window (MEDIUM-03)')
}

_DESC_ExtMenuDoesNoFileIO() {
	Src := _DESC_ReadSource("ui/tray_menu.ahk")
	Body := _DESC_FuncBodyWalk(Src, "_HS_Extensions(")
	Assert(Body != "", "_HS_Extensions( must exist in ui/tray_menu.ahk")

	; Strip comments so a comment that names "Loop Files" / "FileRead" (explaining
	; where the I/O moved to) cannot trip these assertions — only real code counts.
	Code := _DESC_StripComments(Body)
	Assert(InStr(Code, "Loop Files") = 0,
		"_HS_Extensions must NOT iterate the extensions tree with Loop Files — read the pre-warmed cache instead (MEDIUM-03)")
	Assert(InStr(Code, "FileRead(ManifestPath") = 0,
		"_HS_Extensions must NOT FileRead(ManifestPath) — manifest parsing must happen in the off-Critical prescan (MEDIUM-03)")
}

Test("meta deferred-ext-scan: BuildTrayMenuDeferred warms extensions cache before Critical (MEDIUM-03)", _DESC_PrescanWarmedBeforeCritical)
Test("meta deferred-ext-scan: _HS_Extensions does no file I/O at menu-build time (MEDIUM-03)", _DESC_ExtMenuDoesNoFileIO)
