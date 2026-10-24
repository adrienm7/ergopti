; tests/fixtures/user_hotstring_loader_lifetime_body.ahk

; ==============================================================================
; MODULE: Programmable Loader Lifetime Component
; DESCRIPTION:
; Real public metadata reloads own a native worker behind a private factory gate.
; Native task and stage retirement precede passive object-lifetime observations.
; No callback delivery, input injection or garbage collection is synthesized.
; ==============================================================================

#Requires AutoHotkey v2.0

_UHLC_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_UHLC_BootError(Failure, Mode) {
	FileAppend("BOOT_EXCEPTION loader-lifetime type=" . JsonStringLiteral(Type(Failure))
		. " message=" . JsonStringLiteral(Failure.Message) . " file=" . JsonStringLiteral(Failure.File)
		. " line=" . Failure.Line . " mode=" . JsonStringLiteral(Mode) . "`n", "*", "UTF-8")
	return false
}

_UHLC_Failure(Failure) {
	global _UHLC
	if !IsObject(_UHLC.Failure)
		_UHLC.Failure := Failure
}

_UHLC_OnError(Failure, Mode) {
	_UHLC_Failure(Failure)
	return true
}

_UHLC_Log(Line) {
	global _UHLC
	if InStr(Line, "[ERROR]", true) || InStr(Line, "[WARNING]", true)
		_UHLC.Errors.Push(Line)
}

_UHLC_Healthy() {
	global _UHLC
	if IsObject(_UHLC.Failure)
		throw _UHLC.Failure
	_UHLC_Require(_UHLC.Errors.Length == 0, "A genuine logger error or warning prevents lifetime qualification.")
}

class _UHLC_Marker {
	__New(Observer, Kind) {
		this.Observer := Observer, this.Kind := Kind
	}
	__Delete() {
		if this.Kind == "disposable"
			this.Observer.DisposableDeleted += 1
		else
			this.Observer.WorkerDeleted += 1
	}
}

_UHLC_Disposable(Observer) {
	Marker := _UHLC_Marker(Observer, "disposable")
}

_UHLC_Quote(Text) {
	return Chr(34) . StrReplace(StrReplace(Text, Chr(96), Chr(96) . Chr(96)), Chr(34), Chr(96) . Chr(34)) . Chr(34)
}

_UHLC_Factory() {
	global _UHLC
	return Chr(0xFEFF) . "ErgoptiDynamicHotstrings(api) {`n"
		. "`tGate := " . _UHLC_Quote(_UHLC.Gate) . ", Ready := " . _UHLC_Quote(_UHLC.Ready) . "`n"
		. '`tFileAppend("factory-entered", Ready, "UTF-8-RAW")' . "`n"
		. "`tStarted := A_TickCount`n`twhile !FileExist(Gate) {`n"
		. '`t`tif A_TickCount - Started >= 5000`n`t`t`tthrow Error("Private metadata gate was not released.")' . "`n"
		. "`t`tSleep(10)`n`t}`n"
		. '`treturn [Map("id", "probe", "suffix", "@probe", "preview", "été 世界", "callback", (ctx) => false)]' . "`n}`n"
}

