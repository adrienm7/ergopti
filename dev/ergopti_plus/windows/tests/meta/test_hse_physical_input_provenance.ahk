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
	Assert(Tap != "", "_SpaceTap must exist in platform/remap/space.ahk")
	Assert(InStr(Tap, 'HSE_FeedChar(" ", true)') > 0,
		"_SpaceTap must feed its space as PHYSICAL (IsPhysical=true) so it survives the post-expansion suppress window")

	KeyDown := _DriverFuncBody("_OnPrefixKeyDown")
	Invalidate := _DriverFuncBody("_PrefixInvalidateInputContext")
	Commit := _DriverFuncBody("_PrefixCommitInputContext")
	Assert(KeyDown != "", "_OnPrefixKeyDown must exist")
	Assert(InStr(KeyDown, "_PrefixInvalidateInputContext(") > 0
		and InStr(Invalidate, "_PrefixCommitInputContext(FocusToken, KnownBoundary)") > 0
		and InStr(Commit, "HSE_FeedReset(KnownBoundary, true)") > 0,
		"physical keydown resets must route through the paired transaction whose engine mutation declares IsPhysical=true")
}
Test("HSE: physical feeds outside the InputHook declare IsPhysical", _HSPIP_PhysicalFeedsDeclareProvenance)

; AHK-001 / A1-01 (audit 2026-08-26): AutoHotkey permanently stops invoking an
; InputHook callback after an exception escapes it. The prefix hook used to bind
; its large worker functions directly, leaving their setup calls outside the
; workers' narrower try regions. Keep the registration pointed at one guarded
; boundary per callback so every present and future sibling call is contained.
_AHK001_PrefixInputHookCallbacksAreContained() {
	StartHook := _DriverFuncBody("_StartInputHook")
	CharBoundary := _DriverFuncBody("_OnPrefixCharGuarded")
	KeyBoundary := _DriverFuncBody("_OnPrefixKeyDownGuarded")
	Assert(StartHook != "", "_StartInputHook must exist")
	Assert(CharBoundary != "", "the OnChar InputHook boundary must exist")
	Assert(KeyBoundary != "", "the OnKeyDown InputHook boundary must exist")
	Assert(InStr(StartHook, "Hook.OnChar    := _OnPrefixCharGuarded") > 0,
		"the InputHook must bind OnChar through its exception boundary")
	Assert(InStr(StartHook, "Hook.OnKeyDown := _OnPrefixKeyDownGuarded") > 0,
		"the InputHook must bind OnKeyDown through its exception boundary")
	Assert(InStr(CharBoundary, "try _OnPrefixCharProfiled(IH, Char)") > 0
		and InStr(CharBoundary, "catch as Err") > 0,
		"the OnChar boundary must contain profiling and every worker failure")
	Assert(InStr(KeyBoundary, "try _OnPrefixKeyDown(IH, VK, SC)") > 0
		and InStr(KeyBoundary, "catch as Err") > 0,
		"the OnKeyDown boundary must contain every worker failure")
}
Test("AHK-001: prefix InputHook callbacks contain every exception",
	_AHK001_PrefixInputHookCallbacksAreContained)
