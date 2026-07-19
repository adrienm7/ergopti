; tests/meta/test_hse_physical_input_provenance.ahk
#Requires AutoHotkey v2.0

Test_HSE_PhysicalInputIsNotDroppedByOutputGuard() {
	StartHook := _DriverFuncBody("_StartInputHook")
	OnChar := _DriverFuncBody("_OnPrefixChar")
	Suppress := _DriverFuncBody("PrefixWatcherSuppress")
	Assert(InStr(StartHook, 'InputHook("V L0 I1")') > 0,
		"prefix watcher must use InputHook I1 to distinguish low-level synthetic output")
	Assert(InStr(OnChar, "HSE_FeedChar(Char, true)") > 0,
		"OnChar must pass physical-event provenance to the engine instead of applying a time-based guard")
	Assert(InStr(OnChar, "_PrefixWatcherSuppressed or HSE_Suppressed") == 0,
		"a physical character must not be dropped by the time-based prefix guard")
	Assert(InStr(Suppress, "HSE_Suppress(YesNo)") == 0,
		"the render guard must not suppress HSE physical input")
}
Test("HSE: physical input survives a nearby output transaction", Test_HSE_PhysicalInputIsNotDroppedByOutputGuard)
