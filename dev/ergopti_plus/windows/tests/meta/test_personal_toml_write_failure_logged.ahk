; tests/meta/test_personal_toml_write_failure_logged.ahk

; ==============================================================================
; MODULE: Personal TOML Write Failure Logging Guard
; DESCRIPTION:
; Guards that WritePersonalToml and WritePersonalInfoToml emit a LoggerError
; when FileOpen fails (disk full, locked by AV, ACL-restricted path). Before
; the fix, both functions returned False with no log at all, and three of the
; four native editor call sites ignored the return — silently losing user edits.
; ==============================================================================

#Requires AutoHotkey v2.0


_MetaCheckPersonalTomlWriteFailureLogged() {
	Body := _DriverFuncBody("WritePersonalToml")
	Assert(Body != "", "WritePersonalToml(Data) must exist in personal_toml_io.ahk")

	; The FileOpen failure branch must call LoggerError.
	FileOpenPos := InStr(Body, "FileOpen(")
	Assert(FileOpenPos > 0, "WritePersonalToml must call FileOpen")
	; Search for LoggerError within 300 chars after the FileOpen.
	After := SubStr(Body, FileOpenPos, 300)
	Assert(InStr(After, "LoggerError") > 0,
		"WritePersonalToml must call LoggerError when FileOpen fails")

	; WritePersonalInfoToml must also log.
	InfoBody := _DriverFuncBody("WritePersonalInfoToml")
	Assert(InfoBody != "", "WritePersonalInfoToml(FilePath) must exist in personal_toml_io.ahk")
	InfoFileOpenPos := InStr(InfoBody, "FileOpen(")
	Assert(InfoFileOpenPos > 0, "WritePersonalInfoToml must call FileOpen")
	AfterInfo := SubStr(InfoBody, InfoFileOpenPos, 300)
	Assert(InStr(AfterInfo, "LoggerError") > 0,
		"WritePersonalInfoToml must call LoggerError when FileOpen fails")
}

Test("meta personal TOML: WritePersonalToml + WritePersonalInfoToml log on FileOpen failure",
	_MetaCheckPersonalTomlWriteFailureLogged)
