; tests/meta/test_llm_tray_deferred_build.ahk

; ==============================================================================
; MODULE: LLM Tray Deferred-Build Test
; DESCRIPTION:
; Guards the order-preserving deferral of the IA submenu build.
;
; WHY THIS MATTERS (the regression this encodes):
;   LLM_Tray_Build() populates ~8 submenus and was called synchronously from
;   LLM_Tray_Init() inside initMenu(). Under load that build was measured at
;   ~1.6 s, blocking initMenu() mid-way. A tray opened during that window showed
;   only the top-level items registered before the IA entry (the user-reported
;   "menu shows only the first 2 items" bug). The fix places the IA entry in its
;   canonical position immediately (empty, persistent Menu object) and flags the
;   expensive population for the post-"ready" boot tail, where it can no longer
;   block menu completion. Re-populating the same Menu object in place preserves
;   the entry's position, so menu order is unchanged.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckLlmTrayDeferredBuild() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	InitFile := WindowsDir . "\ui\tray_llm\init.ahk"
	BootFile := WindowsDir . "\ErgoptiPlus.ahk"

	InitBody := ""
	try InitBody := FileRead(InitFile)
	Assert(InitBody != "", "ui/tray_llm/init.ahk must be readable")

	; LLM_Tray_Init must flag the build as deferred, and place the entry itself.
	Assert(InStr(InitBody, "_LLM_Tray_BuildPending := true") > 0,
		"LLM_Tray_Init must set _LLM_Tray_BuildPending := true to defer the IA submenu build")
	Assert(InStr(InitBody, 'A_TrayMenu.Add(t("menu.llm.title"), _LLM_Tray_Menu)') > 0,
		"LLM_Tray_Init must place the (empty) IA submenu in its canonical tray position")

	; And it must NOT build the menu synchronously — that is what blocked initMenu.
	Assert(!InStr(InitBody, "LLM_Tray_Build("),
		"LLM_Tray_Init must NOT call LLM_Tray_Build() synchronously — the boot tail arms it")

	; The boot tail must arm the deferred build.
	BootBody := ""
	try BootBody := FileRead(BootFile)
	Assert(BootBody != "", "ErgoptiPlus.ahk must be readable")
	Assert(InStr(BootBody, "SetTimer(LLM_Tray_Build, -LLM_TRAY_BUILD_DEFER_MS)") > 0,
		"ErgoptiPlus.ahk boot tail must arm the deferred LLM_Tray_Build")
}

Test("meta llm: LLM_Tray_Init defers the IA submenu build", _MetaCheckLlmTrayDeferredBuild)