_UHLC_Run(Observer, Retain) {
	global _UHLC, _UserHotstringsLoader, _UserHotstringsJobs, _UserHotstringsOwner, _UserHotstringsLoadEpoch
	_UHLC.Stage := "public-reload"
	Admitted := UserHotstringsReload()
	Worker := _UserHotstringsLoader
	if IsObject(Worker)
		_UHLC.CleanupWorker := Worker
	_UHLC_Require(Admitted && Worker is UserHotstringWorker, "The real public reload must admit its native loader.")
	_UHLC_Require(Worker.mode == "load" && !IsObject(Worker.context) && _UserHotstringsOwner.active.Count == 0,
		"Metadata loading must exclude execution tickets and user callbacks.")
	Worker.LifetimeMarker := _UHLC_Marker(Observer, "worker")
	ExpectedEpoch := _UserHotstringsLoadEpoch
	_UHLC.Stage := "waiting-for-native-factory"
	Started := A_TickCount
	while (!IsObject(Worker.task) || !FSStrictExists(_UHLC.Ready)) && TickElapsed64(Started) < 5000 {
		_UHLC_Healthy()
		Sleep(10)
	}
	_UHLC_Healthy()
	_UHLC_Require(IsObject(Worker.task) && FSStrictExists(_UHLC.Ready), "The actual gated native factory must enter before capture.")
	Task := Worker.task, _UHLC.CleanupTask := Task
	Observer.Pid := Task.processId()
	Snapshot := Worker.source.Clone()
	_UHLC_Require(Observer.Pid > 0 && _UserHotstringsLoader == Worker && _UserHotstringsJobs.Has(Worker)
		&& !_UserHotstringsOwner.ready && Snapshot["present"] && Snapshot["path"] == UserHotstringsSourcePath()
		&& Snapshot["content"] == _UHLC.Source, "The gated task must own the exact real source snapshot and live admission.")
	_UHLC_Require(FSReadUtf8Exact(_UHLC.Ready) == "factory-entered" && !FSStrictExists(_UHLC.Gate),
		"Only the genuine factory may publish its private entry before release.")
	_UHLC.StageDirectory := Worker.stage
	_UHLC_Require(DirExist(_UHLC.StageDirectory)
		&& FSReadUtf8Exact(_UHLC.StageDirectory . "\source.ahk") == _UHLC.Source,
		"The actual worker must stage the byte-faithful private source.")
	_UHLC_Require(Observer.WorkerDeleted == 0, "An actually active loader must retain its marker.")
	Observer.FactoryEntered := 1, Observer.ActiveRetained := 1
	_UHLC.Stage := "release-native-factory"
	_UHLC_Require(UserCodeAcknowledged(FSWriteCreateDurable(_UHLC.Gate, "release"))
		&& FSReadUtf8Exact(_UHLC.Gate) == "release", "The private filesystem gate must genuinely commit release.")
	Observer.GateReleased := 1
	Started := A_TickCount
	while (IsObject(_UserHotstringsLoader) || !_UserHotstringsOwner.ready || _UserHotstringsJobs.Has(Worker))
		&& TickElapsed64(Started) < 10000 {
		_UHLC_Healthy()
		Sleep(10)
	}
	_UHLC_Healthy()
	_UHLC_Require(!IsObject(_UserHotstringsLoader) && _UserHotstringsOwner.ready && !_UserHotstringsJobs.Has(Worker)
		&& ExpectedEpoch == _UserHotstringsLoadEpoch, "The genuine metadata completion must retire its public loader and exact job.")
	_UHLC.Stage := "native-task-ack"
	Ack := Task.terminate()
	_UHLC_Require(Ack is Integer && Ack == 1, "The captured exact native Task must acknowledge complete tree retirement.")
	Observer.TaskAck := Ack, _UHLC.CompletedTaskAck := Ack
	_UHLC_Require(!DirExist(_UHLC.StageDirectory), "Actual Cleanup must remove the native worker stage.")
	Rules := _UserHotstringsOwner.Rules()
	_UHLC_Require(UserHotstringsCount() == 1 && Rules.Length == 1 && Rules[1]["id"] == "probe"
		&& Rules[1]["suffix"] == "@probe" && Rules[1]["preview"] == "été 世界",
		"The actual worker frame must publish its independently specified Unicode metadata.")
	_UHLC_Require(FSReadUtf8Exact(UserHotstringsSourcePath()) == _UHLC.Source, "Public loading must preserve exact source bytes.")
	Observer.MetadataCount := 1, Observer.SourceUnchanged := 1, Observer.LoaderDropped := 1
	Observer.JobRemoved := 1, Observer.StageGone := 1
	; These are test cleanup capabilities, not observer fields. Release A before
	; returning; the retained control alone deliberately returns the real Worker.
	_UHLC.CleanupTask := 0, _UHLC.CleanupWorker := 0
	return Retain ? Worker : 0
}

_UHLC_Pulse() {
	global _UHLC
	_UHLC.NativeTurns += 1
}

_UHLC_Turn() {
	global _UHLC
	SetTimer(_UHLC_Pulse, -1)
	Started := A_TickCount
	while _UHLC.NativeTurns == 0 && TickElapsed64(Started) < 1000
		Sleep(10)
	_UHLC_Require(_UHLC.NativeTurns == 1, "A real native timer turn must return to original Main.")
}

