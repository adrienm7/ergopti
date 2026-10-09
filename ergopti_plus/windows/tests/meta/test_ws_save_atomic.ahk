; tests/meta/test_ws_save_atomic.ahk

; ==============================================================================
; MODULE: _WS_Save Atomic Write Guard
; DESCRIPTION:
; Static source guard for the _WS_Save atomic write fix in
; infra/wrap_symbols_config.ahk.
;
; ROOT CAUSE ENCODED:
; The original _WS_Save wrote directly to the config file, leaving a window
; where a crash or power loss mid-write would produce a truncated or corrupt
; TOML file. The fix stages the write to a sibling .tmp file and then renames
; it over the target using the write-through atomic filesystem adapter. The
; replacement is atomic on all supported Windows file systems, so either the full new config is
; visible or the old config is untouched — there is no partial-write state.
; ==============================================================================

#Requires AutoHotkey v2.0

_TWSA_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TWSA_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}





; =====================================================================
; =====================================================================
; ======= 1/ _WS_Save writes via durable stage + atomic replace =======
; =====================================================================
; =====================================================================

_TWSA_AtomicWrite() {
	Src := _TWSA_StripLineComments(_TWSA_ReadSource("infra/wrap_symbols_config.ahk"))
	Assert(Src != "", "infra/wrap_symbols_config.ahk must be readable")

	Body := _DriverFuncBody("_WS_Save")
	Assert(Body != "", "_WS_Save must be defined in infra/wrap_symbols_config.ahk")

	; Must use a .tmp staging file
	Assert(InStr(Body, ".tmp") > 0,
		"_WS_Save must stage the write to a .tmp file before moving it over the target (atomic write)")

	WritePos := InStr(Body, "FSWriteDurable(StagePath, Content)")
	AuthorizePos := InStr(Body,
		"_WS_AuthorizeCommit(OwnerToken, BoundPath, StartEpoch)")
	ReplacePos := InStr(Body, "FSAtomicMoveReplace(StagePath, BoundPath)")
	Assert(WritePos > 0 && AuthorizePos > WritePos && ReplacePos > AuthorizePos,
		"_WS_Save must durably stage, revalidate the exact owner, then publish through the atomic adapter")
	Assert(InStr(Body, "FileMove(") == 0,
		"_WS_Save must not bypass the write-through atomic adapter")

	; Direct overwrite of the config path without staging must not be the pattern
	; (we check that FileDelete of the main path is not used as the write strategy)
	Assert(InStr(Body, "FileDelete(_WS_Config_Path)") = 0,
		"_WS_Save must NOT delete the config before writing — that is non-atomic and risks data loss")
}
Test("wrap_symbols_config: _WS_Save uses durable staging + atomic replace", _TWSA_AtomicWrite)
