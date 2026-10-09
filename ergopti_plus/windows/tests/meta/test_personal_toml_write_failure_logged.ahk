; tests/meta/test_personal_toml_write_failure_logged.ahk

; ==============================================================================
; MODULE: Personal TOML Write Failure Logging Guard
; DESCRIPTION:
; Guards that WritePersonalToml and WritePersonalInfoToml emit a LoggerError
; when their write path fails (disk full, locked by AV, ACL-restricted path).
; Personal-hotstring writes stage through FSWriteDurable before an atomic replace, so
; this guard follows the production delegation instead of requiring the durable
; target itself to be opened with truncation semantics.
; ==============================================================================

#Requires AutoHotkey v2.0


_MetaCheckPersonalTomlWriteFailureLogged() {
	Body := _DriverFuncBody("WritePersonalToml")
	Assert(Body != "", "WritePersonalToml(Data) must exist in personal_toml_io.ahk")

	AtomicBody := _DriverFuncBody("_PersonalTomlWriteAtomic")
	Assert(AtomicBody != "", "the personal TOML atomic publisher must exist")
	Assert(InStr(Body, "_PersonalTomlWriteAtomic(FilePath, Content") > 0,
		"WritePersonalToml must delegate its terminal write to the guarded atomic publisher")
	Assert(InStr(AtomicBody, "FSWriteDurable(StagePath, Content)") > 0,
		"the atomic publisher must durably write only its same-directory stage")
	Assert(InStr(AtomicBody, "FSAtomicMoveReplace(StagePath, FilePath)") > 0,
		"the complete stage must replace the durable target atomically")
	Assert(InStr(AtomicBody, "LoggerError") > 0,
		"staging and replace failures must be logged instead of becoming silent false returns")

	; personal_info.toml must use the same stage+replace path. Requiring the old
	; direct FileOpen("w") here pinned the truncation bug as a test invariant:
	; a partial write could destroy the durable target before the catch logged it.
	InfoBody := _DriverFuncBody("WritePersonalInfoToml")
	Assert(InfoBody != "", "WritePersonalInfoToml(FilePath) must exist in personal_toml_io.ahk")
	Assert(InStr(InfoBody, "_PersonalTomlWriteAtomic(FilePath, Content") > 0,
		"WritePersonalInfoToml must stage complete bytes and atomically replace the durable target")
	Assert(InStr(InfoBody, '_PersonalTomlAuthorizeOwnedWrite.Bind(') > 0,
		"the personal-info replace must revalidate its exact logical owner after the yielded stage")
	Assert(InStr(InfoBody, "FileOpen(") == 0,
		"WritePersonalInfoToml must never open the durable target with truncation semantics")
}

Test("personal-toml-write-failure: both writers log their terminal write failure",
	_MetaCheckPersonalTomlWriteFailureLogged)