_UHLC_Receipt(Observer) {
	global _UHLC
	FileAppend("RECEIPT loader-lifetime mode=" . _UHLC.Mode . " stage=" . _UHLC.Stage
		. " disposable_deleted=" . Observer.DisposableDeleted . " worker_deleted=" . Observer.WorkerDeleted
		. " pid=" . Observer.Pid . " task_ack=" . Observer.TaskAck . " factory_entered=" . Observer.FactoryEntered
		. " gate_released=" . Observer.GateReleased . " active_retained=" . Observer.ActiveRetained
		. " metadata_count=" . Observer.MetadataCount . " source_unchanged=" . Observer.SourceUnchanged
		. " loader_dropped=" . Observer.LoaderDropped . " job_removed=" . Observer.JobRemoved . " stage_gone=" . Observer.StageGone
		. " helper_returned=" . _UHLC.HelperReturned . " returned_turns=" . _UHLC.NativeTurns
		. " logger_errors=" . _UHLC.Errors.Length . " failure=" . IsObject(_UHLC.Failure) . "`n", "*", "UTF-8")
}

_UHLC_Cleanup() {
	global _UHLC, _UserHotstringsLoader, _UserHotstringsJobs, _UserHotstringsOwner
	SetTimer(_UHLC_Pulse, 0)
	Worker := _UHLC.CleanupWorker, Task := _UHLC.CleanupTask
	if !IsObject(Worker) && IsObject(_UserHotstringsLoader)
		Worker := _UserHotstringsLoader
	if !IsObject(Task) && IsObject(Worker) && Worker.HasProp("task") && IsObject(Worker.task)
		Task := Worker.task
	try {
		if IsObject(Worker) && _UserHotstringsJobs.Has(Worker)
			_UHLC_Require(UserCodeAcknowledged(Worker.cancel()), "Exact native worker cancellation must acknowledge cleanup.")
	} catch Any as Failure {
		_UHLC_Failure(Failure)
	}
	try {
		Ack := IsObject(Task) ? Task.terminate() : 1
		_UHLC_Require(Ack is Integer && Ack == 1, "Native task cleanup acknowledgement must be independent of other failures.")
		_UHLC_Require(!IsObject(Worker) || !_UserHotstringsJobs.Has(Worker), "No actual worker job may remain owned after cleanup.")
		_UHLC_Require(_UHLC.StageDirectory == "" || !DirExist(_UHLC.StageDirectory), "No private staged source may remain after cleanup.")
		_UHLC.CleanupTask := 0, _UHLC.CleanupWorker := 0
		_UHLC.CleanupAck := IsObject(Task) ? Ack : _UHLC.CompletedTaskAck
		_UHLC.CleanupAckMode := IsObject(Task) ? "exact-task" : _UHLC.CompletedTaskAck ? "prior-exact-task" : "no-task"
	} catch Any as Failure {
		_UHLC_Failure(Failure)
	}
	try _UHLC_Require(UserHotstringsStop(), "The real programmable owner must stop without native debt.")
	catch Any as Failure
		_UHLC_Failure(Failure)
	try {
		_UHLC_Require(LoggerPrepareShutdown() == true, "The true private logger must flush before exit.")
		SetTimer(_LoggerFlush, 0)
		OnExit(_LoggerOnExitFlush, 0)
	} catch Any as Failure {
		_UHLC_Failure(Failure)
	}
	FileAppend("CLEANUP loader-lifetime task_ack=" . _UHLC.CleanupAck . " ack_mode=" . _UHLC.CleanupAckMode . " jobs=" . _UserHotstringsJobs.Count
		. " errors=" . IsObject(_UHLC.Failure) . "`n", "*", "UTF-8")
}

