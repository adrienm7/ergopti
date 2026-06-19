; tests/meta/test_api_entries_persist_error_logged.ahk

; ==============================================================================
; MODULE: API Entries Persistence Error Logging Meta Test
; DESCRIPTION:
; Regression guard ensuring _LLM_Tray_PersistApiEntries logs write failures
; instead of swallowing them silently.
;
; The bug: the write block used a bare `try {}` with no catch handler.  A real
; disk-full, permission, or path error would be silently ignored — the caller
; received no indication that the API entry (and the user's encrypted token)
; was not actually saved.  On the next restart the entry would be gone with no
; error in the logs.
;
; The fix: add a catch block that calls LoggerError so failures are visible in
; the log file and the user can diagnose a lost entry.
;
; SCOPE: source introspection of ui/tray_llm/menu_api_entries.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ Source scan helpers ==================
; =================================================
; =================================================

_APEL_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}

_APEL_FuncBody(Src, FnDecl) {
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

_APEL_CheckCatchBlockExists() {
	Src := _APEL_ReadSource("ui/tray_llm/menu_api_entries.ahk")
	Assert(Src != "", "ui/tray_llm/menu_api_entries.ahk must be readable")

	Body := _APEL_FuncBody(Src, "_LLM_Tray_PersistApiEntries() {")
	Assert(Body != "", "_LLM_Tray_PersistApiEntries must be present in menu_api_entries.ahk")

	; Must have a catch block in the write section
	Assert(InStr(Body, "catch"),
		"_LLM_Tray_PersistApiEntries must have a catch block on the write try — bare try silently drops disk errors")
}

_APEL_CheckCatchLogsError() {
	Src := _APEL_ReadSource("ui/tray_llm/menu_api_entries.ahk")
	Assert(Src != "", "ui/tray_llm/menu_api_entries.ahk must be readable")

	Body := _APEL_FuncBody(Src, "_LLM_Tray_PersistApiEntries() {")
	Assert(Body != "", "_LLM_Tray_PersistApiEntries must be present in menu_api_entries.ahk")

	; The catch must log an error so the failure is diagnosable
	Assert(InStr(Body, "LoggerError"),
		"_LLM_Tray_PersistApiEntries catch block must call LoggerError to surface write failures")
}


Test("meta api-persist-error: _LLM_Tray_PersistApiEntries has a catch block on the write try",
	_APEL_CheckCatchBlockExists)

Test("meta api-persist-error: catch block calls LoggerError to make write failures diagnosable",
	_APEL_CheckCatchLogsError)
