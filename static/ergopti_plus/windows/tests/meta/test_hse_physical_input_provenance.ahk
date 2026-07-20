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

; F46 (audit 2026-07-20): the suppress window exists to filter the engine's OWN
; SendInput output, so a genuinely physical feed must declare itself with
; IsPhysical=true. _SpaceTap fed its space without the flag (its space bypasses the
; InputHook entirely), so a space tapped inside the ~60 ms post-expansion suppress
; window was silently dropped from the buffer and the next trigger mis-framed. The
; Ctrl+A reset in the prefix watcher had the same omission.
_HSPIP_PhysicalFeedsDeclareProvenance() {
	Tap := _DriverFuncBody("_SpaceTap")
	Assert(Tap != "", "_SpaceTap must exist in modules/tap_holds/space.ahk")
	Assert(InStr(Tap, 'HSE_FeedChar(" ", true)') > 0,
		"_SpaceTap must feed its space as PHYSICAL (IsPhysical=true) so it survives the post-expansion suppress window")

	KeyDown := _DriverFuncBody("_OnPrefixKeyDown")
	Assert(KeyDown != "", "_OnPrefixKeyDown must exist")
	Assert(InStr(KeyDown, "HSE_FeedReset(true, true)") > 0,
		"the Ctrl+A branch must reset with IsPhysical=true so a real select-all inside the suppress window is honoured")
}
Test("HSE: physical feeds outside the InputHook declare IsPhysical", _HSPIP_PhysicalFeedsDeclareProvenance)
