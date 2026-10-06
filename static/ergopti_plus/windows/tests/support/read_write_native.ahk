; tests/support/read_write_native.ahk

#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, StdOut
#Warn VarUnset, Off
#Include infra/file_read_activity.ahk
#Include adapters/file_system.ahk
#Include infra/config_write_lease.ahk

global _RW_State := 0
global _RW_Pass := 0, _RW_Fail := 0

_RW_Check(Condition, Message) {
	if !Condition
		throw Error(Message)
}
_RW_Writer(State, *) {
	try {
		State.Critical := A_IsCritical
		Token := _ConfigWriteLeaseTryAcquire(State.Target)
		State.Denied := !(Token is Object)
		if Token is Object {
			try State.Moved := FSAtomicMoveReplace(State.Stage, State.Target, &NativeError)
			finally _ConfigWriteLeaseRelease(Token)
			State.NativeError := NativeError
		}
	} catch as Err {
		State.Failure := Err
	} finally State.Done := true
}
_RW_Boundary(ReadPath, Phase, Handle := -1) {
	global _RW_State
	if !(_RW_State is Object) || !(ReadPath == _RW_State.Target) || Phase != _RW_State.Phase || _RW_State.Observed
		return
	State := _RW_State
	State.Observed := true
	if Phase == "held"
		_RW_Check(FSHandleSnapshot(Handle).Get("ok", false), "Actual held reader identity is required.")
	State.Timer := _RW_Writer.Bind(State)
	SetTimer(State.Timer, -1)
	Started := A_TickCount
	while !State.Done {
		if A_TickCount - Started > 2000 {
			SetTimer(State.Timer, 0)
			throw Error("The actual writer timer did not run.")
		}
		Sleep(1)
	}
	if State.Failure is Error
		throw State.Failure
}
_RW_Metadata() {
	A := FileReadActivityEnter("C:\Probe\config.toml")
	B := FileReadActivityEnter("c:/probe/CONFIG.toml")
	try {
		_RW_Check(FileReadActivityBusy("c:/PROBE/config.toml"), "Slash/case read keys agree.")
		Attempt := _ConfigWriteLeaseTryAcquire("C:\Probe\config.toml")
		if Attempt is Object
			_ConfigWriteLeaseRelease(Attempt)
		_RW_Check(!(Attempt is Object), "A same-path writer must defer.")
		Other := _ConfigWriteLeaseTryAcquire("C:\Probe\other.toml")
		_RW_Check(Other is Object, "An independent writer remains admitted.")
		_ConfigWriteLeaseRelease(Other)
		_RW_Check(FileReadActivityLeave(A), "First read releases only itself.")
		_RW_Check(FileReadActivityBusy("C:\Probe\config.toml"), "Second reader still excludes writes.")
		_RW_Check(!FileReadActivityLeave(A) && !FileReadActivityLeave({}), "Stale and forged release cannot clear another reader.")
		_RW_Check(!ConfigWriteLeaseBusy(), "An exact read does not become foreign write authority.")
		_RW_Check(ConfigMutationBusy(), "Mutation commands see the interrupted read as busy.")
	} finally {
		FileReadActivityLeave(A)
		FileReadActivityLeave(B)
	}
	_RW_Check(!FileReadActivityBusy(), "Both exact readers retired.")
}
_RW_Terminal() {
	Path := "C:\Probe\config.toml"
	Bundle := _ConfigWriteTerminalTryAcquire(Path)
	_RW_Check(Bundle is Object, "Dry terminal bundle starts live.")
	try {
		Read := FileReadActivityEnter(Path)
		try {
			_RW_Check(_ConfigWriteLeaseOwns(Bundle.tokens[1], Path), "An exact read does not invalidate existing authority.")
			_RW_Check(!_ConfigWriteTerminalAuthorize(Bundle), "Existing bundle cannot authorize over a reader.")
		} finally FileReadActivityLeave(Read)
		_RW_Check(_ConfigWriteTerminalAuthorize(Bundle), "Authorization retries after read closes.")
		Read := FileReadActivityEnter(Path)
		try _RW_Check(!_ConfigWriteTerminalClaimShutdown(Bundle), "Post-authorization reader debt refuses final claim.")
		finally FileReadActivityLeave(Read)
		_RW_Check(_ConfigWriteTerminalClaimShutdown(Bundle), "Exact shutdown claim retries after close.")
	} finally _ConfigWriteTerminalRelease(Bundle)
}

