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
; ExitApp(1). The fix is a static-initializer accessor (CapsWordEndCallback) that
; binds lazily on first call and returns the same object every time; its
; identity and the early toggle are pinned by behaviour in
; unit/modules/shortcuts/test_capsword_state.ahk. This guards the fragile
; global staying gone.
; (F11, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_CPTC_CallbackViaStaticAccessor() {
	Listeners := _DriverFuncBody("_CapsWordAutoOffCallbacks")
	Assert(Listeners != "", "capsword_auto_off must expose a _CapsWordAutoOffCallbacks() accessor")
	Assert(InStr(Listeners, "return CapsWordAutoOff.Callbacks") > 0,
		"the auto-off listeners must retain the exact activation callback map in their parse-time-safe class")
	Src := _DriverSourceNoComments()
	Assert(Src != "" && InStr(Src, "static Callbacks := Map()"),
		"the activation callback map must initialize on class access, never at include execution")
	Assert(InStr(Src, "_CapsWord_OnMouseDown") = 0,
		"the include-position-dependent _CapsWord_OnMouseDown global must not be reintroduced")
}
Test("capsword: the listener map initializes on class access, no include-position global (parse-time)", _CPTC_CallbackViaStaticAccessor)

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
