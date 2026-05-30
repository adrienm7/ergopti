; tests/meta/test_llm_tray_init_order.ahk

; ==============================================================================
; MODULE: LLM Tray Initialisation Order Test
; DESCRIPTION:
; Verifies that initMenu() resets _LLM_Tray_InTray to false immediately before
; calling LLM_Tray_Init(), preventing a race condition where a background
; health-probe timer fires LLM_Tray_Build() during boot (before initMenu() has
; run) and prematurely sets _LLM_Tray_InTray := true. Without the reset, the
; "Intelligence Artificielle" entry is silently skipped when initMenu() finally
; runs, because LLM_Tray_Build() sees InTray = true and skips A_TrayMenu.Add.
;
; HOW THE RACE HAPPENS:
;   LLM_Tray_Init() (called from initMenu) starts a 10-second health-probe
;   timer. On a slow or busy boot the timer can fire before initMenu() reaches
;   the LLM block. LLM_Tray_Build() then adds the entry (InTray := true).
;   When initMenu() subsequently calls LLM_Tray_Init → LLM_Tray_Build again,
;   the guard skips A_TrayMenu.Add — but A_TrayMenu.Delete() at the top of
;   initMenu() has already wiped the prematurely-added entry, so the menu item
;   is gone with no error.
;
; THE FIX: set _LLM_Tray_InTray := false in initMenu() before LLM_Tray_Init
; so LLM_Tray_Build() always (re-)registers the entry at the correct position.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckLlmTrayInitOrder() {
	; Locate tray_menu.ahk relative to the tests/ directory.
	SplitPath(A_ScriptDir, , &WindowsDir)
	TrayMenuFile := WindowsDir . "\ui\tray_menu.ahk"

	try {
		Body := FileRead(TrayMenuFile)
	} catch {
		return
	}

	; The fix requires that _LLM_Tray_InTray := false appears BEFORE the
	; LLM_Tray_Init() call inside initMenu(). We verify by finding the byte
	; offset of both strings: the reset must come first.
	ResetPos := InStr(Body, "_LLM_Tray_InTray := false")
	InitPos  := InStr(Body, "LLM_Tray_Init(")

	Assert(ResetPos > 0,
		"tray_menu.ahk must set _LLM_Tray_InTray := false before LLM_Tray_Init() "
		. "to prevent the boot-time race condition that hides the IA menu entry")

	Assert(InitPos > 0,
		"tray_menu.ahk must call LLM_Tray_Init() — entry point not found")

	Assert(ResetPos < InitPos,
		"_LLM_Tray_InTray := false must appear before LLM_Tray_Init() in tray_menu.ahk "
		. "(found reset at offset " . ResetPos . ", LLM_Tray_Init at offset " . InitPos . ")")
}

Test("meta llm: _LLM_Tray_InTray reset before LLM_Tray_Init in initMenu()",
	_MetaCheckLlmTrayInitOrder)