_RW_Native(Phase) {
	global _RW_State
	Dir := A_ScriptDir . "\data-" . Phase
	DirCreate(Dir)
	Target := Dir . "\config.toml", Stage := Dir . "\stage.tmp"
	Original := "original é", Replacement := "replacement é"
	FileAppend(Original, Target, "UTF-8-RAW")
	FileAppend(Replacement, Stage, "UTF-8-RAW")
	State := {Target: Target, Stage: Stage, Phase: Phase, Observed: false, Done: false,
		Denied: false, Moved: false, NativeError: 0, Critical: -1, Failure: 0}
	_RW_State := State
	try {
		Content := FSReadUtf8Exact(Target)
		_RW_Check(State.Observed && State.Done, "Actual read boundary and timer must both execute.")
		FileAppend("# boundary=" . Phase . " denied=" . State.Denied . " native-error=" . State.NativeError . " writer-critical=" . State.Critical . "" . Chr(10) . "", A_ScriptDir . "\native-results.log", "UTF-8")
		_RW_Check(State.Critical == 0, "No native I/O may run inside Critical.")
		_RW_Check(State.Denied, "The interrupted writer must defer until actual reader close.")
		_RW_Check(Content == Original && FileRead(Target, "UTF-8") == Original, "The original exact bytes stay visible.")
		_RW_Check(!FileReadActivityBusy(Target), "The real native close releases the reader activity.")
		Token := _ConfigWriteLeaseTryAcquire(Target)
		_RW_Check(Token is Object, "Writer admission resumes after native close.")
		try _RW_Check(FSAtomicMoveReplace(Stage, Target, &MoveError) && MoveError == 0, "The actual deferred replacement must succeed.")
		finally _ConfigWriteLeaseRelease(Token)
		_RW_Check(FileRead(Target, "UTF-8") == Replacement, "Independent file read observes the committed replacement.")
	} finally _RW_State := 0
}
_RW_FailedOpen() {
	Path := A_ScriptDir . "\not-created.toml"
	Result := FSReadUtf8Exact(Path)
	_RW_Check((Result is Integer) && Result == false, "A missing file returns the existing false verdict.")
	_RW_Check(!FileReadActivityBusy(Path), "A returned failed open cancels only its own activity.")
}
_RW_Run(Name, Fn) {
	global _RW_Pass, _RW_Fail
	try {
		Fn.Call()
		_RW_Pass += 1
		FileAppend("ok " . (_RW_Pass + _RW_Fail) . " - " . Name . "" . Chr(10) . "", A_ScriptDir . "\native-results.log", "UTF-8")
	} catch as Err {
		_RW_Fail += 1
		FileAppend("not ok " . (_RW_Pass + _RW_Fail) . " - " . Name . " - " . Err.Message . "" . Chr(10) . "", A_ScriptDir . "\native-results.log", "UTF-8")
	}
}
FileAppend("1..5" . Chr(10) . "", A_ScriptDir . "\native-results.log", "UTF-8")
_RW_Run("read-write-alias-nesting-retirement", _RW_Metadata)
_RW_Run("read-write-existing-terminal-bundle", _RW_Terminal)
_RW_Run("read-write-native-opening-preemption", _RW_Native.Bind("opening"))
_RW_Run("read-write-native-held-handle-preemption", _RW_Native.Bind("held"))
_RW_Run("read-write-failed-open-cancels-attempt", _RW_FailedOpen)
FileAppend("# " . _RW_Pass . " passed, " . _RW_Fail . " failed." . Chr(10) . "", A_ScriptDir . "\native-results.log", "UTF-8")
ExitApp(_RW_Fail ? 1 : 0)
