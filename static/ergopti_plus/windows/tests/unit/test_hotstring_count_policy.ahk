; tests/unit/test_hotstring_count_policy.ahk

; ==============================================================================
; MODULE: Hotstring Count Display Policy Tests
; DESCRIPTION:
; Regression guard for the tray-menu hotstring count (infra/hotstrings/
; hotstring_count_policy.ahk). The menu must show the number of ACTIVE
; hotstrings; a gated-off scope (e.g. the whole Hotstrings menu toggled off)
; must contribute 0, NOT the full "what would reactivate" count. Reproduces the
; report "désactiver menu hotstrings, mais son total est encore à +3000".
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================================================
; ==============================================================
; ======= 1/ Gated count policy ================================
; ==============================================================
; ==============================================================

; A gated-OFF scope shows 0 — the bug was showing the full section count here.
Test("hs_count: gated-off scope contributes 0, not its full count", () => (
	AssertEqual(0, _HS_GatedCount(false, 3127), "disabled hotstrings menu must show 0")
))

; A gated-ON scope shows its enabled-only count unchanged.
Test("hs_count: gated-on scope shows its enabled count", () => (
	AssertEqual(42, _HS_GatedCount(true, 42), "enabled hotstrings menu shows enabled count")
))

; Zero enabled while gated on stays 0 (every section individually disabled).
Test("hs_count: gated-on with no enabled sections shows 0", () => (
	AssertEqual(0, _HS_GatedCount(true, 0), "all sections off shows 0")
))
