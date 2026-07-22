; tests/meta/test_llm_menu_layout_shared.ahk

; ==============================================================================
; MODULE: Shared LLM Menu Layout Contract Test
; DESCRIPTION:
; The IA submenu's row ORDER and disabled-when-off POLICY are now a single shared
; source of truth — _shared/modules/llm/menu_layout.json — consumed by BOTH the
; Windows renderer (LLM_Menu_Build via _LLM_Menu_EmitRow) and the macOS renderer
; (init.lua build_item). This test pins that contract so the two menus can never
; drift again (a greying mismatch between them was the bug that motivated it):
;
;   1. The shared JSON declares exactly the canonical rows, in order, with the
;      correct disabled_when_off policy (backend + model usable while off; the
;      rest greyed).
;   2. The Windows built-in fallback (_LLM_MenuLayout_Fallback) mirrors the JSON
;      exactly — a second copy that exists only for resilience must not drift.
;   3. LLM_Menu_Build is actually spec-DRIVEN (loops _LLM_MenuLayout_Rows() and
;      dispatches via _LLM_Menu_EmitRow) rather than hardcoding the row list.
;
; The macOS conformance half lives in macos/tests/test_llm_menu_layout_shared.lua.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ======= 1/ Canonical contract (the truth) ========
; ==================================================

; The canonical row order + greying policy. Index order IS the menu order.
; disabled_when_off: false = stays usable while the feature is off (configure
; before enabling), true = greyed while off. Mirrors macOS is_disabled vs paused.
_LMLS_Canonical() {
	return [
		Map("id", "backend",         "off", false),
		Map("id", "model",           "off", false),
		Map("id", "profile",         "off", true),
		Map("id", "num_predictions", "off", true),
		Map("id", "trigger",         "off", true),
		Map("id", "generation",      "off", true),
		Map("id", "display",         "off", true),
		Map("id", "navigation",      "off", true)
	]
}

_LMLS_SharedJsonPath() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	return WindowsDir . "\..\_shared\modules\llm\menu_layout.json"
}




; ==================================================
; ======= 2/ Contract assertions ===================
; ==================================================

; The shared JSON must declare exactly the canonical rows, in order, with the
; correct policy — this is the source of truth both platforms read.
_LMLS_SharedJsonMatchesCanonical() {
	path := _LMLS_SharedJsonPath()
	content := ""
	try content := FileRead(path, "UTF-8")
	Assert(content != "", "_shared/modules/llm/menu_layout.json must be readable")
	parsed := JsonParse(content)
	Assert(parsed is Map && parsed.Has("rows"), "menu_layout.json must have a 'rows' array")
	rows := parsed["rows"]
	canon := _LMLS_Canonical()
	Assert(rows.Length == canon.Length,
		"menu_layout.json must declare exactly " . canon.Length . " rows — found " . rows.Length)
	for i, c in canon {
		Assert(rows[i] is Map && rows[i]["id"] == c["id"],
			"menu_layout.json row " . i . " must be '" . c["id"] . "' (order is the menu order)")
		Assert((rows[i]["disabled_when_off"] = true) == (c["off"] = true),
			"menu_layout.json row '" . c["id"] . "' disabled_when_off must be " . (c["off"] ? "true" : "false")
			. " (backend/model stay usable while off; the rest grey out — macOS parity)")
	}
}
Test("llm-menu-layout-shared: menu_layout.json matches the canonical row order + greying policy", _LMLS_SharedJsonMatchesCanonical)

; The Windows fallback array must mirror the JSON exactly — it exists only so a
; missing/corrupt spec still renders a menu, and must never become a 2nd truth.
_LMLS_FallbackMirrorsJson() {
	Seg := _DriverFuncBody("_LLM_MenuLayout_Fallback")
	Assert(Seg != "", "_LLM_MenuLayout_Fallback() must exist in menu_main.ahk")
	for _, c in _LMLS_Canonical() {
		; Tolerate variable inner spacing: assert the id and its bool co-occur in the body.
		idTok  := '"id", "' . c["id"] . '"'
		boolTok := '"disabled_when_off", ' . (c["off"] ? "true" : "false")
		Assert(InStr(Seg, idTok) > 0,
			"_LLM_MenuLayout_Fallback must contain row id '" . c["id"] . "'")
		Assert(InStr(Seg, idTok) > 0 and InStr(Seg, boolTok) > 0,
			"_LLM_MenuLayout_Fallback row '" . c["id"] . "' must carry disabled_when_off=" . (c["off"] ? "true" : "false") . " (mirror the JSON)")
	}
}
Test("llm-menu-layout-shared: Windows fallback mirrors the shared JSON", _LMLS_FallbackMirrorsJson)

; LLM_Menu_Build must be spec-DRIVEN: it loops the shared rows and dispatches each
; via _LLM_Menu_EmitRow, rather than hardcoding the settings-row list inline.
_LMLS_BuildIsSpecDriven() {
	Seg := _DriverFuncBody("LLM_Menu_Build")
	Assert(Seg != "", "LLM_Menu_Build() must exist in menu_main.ahk")
	Assert(InStr(Seg, "_LLM_MenuLayout_Rows()") > 0,
		"LLM_Menu_Build must read the row list from _LLM_MenuLayout_Rows() (the shared spec) — not hardcode it")
	Assert(InStr(Seg, "_LLM_Menu_EmitRow(") > 0,
		"LLM_Menu_Build must dispatch each row via _LLM_Menu_EmitRow so order + greying come from the shared spec")
}
Test("llm-menu-layout-shared: LLM_Menu_Build is driven by the shared layout spec", _LMLS_BuildIsSpecDriven)
