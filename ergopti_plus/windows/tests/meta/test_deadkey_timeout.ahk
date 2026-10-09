; tests/meta/test_deadkey_timeout.ahk

#Requires AutoHotkey v2.0

_TDT_AssertDeadKeyTimeout() {
	; Move-resilient: locate DeadKey() across the whole driver source via the
	; framework helper instead of a pinned modules path
	DeadKeyBody := _DriverFuncBody("DeadKey")
	
	TimeoutIdx := InStr(DeadKeyBody, '"L1 T2"')
	if !TimeoutIdx
		TimeoutIdx := InStr(DeadKeyBody, "'L1 T2'")
	Assert(TimeoutIdx > 0, "DeadKey InputHook must have a timeout (e.g. T2) (deadkey-inputhook-blocks-thread)")
	
	FinallyIdx := InStr(DeadKeyBody, "finally {")
	Assert(FinallyIdx > 0, "DeadKey must use a finally block to reset InDeadKeySequence (deadkey-inputhook-blocks-thread)")
}

Test("layout: DeadKey InputHook has a timeout and finally block (deadkey-inputhook-blocks-thread)", _TDT_AssertDeadKeyTimeout)
