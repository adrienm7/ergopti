; tests/meta/test_llm_menu_init_order.ahk

; ==============================================================================
; MODULE: LLM Tray Initialisation Order Test
; DESCRIPTION:
; Verifies that initMenu() resets _LLM_Menu_InTray to false immediately before
; calling LLM_Menu_Init(), preventing a race condition where a background
; health-probe timer fires LLM_Menu_Build() during boot (before initMenu() has
; run) and prematurely sets _LLM_Menu_InTray := true. Without the reset, the
; "Intelligence Artificielle" entry is silently skipped when initMenu() finally
; runs, because LLM_Menu_Build() sees InTray = true and skips A_TrayMenu.Add.
;
; HOW THE RACE HAPPENS:
;   LLM_Menu_Init() (called from initMenu) starts a 10-second health-probe
;   timer. On a slow or busy boot the timer can fire before initMenu() reaches
;   the LLM block. LLM_Menu_Build() then adds the entry (InTray := true).
;   When initMenu() subsequently calls LLM_Menu_Init → LLM_Menu_Build again,
;   the guard skips A_TrayMenu.Add — but A_TrayMenu.Delete() at the top of
;   initMenu() has already wiped the prematurely-added entry, so the menu item
;   is gone with no error.
;
; THE FIX: set _LLM_Menu_InTray := false in initMenu() before LLM_Menu_Init
; so LLM_Menu_Build() always (re-)registers the entry at the correct position.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckLlmTrayInitOrder() {
	; Scope the check to initMenu()'s body (now in ui/menu/menu_init.ahk) via the
	; location-independent driver-source helper, so the order assertion survives
	; the menu decomposition. The reset must come before the LLM_Menu_Init() call.
	Body := _DriverFuncBody("initMenu")
	Assert(Body != "", "initMenu() must exist in the driver source")

	ResetPos := InStr(Body, "_LLM_Menu_InTray := false")
	InitPos  := InStr(Body, "LLM_Menu_Init(")

	Assert(ResetPos > 0,
		"initMenu() must set _LLM_Menu_InTray := false before LLM_Menu_Init() "
		. "to prevent the boot-time race condition that hides the IA menu entry")

	Assert(InitPos > 0,
		"initMenu() must call LLM_Menu_Init() — entry point not found")

	Assert(ResetPos < InitPos,
		"_LLM_Menu_InTray := false must appear before LLM_Menu_Init() in initMenu() "
		. "(found reset at offset " . ResetPos . ", LLM_Menu_Init at offset " . InitPos . ")")
}

Test("meta llm: _LLM_Menu_InTray reset before LLM_Menu_Init in initMenu()",
	_MetaCheckLlmTrayInitOrder)
