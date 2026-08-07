; tests/meta/test_llm_menu_layout_shared.ahk

; ==============================================================================
; MODULE: Shared LLM Menu Layout Contract Test
; DESCRIPTION:
; The IA submenu's row ORDER and disabled-when-off POLICY are a single shared
; source of truth — the menu manifest's ``llm_menu`` key — consumed by BOTH the
; Windows renderer (LLM_Menu_Build via _LLM_Menu_EmitRow) and the macOS renderer
; (init.lua build_item). This test pins that contract so the two menus can never
; drift again (a greying mismatch between them was the bug that motivated it):
;
;   1. The manifest declares exactly the canonical rows, in order, with the
;      correct disabled_when_off policy (backend + model usable while off; the
;      rest greyed).
;   2. The Windows built-in fallback (_LLM_MenuLayout_Fallback) mirrors the
;      manifest exactly — a second copy that exists only for resilience must not
;      drift.
;   3. LLM_Menu_Build is actually spec-DRIVEN (loops _LLM_MenuLayout_Rows() and
;      dispatches via _LLM_Menu_EmitRow) rather than hardcoding the row list.
;   4. _LLM_Menu_EmitRow answers every canonical id, so a renamed row cannot
;      silently fall through to the "unknown row id" branch and vanish.
;   5. The retired second description has not come back.
;
; MOVED 2026-08-07: this contract used to read _shared/modules/llm/menu_layout.json,
; a spec file of its own. One menu therefore had TWO shared descriptions — that
; file and the manifest's ``llm_menu`` key, which described a two-row menu only
; Linux drew — and neither mentioned the other. The rows now live in the manifest
; with the rest of the menu tree, and assertion 5 below is what stops a second
; description from being reintroduced.
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
		Map("id", "llm_backend",             "off", false),
		Map("id", "llm_model",               "off", false),
		Map("id", "llm_profile",             "off", true),
		Map("id", "llm_num_predictions",     "off", true),
		Map("id", "llm_trigger",             "off", true),
		Map("id", "llm_generation_settings", "off", true),
		Map("id", "llm_display",             "off", true),
		Map("id", "llm_navigation",          "off", true)
	]
}

_LMLS_SharedDir() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	return WindowsDir . "\..\_shared"
}

; The manifest rows this platform renders: the declared ``dynamic`` rows of
; llm_menu that are visible on "ahk". Linux's two inline `list` rows and the
; separator between them are not settings rows and are filtered out here exactly
; as _LLM_MenuLayout_Rows() filters them at runtime.
_LMLS_ManifestRows() {
	path := _LMLS_SharedDir() . "\modules\menu\menu_manifest.json"
	content := ""
	try content := FileRead(path, "UTF-8")
	Assert(content != "", "_shared/modules/menu/menu_manifest.json must be readable")
	parsed := JsonParse(content)
	Assert(parsed is Map && parsed.Has("llm_menu"), "menu_manifest.json must have an 'llm_menu' array")
	Rows := []
	for _, Entry in parsed["llm_menu"] {
		if !(Entry is Map) or !Entry.Has("type") or Entry["type"] != "dynamic"
			continue
		Visible := true
		if Entry.Has("platforms") {
			Visible := false
			for _, P in Entry["platforms"] {
				if (P == "ahk") {
					Visible := true
					break
				}
			}
		}
		if Visible
			Rows.Push(Entry)
	}
	return Rows
}




; ==================================================
; ======= 2/ Contract assertions ===================
; ==================================================

; The manifest must declare exactly the canonical rows, in order, with the
; correct policy — this is the source of truth both platforms read.
_LMLS_ManifestMatchesCanonical() {
	rows := _LMLS_ManifestRows()
	canon := _LMLS_Canonical()
	Assert(rows.Length == canon.Length,
		"llm_menu must declare exactly " . canon.Length . " Windows row(s) — found " . rows.Length)
	for i, c in canon {
		Assert(rows[i]["id"] == c["id"],
			"llm_menu row " . i . " must be '" . c["id"] . "' (order is the menu order)")
		Assert((rows[i]["disabled_when_off"] = true) == (c["off"] = true),
			"llm_menu row '" . c["id"] . "' disabled_when_off must be " . (c["off"] ? "true" : "false")
			. " (backend/model stay usable while off; the rest grey out — macOS parity)")
	}
}
Test("llm-menu-layout-shared: the manifest matches the canonical row order + greying policy", _LMLS_ManifestMatchesCanonical)

; The Windows fallback array must mirror the manifest exactly — it exists only so
; a missing/corrupt manifest still renders a menu, and must never become a 2nd truth.
_LMLS_FallbackMirrorsManifest() {
	Seg := _DriverFuncBody("_LLM_MenuLayout_Fallback")
	Assert(Seg != "", "_LLM_MenuLayout_Fallback() must exist in menu_main.ahk")
	for _, c in _LMLS_Canonical() {
		; Tolerate variable inner spacing: assert the id and its bool co-occur in the body.
		idTok  := '"id", "' . c["id"] . '"'
		boolTok := '"disabled_when_off", ' . (c["off"] ? "true" : "false")
		Assert(InStr(Seg, idTok) > 0,
			"_LLM_MenuLayout_Fallback must contain row id '" . c["id"] . "'")
		Assert(InStr(Seg, idTok) > 0 and InStr(Seg, boolTok) > 0,
			"_LLM_MenuLayout_Fallback row '" . c["id"] . "' must carry disabled_when_off=" . (c["off"] ? "true" : "false") . " (mirror the manifest)")
	}
}
Test("llm-menu-layout-shared: Windows fallback mirrors the manifest", _LMLS_FallbackMirrorsManifest)

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

; Every declared row must have a case in the dispatch. Without this, renaming a
; row in the manifest leaves the driver answering nothing for it: the row falls
; through to the "unknown row id" warning and simply disappears from the menu,
; which is silent to a user who never reads the log.
_LMLS_DispatchAnswersEveryRow() {
	Seg := _DriverFuncBody("_LLM_Menu_EmitRow")
	Assert(Seg != "", "_LLM_Menu_EmitRow() must exist in menu_main.ahk")
	for _, c in _LMLS_Canonical() {
		Assert(InStr(Seg, 'case "' . c["id"] . '":') > 0,
			"_LLM_Menu_EmitRow must answer the declared row '" . c["id"]
			. "' — an unanswered id is dropped with only a log line to show for it")
	}
}
Test("llm-menu-layout-shared: the dispatch answers every declared row", _LMLS_DispatchAnswersEveryRow)

; The retired spec file must stay retired. Two shared descriptions of one menu is
; the state this migration ended; a reintroduced menu_layout.json would drift from
; the manifest with nothing comparing them.
_LMLS_NoSecondDescription() {
	path := _LMLS_SharedDir() . "\modules\llm\menu_layout.json"
	Assert(!FileExist(path),
		"_shared/modules/llm/menu_layout.json must not exist — the IA menu is described in the "
		. "menu manifest's llm_menu key, and a second shared description would drift from it")
}
Test("llm-menu-layout-shared: the retired second description has not come back", _LMLS_NoSecondDescription)
