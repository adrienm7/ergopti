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

; Both startup receipts report one native runtime identity snapshot. This flag
; chooses the launched image; installed-build product policy stays in its owner.
; @returns {Object} Current PID, executable path and compiled runtime flag.
_StartupSmokeRuntimeIdentity() {
	Compiled := A_IsCompiled
	return {pid: SystemControl().OwnPid(),
		executable: Compiled ? A_ScriptFullPath : A_AhkPath, compiled: Compiled}
}

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
	Identity := _StartupSmokeRuntimeIdentity()
	Pid := Identity.pid
	Executable := Identity.executable
	Receipt := '{"schema_version":1,"nonce":' . JsonStringLiteral(Nonce)
		. ',"pid":' . Pid . ',"executable":' . JsonStringLiteral(Executable)
		. ',"compiled":' . (Identity.compiled ? "true" : "false")
		. ',"build_commit":' . JsonStringLiteral(BUNDLE_COMMIT)
		. ',"bundle_identity":' . JsonStringLiteral(_Bundle_BuildMarker())
		. ',"phase":"ready","driver_ready":true,"menu_ready":true,"logs_flushed":true}' . "`n"
	Path := Directory . "\ready.json"
	if !FSWriteCreateDurable(Path, Receipt)
		throw Error("The startup readiness receipt could not be created durably.")
	return Path
}

; A compiled probe has no source wrapper. Acknowledge only the boot's already
; accepted full-save generation through the production collector/WAL owner.
; @param Directory {String} Exclusive directory owned by the startup observer.
; @param Nonce {String} Parent-generated lowercase hexadecimal nonce.
; @return {String} Fresh durable generation receipt bound to the actual process.
StartupSmokePublishFullSave(Directory, Nonce) {
	global CONFIG_SAVE_OK, BUNDLE_COMMIT
	global _DriverReady, _DriverMenuReady, _DriverBootPhase
	if !RegExMatch(Nonce, "^[0-9a-f]{32}$")
		throw ValueError("Invalid startup smoke nonce.")
	if !_DriverReady || !_DriverMenuReady || _DriverBootPhase != "ready"
		throw Error("The startup full save requires complete driver readiness.")
	State := _ConfigFullSaveCoordinator()
	PreviousCritical := Critical("On")
	try {
		RequestedBefore := State.requested_generation
		CommittedBefore := State.committed_generation
	} finally Critical(PreviousCritical)
	if !(RequestedBefore is Integer) || RequestedBefore <= 0
		throw Error("The startup probe has no accepted boot full-save generation.")
	Result := CONFIG_SAVE_OK
	if RequestedBefore > CommittedBefore
		Result := _ConfigDrainFullSave()
	PreviousCritical := Critical("On")
	try {
		Requested := State.requested_generation
		Committed := State.committed_generation
		Settled := State.settled_generation
		Pending := _ConfigFullSaveHasPending()
	} finally Critical(PreviousCritical)
	if !(Result is Integer) || Result != CONFIG_SAVE_OK
		throw Error("The startup full save did not acknowledge its existing boot generation.")
	if !(Requested is Integer) || Requested < RequestedBefore
			|| !(Committed is Integer) || Committed < Requested
			|| !(Settled is Integer) || Settled < Requested || Pending
		throw Error("The startup boot full-save generation is not committed.")
	Identity := _StartupSmokeRuntimeIdentity()
	Pid := Identity.pid
	Executable := Identity.executable
	Receipt := '{"schema_version":1,"nonce":' . JsonStringLiteral(Nonce)
		. ',"pid":' . Pid . ',"executable":' . JsonStringLiteral(Executable)
		. ',"compiled":' . (Identity.compiled ? "true" : "false")
		. ',"build_commit":' . JsonStringLiteral(BUNDLE_COMMIT)
		. ',"bundle_identity":' . JsonStringLiteral(_Bundle_BuildMarker())
		. ',"requested":' . Requested . ',"committed":' . Committed
		. ',"settled":' . Settled . ',"pending":false}' . "`n"
	Path := Directory . "\full-save.json"
	if !FSWriteCreateDurable(Path, Receipt)
		throw Error("The startup full-save receipt could not be created durably.")
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
