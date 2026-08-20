; static/ergopti_plus/windows/tests/unit/test_metrics_shortcut_persist_on_bind_failure.ahk

; ==============================================================================
; MODULE: Metrics Shortcut Persist-On-Failure Test
; DESCRIPTION:
; Guards MS_ShouldPersistShortcut(), the syntactic eligibility helper used by
; the transactional shortcut owner before it touches Hotkey() or config.toml.
;
; FEATURES & RATIONALE:
; 1. Regression for F38: MS_PromptShortcut used to write the raw user string
;    to MetricsShortcuts.typing_str/apps_str unconditionally, even when
;    MS_BindHotkey() failed to register it (MS_BindHotkey returns ""). The
;    bad string was then replayed on every future boot by MS_ApplyAll(),
;    re-triggering the Hotkey() registration failure (and its blocking
;    MsgBox) forever.
; 2. A non-empty raw string needs a translated native candidate. An explicit
;    clear is syntactically eligible; the transaction test separately proves
;    that a failed durable clear leaves the old binding live.
; ==============================================================================





; =====================================================
; =====================================================
; ======= 1/ MS_ShouldPersistShortcut decisions =======
; =====================================================
; =====================================================

_MSPF_ExplicitClearIsPersisted() {
	AssertTrue(MS_ShouldPersistShortcut("", ""),
		"an explicit clear must be eligible for the transactional commit")
}
Test("MS_ShouldPersistShortcut: explicit clear is always persisted", _MSPF_ExplicitClearIsPersisted)

_MSPF_SuccessfulBindIsPersisted() {
	; A non-empty raw string with a translated native candidate may proceed to
	; the OS-registration and durable-commit steps.
	AssertTrue(MS_ShouldPersistShortcut("ctrl+alt+m", "^!m"), "a successfully bound shortcut must be persisted")
}
Test("MS_ShouldPersistShortcut: a successfully bound shortcut is persisted", _MSPF_SuccessfulBindIsPersisted)

_MSPF_FailedBindIsNotPersisted() {
	; A non-empty raw string with no native candidate must NOT be persisted --
	; else it replays forever via MS_ApplyAll() at boot.
	AssertFalse(MS_ShouldPersistShortcut("ctrl+alt+boguskey", ""),
		"a shortcut that failed Hotkey() registration must not be persisted (F38 — replayed forever otherwise)")
}
Test("MS_ShouldPersistShortcut: a shortcut that failed registration is not persisted (F38)", _MSPF_FailedBindIsNotPersisted)
