; tests/meta/platform/remap/layers/test_deadkey_timeout.ahk

#Requires AutoHotkey v2.0

_TDT_AssertDeadKeyTimeout() {
	; Move-resilient: locate DeadKey() across the whole driver source via the
	; framework helper instead of a pinned modules path
	DeadKeyBody := _DriverFuncBody("DeadKey")
	
	Assert(DeadKeyBody != "", "the real DeadKey implementation must exist")
	TimeoutIdx := InStr(DeadKeyBody, 'InputHook("L2 E C T2", _SIHO_ScalarEndKeys() . NamedKeys)')
	Assert(TimeoutIdx > 0, "DeadKey InputHook must have a timeout (e.g. T2) (deadkey-inputhook-blocks-thread)")
	
	FinallyIdx := InStr(DeadKeyBody, "finally {")
	Assert(FinallyIdx > 0, "DeadKey must use a finally block to reset InDeadKeySequence (deadkey-inputhook-blocks-thread)")
}

Test("layout: DeadKey InputHook has a timeout and finally block (deadkey-inputhook-blocks-thread)", _TDT_AssertDeadKeyTimeout)
