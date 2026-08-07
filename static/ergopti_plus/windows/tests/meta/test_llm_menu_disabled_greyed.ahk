; tests/meta/test_llm_menu_disabled_greyed.ahk

; ==============================================================================
; MODULE: LLM Menu Disabled-State Full-Greyed Render Meta Test
; DESCRIPTION:
; Regression for the "menu IA vide quand desactive" report: when the LLM feature
; is OFF, the IA submenu must still render the FULL set of rows (so the enable
; toggle is always reachable) with every settings row greyed out — mirroring the
; macOS menu's is_disabled pattern (ui/menu/menu_llm/init.lua).
;
; Two root causes are guarded here:
;   1. LLM_Deps_IsReady() was called UNGUARDED at the top of LLM_Menu_Build();
;      a throw (deps subsystem not ready while the feature is off) aborted the
;      build BEFORE the enable toggle was added, leaving the submenu empty with
;      no visible control to switch the feature back on.
;   2. Settings rows were added with no disabled flag, so there was no greying
;      (and no macOS parity) when the feature was off.
;
; Meta-static (source introspection) because the LLM tray modules register
; top-level state plus an OnMessage hook the headless runner cannot load.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================
; ==============================================
; ======= 1/ Source-introspection guards =======
; ==============================================
; ==============================================

; Guard 1 — the deps probe must be wrapped so it can never abort the build
; before the enable toggle is added (the empty-IA-submenu regression).
_LMDG_BuildGuardsDepsProbe() {
	Seg := _DriverFuncBody("LLM_Menu_Build")
	Assert(Seg != "", "LLM_Menu_Build() declaration must exist in menu_main.ahk")
	Assert(InStr(Seg, "try _deps_ready := LLM_Deps_IsReady()") > 0,
		"LLM_Menu_Build must probe LLM_Deps_IsReady() inside a try (guarded) so a throw cannot abort the build before the enable toggle is added")
	Assert(InStr(Seg, '_llm_is_operational := (_LLM_Menu["enabled"] && LLM_Deps_IsReady())') == 0,
		"LLM_Menu_Build must NOT call LLM_Deps_IsReady() unguarded inline — that throw left the IA submenu empty when the feature was off")
}
Test("menu_main: LLM_Menu_Build guards the deps probe so the toggle always renders (llm-menu-disabled-greyed)", _LMDG_BuildGuardsDepsProbe)

; Guard 2 — the SETTINGS rows grey out when off and the enable toggle is added
; unconditionally. Greying is now driven through the shared layout spec: the build
; computes _disabled from the enabled flag and resolves each row's flag against the
; spec's disabled_when_off policy (`_row["disabled_when_off"] ? _disabled : false`).
; The per-row policy itself (backend/model stay usable, the rest grey) lives in
; the menu manifest's llm_menu key and is asserted by test_llm_menu_layout_shared.
_LMDG_BuildGreysRowsWhenOff() {
	Seg := _DriverFuncBody("LLM_Menu_Build")
	Assert(Seg != "", "LLM_Menu_Build() declaration must exist in menu_main.ahk")
	Assert(InStr(Seg, '_disabled := !_LLM_Menu["enabled"]') > 0,
		"LLM_Menu_Build must compute _disabled from the enabled flag to grey settings rows when off")
	Assert(InStr(Seg, '_row["disabled_when_off"] ? _disabled : false') > 0,
		"LLM_Menu_Build must resolve each row's greying against the shared spec policy (disabled_when_off ? _disabled : false) — so backend/model stay usable while the rest grey out")
	Assert(InStr(Seg, "AddCategoryToggleItem(_LLM_Menu_Handle,") > 0,
		"LLM_Menu_Build must always add the enable toggle (AddCategoryToggleItem)")
}
Test("menu_main: LLM_Menu_Build greys the settings rows when the feature is off (llm-menu-disabled-greyed)", _LMDG_BuildGreysRowsWhenOff)

; Guard 2b — every row emitted by _LLM_Menu_EmitRow honours the resolved greying
; flag (passes `disabled` through to _LLM_Menu_AddRow), so the shared spec's policy
; actually takes effect at render. The backend/model "stay enabled while off"
; guarantee itself is the spec's disabled_when_off=false, pinned by
; test_llm_menu_layout_shared — this guard just proves the renderer applies it.
_LMDG_EmitRowAppliesGreying() {
	Seg := _DriverFuncBody("_LLM_Menu_EmitRow")
	Assert(Seg != "", "_LLM_Menu_EmitRow() must exist in menu_main.ahk")
	Assert(InStr(Seg, "_LLM_Menu_AddRow(StrReplace(t(" . Chr(34) . "menu.llm.model_backend") > 0,
		"_LLM_Menu_EmitRow must emit the backend row via _LLM_Menu_AddRow so its greying follows the spec-resolved flag")
	Assert(InStr(Seg, "model_menu, disabled)") > 0,
		"_LLM_Menu_EmitRow must emit the model row with the resolved 'disabled' flag (not a hardcoded value) so the spec policy drives greying")
}
Test("menu_main: _LLM_Menu_EmitRow applies the spec-resolved greying flag (llm-menu-disabled-greyed)", _LMDG_EmitRowAppliesGreying)

; Guard 3 — the row helper greys a row when its disabled flag is set.
_LMDG_AddRowHelperDisables() {
	Seg := _DriverFuncBody("_LLM_Menu_AddRow")
	Assert(Seg != "", "_LLM_Menu_AddRow(label, target, disabled) helper must exist in menu_main.ahk")
	Assert(InStr(Seg, ".Add(label, target)") > 0,
		"_LLM_Menu_AddRow must always Add the row so it is present at a stable position")
	Assert(InStr(Seg, "if disabled") > 0 and InStr(Seg, ".Disable(label)") > 0,
		"_LLM_Menu_AddRow must Disable() the row when disabled is true (grey it — macOS is_disabled parity)")
}
Test("menu_main: _LLM_Menu_AddRow greys a row when disabled (llm-menu-disabled-greyed)", _LMDG_AddRowHelperDisables)
