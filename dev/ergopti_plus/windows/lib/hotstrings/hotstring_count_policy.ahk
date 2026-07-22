; lib/hotstrings/hotstring_count_policy.ahk

; ==============================================================================
; MODULE: Hotstring Count Display Policy
; DESCRIPTION:
; The single pure rule deciding what hotstring count the tray menu shows for a
; given scope (the whole Hotstrings menu, a category submenu, a personal
; sub-group). The menu must display the number of hotstrings that are actually
; ACTIVE — never "what would reactivate". A scope whose master/category gate is
; off contributes 0, regardless of the per-section flags persisted on disk.
;
; FEATURES & RATIONALE:
; 1. Pure + dependency-light: takes the resolved gate state and the enabled-only
;    section count as plain arguments, touches no Features map, no menu, no OS —
;    so it is unit-tested in isolation (tests/unit/test_hotstring_count_policy.ahk)
;    and cannot regress to the old "show the full count while disabled" behaviour.
; 2. Single source of truth: every count site (grand total + per-category labels)
;    routes through this helper so the displayed numbers can never diverge.
; ==============================================================================




; ==========================================
; ==========================================
; ======= 1/ Gated count policy ============
; ==========================================
; ==========================================

; Return the hotstring count to display for a scope: its enabled-section count
; while the scope is gated on, or 0 when the gate is off (a disabled scope shows
; no active hotstrings, not the count it would have if re-enabled).
; @param IsGated       {Boolean} true when every gate covering the scope is on.
; @param EnabledCount  {Integer} count of the scope's individually-enabled sections.
; @returns {Integer} EnabledCount when gated on, else 0.
_HS_GatedCount(IsGated, EnabledCount) {
	return IsGated ? EnabledCount : 0
}
