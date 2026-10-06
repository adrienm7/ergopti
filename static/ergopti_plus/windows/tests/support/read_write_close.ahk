; tests/support/read_write_close.ahk

#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn VarUnset, Off
#Include infra/file_read_activity.ahk
#Include adapters/file_system.ahk
#Include infra/config_write_lease.ahk
global _FRC_Handle := -1
_FRC_RefuseClose(Handle) {
	global _FRC_Handle
	_FRC_Handle := Handle
	if A_Args[1] == "throw"
		throw Error("Injected native close exception.")
	return false
}
_FRC_Check(Condition, Message) {
	if !Condition
		throw Error(Message)
}
_FRC_Main() {
	global _FRC_Handle
	Path := A_ScriptDir . "\held-reader.txt"
	FileAppend("retained é", Path, "UTF-8-RAW")
	try {
		Result := FSReadUtf8Exact(Path)
		_FRC_Check(FSHandleSnapshot(_FRC_Handle).Get("ok", false), "The exact real handle remains live after refused close.")
		_FRC_Check((Result is Integer) && Result == false, "A failed native close cannot report a successful exact read.")
		_FRC_Check(FileReadActivityBusy(Path), "Unacknowledged native close retains the read activity.")
		Attempt := _ConfigWriteLeaseTryAcquire(Path)
		if Attempt is Object
			_ConfigWriteLeaseRelease(Attempt)
		_FRC_Check(!(Attempt is Object), "A writer cannot enter over the retained native reader.")
		Rows := _FileReadActivityState().owners
		_FRC_Check(Rows.Count == 1, "The one refused reader must retain exactly one owner.")
		for Row in Rows {
			Record := Rows[Row]
			_FRC_Check(Record.handle == _FRC_Handle, "The debt retains its exact native handle.")
		}
		FileAppend("PASS real-handle-retained read-false writer-denied mode=" . A_Args[1] . Chr(10), A_ScriptDir . "\native-results.log", "UTF-8")
	} finally {
		if _FRC_Handle != -1 {
			OwnedToken := 0
			for Id, Row in _FileReadActivityState().owners {
				if Row.handle != _FRC_Handle || Row.path != Path
					continue
				_FRC_Check(!(OwnedToken is Object), "The fixture handle must have exactly one owning token.")
				OwnedToken := Row.token
			}
			Closed := DllCall("kernel32\CloseHandle", "Ptr", _FRC_Handle, "Int")
			_FRC_Check(Closed, "Fixture retirement needs its own actual native close acknowledgement.")
			_FRC_Handle := -1
			if OwnedToken is Object
				_FRC_Check(FileReadActivityLeave(OwnedToken), "Only the exactly closed fixture reader may retire.")
		}
	}
	_FRC_Check(!FileReadActivityBusy(Path), "The actual acknowledged close releases only the fixture debt.")
	Writer := _ConfigWriteLeaseTryAcquire(Path)
	_FRC_Check(Writer is Object, "Independent writer admission resumes after acknowledged retirement.")
	_ConfigWriteLeaseRelease(Writer)
	FileAppend("PASS actual-close-ack-writer-admitted" . Chr(10), A_ScriptDir . "\native-results.log", "UTF-8")
}
try {
	_FRC_Main()
	ExitApp(0)
} catch as Err {
	FileAppend("FAIL " . Err.Message . Chr(10), A_ScriptDir . "\native-results.log", "UTF-8")
	ExitApp(1)
}