_UHLC_Main() {
	global _UHLC, _UHLC_Root, Features, ConfigurationFile, _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsJobs
	if A_Args.Length != 2 || A_Args[2] != _UHLC_Root
		ExitApp(2)
	Persistent(true)
	_UHLC := {Mode: A_Args[1], Stage: "init", Failure: 0, Errors: [], CleanupWorker: 0, CleanupTask: 0,
		CleanupAck: 0, CompletedTaskAck: 0, CleanupAckMode: "none", StageDirectory: "", Source: "", Ready: _UHLC_Root . "\factory-entered",
		Gate: _UHLC_Root . "\factory-release", HelperReturned: 0, NativeTurns: 0}
	Observer := {DisposableDeleted: 0, WorkerDeleted: 0, Pid: 0, TaskAck: 0, FactoryEntered: 0, GateReleased: 0,
		ActiveRetained: 0, MetadataCount: 0, SourceUnchanged: 0, LoaderDropped: 0, JobRemoved: 0, StageGone: 0}
	Primary := 0, Retainer := 0, Observed := false, PreviousCritical := Critical("Off"), PreviousSuspend := A_IsSuspended
	Thread("Interrupt", 0), Suspend(false)
	OnError(_UHLC_OnError)
	try {
		_UHLC_Require(_UHLC.Mode == "retained" || _UHLC.Mode == "released", "Unknown loader lifetime mode.")
		_UHLC_Require(!FileExist(ConfigurationFile), "The actual private logger config must be absent before initialization.")
		LoggerInit(), LoggerSetTestSink(_UHLC_Log)
		Features := ManifestBuildFeaturesMap()
		_UHLC_Require(!Features["hotstrings"]["dynamic"]["user_code"]["enabled"]
			&& !IsObject(_UserHotstringsOwner) && !IsObject(_UserHotstringsLoader) && _UserHotstringsJobs.Count == 0,
			"Actual fresh defaults must admit a closed, empty programmable owner.")
		_UHLC_Require(UserHotstringsInit() && !_UserHotstringsOwner.enabled && !_UserHotstringsOwner.ready,
			"Real default-off public initialization must run without executing user code.")
		_UHLC.Source := _UHLC_Factory()
		_UHLC_Require(UserCodeAcknowledged(FSWriteCreateDurable(UserHotstringsSourcePath(), _UHLC.Source)),
			"The explicit private source must be genuinely created before public reload.")
		_UHLC_Disposable(Observer)
		_UHLC_Require(Observer.DisposableDeleted == 1, "An ordinary acyclic marker must receive its real destructor after helper return.")
		Retainer := _UHLC_Run(Observer, _UHLC.Mode == "retained")
		_UHLC.HelperReturned := 1, _UHLC.Stage := "original-main-after-helper"
		_UHLC_Turn(), _UHLC_Healthy()
		_UHLC_Require(Observer.DisposableDeleted == 1 && Observer.TaskAck == 1 && Observer.FactoryEntered
			&& Observer.GateReleased && Observer.MetadataCount == 1 && Observer.SourceUnchanged
			&& Observer.LoaderDropped && Observer.JobRemoved && Observer.StageGone && _UHLC.HelperReturned
			&& !IsObject(_UHLC.CleanupTask) && !IsObject(_UHLC.CleanupWorker),
			"All genuine worker, gate, ACK, metadata and returned-frame prerequisites must precede lifetime observation.")
		_UHLC_Require(_UHLC.Mode == "retained" ? IsObject(Retainer) : !IsObject(Retainer),
			"Only the independent retained control may hold the actual completed Worker.")
		_UHLC_Receipt(Observer), Observed := true
		if _UHLC.Mode == "retained"
			_UHLC_Require(Observer.WorkerDeleted == 0, "An explicitly retained native worker must keep its marker alive.")
		else
			_UHLC_Require(Observer.WorkerDeleted == 1,
				"A completed public metadata reload must release its worker after exact task ACK and all completion frames return.")
	} catch Any as Failure {
		Primary := IsObject(_UHLC.Failure) ? _UHLC.Failure : Failure
	} finally {
		if !Observed {
			try _UHLC_Receipt(Observer)
			catch Any as Failure
				_UHLC_Failure(Failure)
		}
		Retainer := 0
		try _UHLC_Cleanup()
		catch Any as Failure
			_UHLC_Failure(Failure)
		LoggerClearTestSink()
		OnError(_UHLC_OnError, 0), OnError(_UHLC_BootError, 0)
		Suspend(PreviousSuspend), Critical(PreviousCritical)
	}
	if !IsObject(Primary) && IsObject(_UHLC.Failure)
		Primary := _UHLC.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS user-hotstring-loader-lifetime " . _UHLC.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_UHLC_Main()
