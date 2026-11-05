; tests/meta/modules/hotstrings/personal/test_personal_toml_write_failure_logged.ahk

; ==============================================================================
; MODULE: Personal TOML Write Failure Logging Guard
; DESCRIPTION:
; Guards that WritePersonalToml and WritePersonalInfoToml emit a LoggerError
; when their write path fails (disk full, locked by AV, ACL-restricted path).
; Personal-hotstring native writes use a held FILE_CREATE stage before atomic rename, so
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
	Assert(InStr(AtomicBody, "FSWriteReplaceOwned(PhysicalPath, Content") > 0,
		"the native publisher must retain creation-time stage custody through atomic replacement")
	Assert(InStr(AtomicBody, "_PersonalTomlCreateHeldStage.Bind(Stage)") > 0,
		"the actual FILE_CREATE factory must issue the stage handle used by the publisher")
	Preflight := _DriverFuncBody("_PersonalTomlHeldPreflight")
	Assert(InStr(Preflight, "_FSReadUtf8ExactHandle(Stage.handle") > 0,
		"the complete held stage must be read back before its native atomic rename")
	Assert(InStr(AtomicBody, "Publication.renamed && !Publication.durable") > 0,
		"a replaced target without complete durable ACK must retain truthful partial feedback")
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
