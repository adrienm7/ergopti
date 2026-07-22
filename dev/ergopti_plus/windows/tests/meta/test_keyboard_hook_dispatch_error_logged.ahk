; tests/meta/test_keyboard_hook_dispatch_error_logged.ahk

; ==============================================================================
; MODULE: Keyboard Hook Dispatch Error Logged Meta Test
; DESCRIPTION:
; Regression guard for AHK-20: _KH_DispatchChar and _KH_DispatchKey called the
; subscriber callback (_KH_ON_CHAR / _KH_ON_KEY) with a bare "try X()" and no
; catch block, swallowing any exception the callback threw. This bypassed
; HookDispatcher.Dispatch, the centralized error sink that logs errors AND
; releases stuck modifiers. A subscriber failure was silently discarded with
; zero diagnostics; the feature processing for that keystroke was lost.
;
; The fix removes the bare "try" on both call sites so exceptions propagate to
; HookDispatcher.Dispatch, which wraps every subscriber call in its own
; try/catch+log+modifier-release pattern (hook_dispatcher.ahk:212-227).
;
; This test asserts (source introspection):
;   (a) _KH_DispatchChar body does NOT contain "try _KH_ON_CHAR" — the bare
;       bare-try-no-catch pattern is gone.
;   (b) _KH_DispatchKey body does NOT contain "try _KH_ON_KEY" — same.
;   (c) Both bodies still call the handler (the calls were not removed).
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Test implementation ====================================
; ===================================================================
; ===================================================================

_TKHDEL_CheckDispatchCharNoBareSwallow() {
	Body := _DriverFuncBody("_KH_DispatchChar")
	Assert(Body != "", "_KH_DispatchChar must exist in adapters/keyboard_hook.ahk")

	; (a) Bare try _KH_ON_CHAR must be gone — exceptions must propagate to
	; HookDispatcher.Dispatch so the centralized error sink can log and release
	; stuck modifiers on subscriber failure
	Assert(!InStr(Body, "try _KH_ON_CHAR"),
		"AHK-20: 'try _KH_ON_CHAR' (bare, no catch) must not appear in _KH_DispatchChar — a bare try swallows subscriber exceptions and bypasses HookDispatcher's stuck-modifier recovery and centralized error logging")

	; (c) The handler must still be called (the fix removes the try, not the call)
	Assert(InStr(Body, "_KH_ON_CHAR"),
		"AHK-20: _KH_DispatchChar must still call _KH_ON_CHAR — the fix removes only the bare try wrapper, not the dispatch itself")
}

_TKHDEL_CheckDispatchKeyNoBareSwallow() {
	Body := _DriverFuncBody("_KH_DispatchKey")
	Assert(Body != "", "_KH_DispatchKey must exist in adapters/keyboard_hook.ahk")

	; (b) Bare try _KH_ON_KEY must be gone
	Assert(!InStr(Body, "try _KH_ON_KEY"),
		"AHK-20: 'try _KH_ON_KEY' (bare, no catch) must not appear in _KH_DispatchKey — bare try swallows subscriber exceptions and bypasses HookDispatcher centralized error logging and stuck-modifier recovery")

	; (c) The handler must still be called
	Assert(InStr(Body, "_KH_ON_KEY"),
		"AHK-20: _KH_DispatchKey must still call _KH_ON_KEY — the fix removes only the bare try wrapper, not the dispatch itself")
}


Test("meta ahk-20: _KH_DispatchChar has no bare try around _KH_ON_CHAR call — subscriber errors propagate to HookDispatcher",
	_TKHDEL_CheckDispatchCharNoBareSwallow)

Test("meta ahk-20: _KH_DispatchKey has no bare try around _KH_ON_KEY call — subscriber errors propagate to HookDispatcher",
	_TKHDEL_CheckDispatchKeyNoBareSwallow)
