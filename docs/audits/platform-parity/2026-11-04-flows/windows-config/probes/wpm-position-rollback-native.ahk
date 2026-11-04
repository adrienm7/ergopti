; UNEXECUTED isolated native probe; no Registry or installed config access.
; Owner body below is verbatim production source. Store is a recording port.
#Requires AutoHotkey v2.0
class WPMWidget {
    static pos_x := 10
    static pos_y := 20
}
class WPMWidgetConst {
    static STORE_X := "x"
    static STORE_Y := "y"
}
global ProbeDisk := Map("x", 10, "y", 20), ProbeCalls := [], ProbeFailures := 0
ProbeStore(Key, Value) {
    global ProbeDisk, ProbeCalls
    ProbeCalls.Push([Key, Value])
    if ProbeCalls.Length != 1
        return false
    ProbeDisk[Key] := Value
    return true
}
global ProbeNested := false
ProbeNestedStore(Key, Value) {
    global ProbeDisk, ProbeNested
    ProbeDisk[Key] := Value
    if !ProbeNested {
        ProbeNested := true
        if !_WPMWidget_StorePosition(300, 400, ProbeNestedStore)
            throw Error("Nested position was unexpectedly refused")
    }
    return true
}
_WPMWidget_StoreSet(*) => false
ConfigReportPersistenceFailure(Context, NotifyFn := 0, Detail := "", StateUnchanged := true) {
    global ProbeFailures
    ProbeFailures += 1
    return false
}
_WPMWidget_StorePosition(TargetX, TargetY, StoreFn := 0, NotifyFn := 0) {
	Store := HasMethod(StoreFn, "Call") ? StoreFn : _WPMWidget_StoreSet
	PreviousX := WPMWidget.pos_x
	PreviousY := WPMWidget.pos_y
	Stored := false
	try Stored := (Store.Call(WPMWidgetConst.STORE_X, TargetX) == true)
		&& (Store.Call(WPMWidgetConst.STORE_Y, TargetY) == true)
	if !Stored {
		try Store.Call(WPMWidgetConst.STORE_X, PreviousX)
		try Store.Call(WPMWidgetConst.STORE_Y, PreviousY)
		return ConfigReportPersistenceFailure("widget position", NotifyFn,
			"the position store refused the write")
	}
	WPMWidget.pos_x := TargetX
	WPMWidget.pos_y := TargetY
	return true
}

Result := _WPMWidget_StorePosition(100, 200, ProbeStore)
if Result || ProbeDisk["x"] != 100 || ProbeDisk["y"] != 20
    throw Error("Audited failed-compensation posture changed")
if WPMWidget.pos_x != 10 || WPMWidget.pos_y != 20 || ProbeFailures != 1 || ProbeCalls.Length != 4
    throw Error("The actual owner must keep RAM old and report its primary failure")
FileAppend("OBSERVED false result; RAM=(10,20); durable=(100,20); rollback receipts ignored`n", "*")
ProbeDisk := Map("x", 10, "y", 20)
WPMWidget.pos_x := 10, WPMWidget.pos_y := 20
if !_WPMWidget_StorePosition(100, 200, ProbeNestedStore)
    throw Error("Outer position was unexpectedly refused")
if WPMWidget.pos_x != 100 || WPMWidget.pos_y != 200 || ProbeDisk["x"] != 300 || ProbeDisk["y"] != 200
    throw Error("Audited reentrant mixed-coordinate posture changed")
FileAppend("OBSERVED both writes succeed; RAM=(100,200); durable=(300,200); nested position interleaves`n", "*")
ExitApp()
