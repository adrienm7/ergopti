; tests/meta/test_llm_menu_build_critical.ahk

; ==============================================================================
; MODULE: LLM Menu Build-Then-Publish Meta Test
; DESCRIPTION:
; Rebuilding the persistent submenu with Delete() exposed an empty or partially
; populated tree to tray clicks. Holding Critical over the full replacement made
; keyboard latency unbounded instead. The safe contract is detached construction,
; followed by one brief publication/prune commit under Critical.
;
; Source-level (mirrors the sibling menu meta tests): exercising the build needs a live
; tray HMENU and the dispatcher's OnMessage hook.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Build then publish =========
; ======================================
; ======================================

_LMBC_BuildIsStaged() {
	Body := _DriverFuncBody("LLM_Menu_Build")
	Assert(Body != "", "menu_main.ahk must define LLM_Menu_Build()")
	Assert(InStr(Body, "StagedHandle := Menu()") > 0 and InStr(Body, "OldHandle := _LLM_Menu_Handle") > 0,
		"LLM_Menu_Build must construct a detached staged Menu while retaining the old published handle")
	Assert(InStr(Body, "_LLM_Menu_Handle.Delete()") == 0,
		"LLM_Menu_Build must not delete the live submenu before the staged replacement is complete")
	Assert(InStr(Body, "_PublishCritical := Critical") > 0 and InStr(Body, 'A_TrayMenu.Add(t("menu.llm.title"), _LLM_Menu_Handle)') > 0,
		"LLM_Menu_Build must publish the staged submenu in its short Critical commit")
	Assert(InStr(Body, "if !Published") > 0 and InStr(Body, "_LLM_Menu_Handle := OldHandle") > 0,
		"a failed staged build must restore the old live submenu instead of publishing a partial tree")
}
Test("menu_main: LLM_Menu_Build stages then atomically publishes the submenu (llm-menu-build-then-publish)",
	_LMBC_BuildIsStaged)
