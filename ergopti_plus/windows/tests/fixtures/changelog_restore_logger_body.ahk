; tests/fixtures/changelog_restore_logger_body.ahk

_CRAWL_Error(Err, Mode) {
	FileAppend("RESTORED_LOGGER_ERROR " . Err.Message . "`n" . Err.Stack . "`n", "*")
	ExitApp(1)
}
OnError(_CRAWL_Error)
try {
	if A_Args.Length != 1
		throw Error("The isolated restored logger needs one exact expected level.")
	if ConfigMigrateBoot(ConfigurationFile, "known")
		throw Error("The cold logger cannot borrow an admitted parent constructor.")
	LoggerInit()
	FileAppend("RESTORED_LOGGER_LEVEL=" . LOGGER_MIN_LEVEL . "`n", "*")
	if LOGGER_MIN_LEVEL != A_Args[1]
		throw Error("The genuine LOGGER_MIN_LEVEL differs from the selected backup.")
	ExitApp(0)
} catch as _CRAWL_StartupFailure {
	_CRAWL_Error(_CRAWL_StartupFailure, "")
}
