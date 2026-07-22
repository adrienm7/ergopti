; tests/meta/test_pathstoml_read_missing_utf8_encoding.ahk

; ==============================================================================
; MODULE: paths.toml UTF-8 Read Guard Meta Test
; DESCRIPTION:
; Static source guard for finding pathstoml-read-missing-utf8-encoding.
;
; ReadPathsToml() used to parse paths.toml via a bare FileRead(FilePath) with
; no encoding argument. The auto-generated file carries a UTF-8 BOM (which
; FileRead auto-detects), so the common path worked - but a BOM-less paths.toml
; (hand-saved as UTF-8 without a BOM, or produced by another tool) was decoded
; with the system codepage. A ConfigDirPath under a non-ASCII Windows home dir
; (accented username) then became mojibake, StrReplace("/","\") yielded a path
; that does not exist, and the user's entire personal config silently failed
; to load with no error.
;
; The fix reads with the explicit "UTF-8" encoding, matching the writer
; (FileOpen(..., "UTF-8")) and every other reader in the unit. This meta-static
; test asserts the encoding argument is present on the ReadPathsToml read so a
; regression to the bare FileRead is caught.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_PRMUE_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Encoding guard assertion ==============
; ==================================================
; ==================================================

_PRMUE_ReadPathsTomlUsesUtf8() {
	Src := _PRMUE_ReadSource("lib/toml/toml_helpers.ahk")
	Seg := _DriverFuncBody("ReadPathsToml")
	Assert(Seg != "", "ReadPathsToml(FilePath) declaration must exist in toml_helpers.ahk")
	; The parse loop must read with an explicit UTF-8 encoding so a BOM-less
	; paths.toml is decoded correctly rather than via the system codepage.
	Assert(InStr(Seg, "FileRead(FilePath, " . Chr(34) . "UTF-8" . Chr(34) . ")") > 0,
		"ReadPathsToml must call FileRead(FilePath, " . Chr(34) . "UTF-8" . Chr(34) . ") - a bare FileRead mis-decodes a BOM-less paths.toml with a non-ASCII ConfigDirPath, silently losing the user's config")
	; Guard against the exact pre-fix form: a bare FileRead with no encoding arg
	; in the loop-parse expression.
	Assert(InStr(Seg, "loop parse, FileRead(FilePath), ") = 0,
		"ReadPathsToml must not parse via a bare FileRead(FilePath) with no encoding - that is the mojibake regression")
}
Test("toml_helpers: ReadPathsToml reads paths.toml as UTF-8 (pathstoml-read-missing-utf8-encoding)", _PRMUE_ReadPathsTomlUsesUtf8)
