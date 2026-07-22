; tests/meta/test_capsword_parse_time_callback.ahk

; ==============================================================================
; MODULE: CapsWord mouse-callback parse-time safety
; DESCRIPTION:
; The CapsWord mouse-cancel callback identity must be stable (HookDispatcher
; identity-compares on Unregister) AND resolvable before capsword.ahk's #Include
; position. A top-level `_CapsWord_OnMouseDown := ....Bind()` only runs when
; auto-exec reaches this file (~700 ms into boot), but ToggleCapsWord is reachable
; far earlier: the default-enabled lalt_caps_lock.caps_word action fires from a
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
	Assert(InStr(AccBody, "static Bound := _CapsWord_HandleMouseDown.Bind()") > 0,
		"_CapsWord_Callback must lazily bind via a static initializer (resolvable any time after parse, identity-stable)")

	Toggle := _DriverFuncBody("ToggleCapsWord")
	Disable := _DriverFuncBody("DisableCapsWord")
	Assert(InStr(Toggle, "_CapsWord_Callback()") > 0 && InStr(Disable, "_CapsWord_Callback()") > 0,
		"ToggleCapsWord and DisableCapsWord must register/unregister via the accessor, not a module-scope global")

	Src := _DriverSourceNoComments()
	Assert(InStr(Src, "_CapsWord_OnMouseDown") = 0,
		"the include-position-dependent _CapsWord_OnMouseDown global must not be reintroduced")
}
Test("capsword: mouse-cancel callback resolves via a parse-time-safe static accessor", _CPTC_CallbackViaStaticAccessor)
