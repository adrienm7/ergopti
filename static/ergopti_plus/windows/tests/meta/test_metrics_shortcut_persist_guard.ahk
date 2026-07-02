; static/ergopti_plus/windows/tests/meta/test_metrics_shortcut_persist_guard.ahk

; ==============================================================================
; MODULE: MS_PromptShortcut Persist-Guard Meta Test
; DESCRIPTION:
; Static source guard for finding F38 (metrics-shortcut-bad-string-replayed-
; forever). Pins that MS_PromptShortcut actually routes both the "typing" and
; "apps" persistence writes through MS_ShouldPersistShortcut() -- the
; behavioral test on the helper alone (test_metrics_shortcut_persist_on_bind_
; failure.ahk) cannot catch a future edit that reintroduces an unconditional
; ``*_str := raw`` write while leaving the helper itself untouched and unused.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Persist-guard wiring assertion =========
; ===================================================
; ===================================================

_MSPG_PromptShortcutUsesGuard() {
	Body := _DriverFuncBody("MS_PromptShortcut")
	Assert(Body != "", "MS_PromptShortcut(which, ToggleFn) declaration must exist in metrics_shortcuts.ahk")

	GuardCount := 0
	Pos := 1
	Needle := "MS_ShouldPersistShortcut("
	while (Pos := InStr(Body, Needle, , Pos)) {
		GuardCount += 1
		Pos += StrLen(Needle)
	}
	Assert(GuardCount >= 2,
		"MS_PromptShortcut must call MS_ShouldPersistShortcut() on both the 'typing' and 'apps' branches before persisting")

	Assert(InStr(Body, "LoggerWarn") > 0,
		"MS_PromptShortcut must log a WARNING when a shortcut fails to persist rather than failing silently")
}
Test("metrics_shortcuts: MS_PromptShortcut persists via MS_ShouldPersistShortcut on both branches (F38)", _MSPG_PromptShortcutUsesGuard)
