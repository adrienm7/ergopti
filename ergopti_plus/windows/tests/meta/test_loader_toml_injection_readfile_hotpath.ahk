; tests/meta/test_loader_toml_injection_readfile_hotpath.ahk

; ==============================================================================
; MODULE: Tap-Hold Atomic Write + Truncated-Read Guard Meta Test
; DESCRIPTION:
; Static source guard for the "loader-toml-injection-readfile-hotpath" finding.
;
; The tap-hold writers previously persisted tap_hold.toml with a non-atomic
; FileDelete(Path) then FileAppend(Path) sequence. A crash or power loss between
; the two leaves an empty/truncated tap_hold.toml on disk; on the next boot the
; loader parses 0 keys and silently treats it as "no config", dropping every
; user tap-hold (CapsLock=Enter, etc.) with no warning.
;
; The fix has two halves:
;   1. Writers (_TH_WriteTapHoldToml, _TH_WriteTapHoldDisabled) durably stage
;      the content in a unique sibling file and publish it through
;      FSAtomicMoveReplace. The write-through rename is atomic on NTFS, so the
;      loader never observes a half-written file.
;   2. The loader (LoadTapHoldToml) raises a WARNING when an existing user file
;      parses to 0 keys without an explicit inherit_defaults=false, so a
;      truncated write is no longer silently indistinguishable from the
;      legitimate "Tout desactiver" opt-out.
;
; This is a meta-static test (it scans source text) because tap_hold_writer.ahk
; is not part of the headless run_all.ahk include graph (it pulls in tray/menu
; globals), so calling its functions would be a load-time error that hangs CI.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_LTI_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Returns the full function body — from its declaration to the first closing
; brace at column 0. Returns "" when the declaration is absent.
_LTI_FuncBody(Src, FuncDef) {
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
; ======= 2/ Atomic-write assertions ===============
; ==================================================
; ==================================================

_LTI_WriteTapHoldTomlIsAtomic() {
	Src := _LTI_ReadSource("platform/remap/tap_hold_writer.ahk")
	Seg := _DriverFuncBody("_TH_WriteTapHoldToml")
	Assert(Seg != "", "_TH_WriteTapHoldToml declaration must exist in tap_hold_writer.ahk")
	Assert(InStr(Seg, "FileDelete(Path)") == 0,
		"_TH_WriteTapHoldToml must NOT delete the live tap_hold.toml first — a crash before FileAppend truncates it (loader-toml-injection-readfile-hotpath)")
	Assert(InStr(Seg, "FSWriteDurable(StagePath, Content)") > 0,
		"_TH_WriteTapHoldToml must flush the complete private stage before publication")
	Assert(InStr(Seg, "FSAtomicMoveReplace(StagePath, BoundPath)") > 0,
		"_TH_WriteTapHoldToml must publish the complete stage with a write-through atomic replacement")
}
Test("tap_hold_writer: _TH_WriteTapHoldToml uses durable atomic replacement (loader-toml-injection-readfile-hotpath)", _LTI_WriteTapHoldTomlIsAtomic)

_LTI_WriteTapHoldDisabledIsAtomic() {
	Src := _LTI_ReadSource("platform/remap/tap_hold_writer.ahk")
	Seg := _DriverFuncBody("_TH_WriteTapHoldDisabled")
	CommitSeg := _DriverFuncBody("_TH_CommitTapHoldMutation")
	Assert(Seg != "", "_TH_WriteTapHoldDisabled declaration must exist in tap_hold_writer.ahk")
	Assert(CommitSeg != "", "_TH_CommitTapHoldMutation declaration must exist in tap_hold_writer.ahk")
	Assert(InStr(Seg, "FileDelete(Path)") == 0 and InStr(CommitSeg, "FileDelete(Path)") == 0,
		"_TH_WriteTapHoldDisabled must NOT delete the live tap_hold.toml first (loader-toml-injection-readfile-hotpath)")
	Assert(InStr(Seg, "_TH_CommitTapHoldMutation(") > 0
		and InStr(CommitSeg, "_TH_WriteTapHoldToml(Candidate") > 0,
		"_TH_WriteTapHoldDisabled must reach the single durable atomic writer through its detached-candidate transaction")
}
Test("tap_hold_writer: _TH_WriteTapHoldDisabled uses durable atomic replacement (loader-toml-injection-readfile-hotpath)", _LTI_WriteTapHoldDisabledIsAtomic)




; ==================================================
; ==================================================
; ======= 3/ Truncated-read warning guard ==========
; ==================================================
; ==================================================

_LTI_LoaderWarnsOnTruncatedConfig() {
	Src := _LTI_ReadSource("platform/remap/tap_hold_loader.ahk")
	Seg := _LTI_FuncBody(Src, "LoadTapHoldToml(FilePath, DefaultsFilePath := " . Chr(34) . Chr(34) . ") {")
	Assert(Seg != "", "LoadTapHoldToml declaration must exist in tap_hold_loader.ahk")
	; The sentinel fires only when the parsed config has 0 keys and the user did
	; not explicitly opt out (InheritDefaults still true). Both conditions plus a
	; warning emission must be present so a truncated write is surfaced loudly.
	Assert(InStr(Seg, "Result[" . Chr(34) . "keys" . Chr(34) . "].Count == 0") > 0,
		"LoadTapHoldToml must detect an empty merged config (0 keys) to flag a truncated write")
	Assert(InStr(Seg, "InheritDefaults") > 0,
		"LoadTapHoldToml truncated-write guard must exempt the explicit inherit_defaults=false opt-out via InheritDefaults")
	Assert(InStr(Seg, "LoggerWarn") > 0,
		"LoadTapHoldToml must LoggerWarn on a 0-key config without inherit_defaults=false so a truncated/corrupt write is not silently masked as 'no config'")
}
Test("tap_hold_loader: LoadTapHoldToml warns on truncated/empty config (loader-toml-injection-readfile-hotpath)", _LTI_LoaderWarnsOnTruncatedConfig)
