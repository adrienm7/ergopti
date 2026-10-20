; tests/meta/platform/remap/keys/test_capsword_parse_time_callback.ahk

; ==============================================================================
; MODULE: CapsWord mouse-callback parse-time safety
; DESCRIPTION:
; The CapsWord mouse-cancel callback identity must be stable (HookDispatcher
; identity-compares on Unregister) AND resolvable before capsword.ahk's #Include
; position. A top-level `_CapsWord_OnMouseDown := ....Bind()` only runs when
; auto-exec reaches this file (~700 ms into boot), but ToggleCapsWord is reachable
; far earlier: a key combination bound to caps_word fires from a
; parse-time-armed hotkey once Features exists (~420 ms). Dereferencing the still-
; unset global there threw UnsetError, which the pre-ready error net escalates to
; ExitApp(1). The fix is a static-initializer accessor (_CapsWord_Callback) that
; binds lazily on first call and returns the same object every time. This guards
; the accessor exists, both toggles use it, and the fragile global is gone.
; (F11, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_CPTC_CallbackViaStaticAccessor() {
	AccBody := _DriverFuncBody("_CapsWord_Callback")
	Assert(AccBody != "", "capsword must expose a _CapsWord_Callback() accessor")
	Assert(InStr(AccBody, "static Bound := _CapsWord_HandleAutoOff.Bind()") > 0,
		"_CapsWord_Callback must lazily bind via a static initializer (resolvable any time after parse, identity-stable)")

	; The auto-off listeners are bound the same way: one static map of callbacks.
	Listeners := _DriverFuncBody("_CapsWordAutoOffCallbacks")
	Assert(Listeners != "", "capsword_auto_off must expose a _CapsWordAutoOffCallbacks() accessor")
	Assert(InStr(Listeners, "static Bound := _CapsWordAutoOffBindCallbacks()") > 0,
		"the auto-off listeners must bind via a static initializer, identity-stable for Unregister")

	Toggle := _DriverFuncBody("ToggleCapsWord")
	Disable := _DriverFuncBody("DisableCapsWord")
	Assert(InStr(Toggle, "CapsWordAutoOffArm(_CapsWord_Callback())") > 0,
		"ToggleCapsWord must arm the listeners with the accessor, not a module-scope global")
	Assert(InStr(Toggle, "CapsWordAutoOffDisarm()") > 0 && InStr(Disable, "CapsWordAutoOffDisarm()") > 0,
		"ToggleCapsWord and DisableCapsWord must both disarm the listeners")

	Src := _DriverSourceNoComments()
	Assert(InStr(Src, "_CapsWord_OnMouseDown") = 0,
		"the include-position-dependent _CapsWord_OnMouseDown global must not be reintroduced")
}
Test("capsword: mouse-cancel callback resolves via a parse-time-safe static accessor", _CPTC_CallbackViaStaticAccessor)

; A parse-time navigation callback reaches the LED writer before shortcuts load.
_CPTC_HardwareIntentBeforePump() {
	PrePump := _HGBS_PrePumpSource()
	Assert(PrePump != "", "the actual entry and first message-pump boundary must exist")
	Assert(RegExMatch(PrePump, 'm)^global _HardwareCapsLockOn := KS_CapsLockToggleState\(\)$'),
		"the entry must capture genuine CapsLock intent before the first message pump")
	Observation := _DriverFuncBody("KS_CapsLockToggleState")
	Assert(Observation != "", "the native startup observation must resolve before adapter initialization")
	Assert(RegExMatch(Observation, 's)^KS_CapsLockToggleState\(\) \{\s*return GetKeyState\("CapsLock", "T"\) \? true : false\s*\}$'),
		"the adapter must retain native toggle mode, boolean conversion and uncaught read refusal without global dependencies")
	Source := _DriverSourceNoComments()
	Count := 0, Offset := 1
	while Position := RegExMatch(Source, "m)^global _HardwareCapsLockOn :=", &Match, Offset) {
		Count += 1
		Offset := Position + StrLen(Match[0])
	}
	AssertEqual(1, Count, "late module execution must not reset an early user CapsLock intent")
}
Test("capsword: hardware intent is owned before parse-time callbacks (capslock-prepump)",
	_CPTC_HardwareIntentBeforePump)
