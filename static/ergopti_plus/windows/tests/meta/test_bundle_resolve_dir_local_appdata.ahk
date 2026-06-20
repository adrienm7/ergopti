; tests/meta/test_bundle_resolve_dir_local_appdata.ahk

; ==============================================================================
; MODULE: Bundle ResolveDir LocalAppData Meta Test
; DESCRIPTION:
; Regression guard ensuring _Bundle_ResolveDir() uses A_LocalAppData directly
; instead of navigating from A_AppData via an unresolved ".." segment.
;
; SCOPE: source introspection of lib/bundle.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_BRDL_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}

_BRDL_FuncBody(Src, FnDecl) {
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

_BRDL_CheckNoDoubleDot() {
	Src := _BRDL_ReadSource("lib/bundle.ahk")
	Assert(Src != "", "lib/bundle.ahk must be readable")

	Body := _DriverFuncBody("_Bundle_ResolveDir")
	Assert(Body != "", "_Bundle_ResolveDir must be present in lib/bundle.ahk")

	Assert(!InStr(Body, '".."') && !InStr(Body, '"\.."'),
		"_Bundle_ResolveDir must not use A_AppData with a '..' segment to reach LocalAppData")
}

_BRDL_CheckUsesLocalAppData() {
	Src := _BRDL_ReadSource("lib/bundle.ahk")
	Assert(Src != "", "lib/bundle.ahk must be readable")

	Body := _DriverFuncBody("_Bundle_ResolveDir")
	Assert(Body != "", "_Bundle_ResolveDir must be present in lib/bundle.ahk")

	Assert(InStr(Body, "A_LocalAppData"),
		"_Bundle_ResolveDir must use A_LocalAppData directly instead of traversing from A_AppData")
}


Test("meta bundle-resolve-dir: does not use A_AppData with '..' traversal",
	_BRDL_CheckNoDoubleDot)

Test("meta bundle-resolve-dir: uses A_LocalAppData directly",
	_BRDL_CheckUsesLocalAppData)