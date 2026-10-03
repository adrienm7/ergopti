; infra/startup_smoke.ahk

; ==============================================================================
; MODULE: Native Startup Readiness Receipt
; DESCRIPTION:
; Binds an isolated startup probe to the process that reached real input/menu
; readiness. Extraction alone cannot prove that the driver finished booting.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../adapters/system_control.ahk
#Include ../adapters/file_system.ahk
#Include tick_count.ahk

; Publish a fresh durable receipt only after the complete startup contract holds.
; @param Directory {String} Exclusive probe directory owned by the parent.
; @param Nonce {String} Parent-generated 128-bit lowercase hexadecimal nonce.
; @param LogsFlushed {Boolean} Successful durable logger preflight receipt.
; @return {String} Path of the newly created process-bound JSON receipt.
StartupSmokePublishReady(Directory, Nonce, LogsFlushed) {
	global _DriverReady, _DriverMenuReady, _DriverBootPhase, BUNDLE_COMMIT
	if !RegExMatch(Nonce, "^[0-9a-f]{32}$")
		throw ValueError("Invalid startup smoke nonce.")
	if !_DriverReady or !_DriverMenuReady or _DriverBootPhase != "ready" or !LogsFlushed
		throw Error("Startup readiness is incomplete or its logs are not durable.")
	Pid := SystemControl().OwnPid()
	Executable := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
	Receipt := '{"schema_version":1,"nonce":' . JsonStringLiteral(Nonce)
		. ',"pid":' . Pid . ',"executable":' . JsonStringLiteral(Executable)
		. ',"compiled":' . (A_IsCompiled ? "true" : "false")
		. ',"build_commit":' . JsonStringLiteral(BUNDLE_COMMIT)
		. ',"bundle_identity":' . JsonStringLiteral(_Bundle_BuildMarker())
		. ',"phase":"ready","driver_ready":true,"menu_ready":true,"logs_flushed":true}' . "`n"
	Path := Directory . "\ready.json"
	if !FSWriteCreateDurable(Path, Receipt)
		throw Error("The startup readiness receipt could not be created durably.")
	return Path
}

; A fresh source boot can Reload before readiness, so its parent must acquire
; the successor's native handle before it exits. The nonce keeps acknowledgments
; private to this run; a missing observer remains bounded and fails visibly.
; @return {Boolean} True after the observer owns this process's terminal receipt.
StartupSmokeAwaitObserver(Directory, Nonce, TimeoutMs := 10000, PollMs := 10) {
	if !RegExMatch(Nonce, "^[0-9a-f]{32}$")
		throw ValueError("Invalid startup smoke nonce.")
	StartedAt := A_TickCount
	AckPath := Directory . "\ack.txt"
	while !TickExpired(StartedAt, TimeoutMs) {
		if FileExist(AckPath) {
			if FSReadStrict(AckPath) != Nonce
				throw Error("The startup observer acknowledgment belongs to another run.")
			return true
		}
		Sleep(PollMs)
	}
	throw Error("The startup observer did not acknowledge readiness before the timeout.")
}
