; tests/meta/test_llm_menu_deferred_build.ahk

; ==============================================================================
; MODULE: LLM Tray Deferred-Build Test
; DESCRIPTION:
; Guards the order-preserving deferral of the IA submenu build.
;
; WHY THIS MATTERS (the regression this encodes):
;   LLM_Menu_Build() populates ~8 submenus and was called synchronously from
;   LLM_Menu_Init() inside initMenu(). Under load that build was measured at
;   ~1.6 s, blocking initMenu() mid-way. A tray opened during that window showed
;   only the top-level items registered before the IA entry (the user-reported
;   "menu shows only the first 2 items" bug). The fix places the IA entry in its
;   canonical position immediately (empty, persistent Menu object) and arms the
;   expensive population for the post-"ready" boot tail, where it can no longer
;   block menu completion. Re-populating the same Menu object in place preserves
;   the entry's position, so menu order is unchanged.
;
; SECOND REGRESSION (empty IA submenu when the feature is OFF):
;   The boot tail used to arm the population behind `if _LLM_Menu_BuildPending`,
;   a flag set by LLM_Menu_Init(). But at boot the FULL menu — initMenu() →
;   LLM_Menu_Init() — is built only inside the DEFERRED BuildTrayMenuDeferred
;   pass, which fires AFTER the synchronous boot tail has already read the flag
;   (still false). So the build was never armed: the IA submenu stayed empty
;   unless some OTHER trigger rebuilt it. When the feature is enabled the
;   health-probe tick rebuilds on the first backend-status change and masks the
;   bug; when it is OFF nothing ever rebuilds, so the submenu is empty forever —
;   no enable toggle, no way to turn the feature back on. THE FIX: arm
;   LLM_Menu_Build at the boot tail (the module is always loaded) and drop the
;   race-prone flag entirely.
;
; THIRD REGRESSION (boot-time synchronous /api/tags block when ON):
;   Arming the boot build UNCONDITIONALLY then froze the keyboard thread when the
;   feature was ON: the model submenu's install-probe (_LLM_GetInstalledTagsCached
;   → LLM_OllamaListModels) is a SYNCHRONOUS /api/tags GET, and at boot the daemon
;   is still cold, so it blocked for seconds — stuck menu AND missed
;   prediction-cancel on input. So the boot build is gated to the OFF case (cheap:
;   the probe is skipped when deps aren't ready). When ON, LLM_Menu_BootstrapOllama
;   (armed in LLM_Menu_Init) builds the menu via LLM_Menu_OnDepsReady AFTER Ollama
;   readiness is confirmed asynchronously, so the build never blocks the boot thread.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckLlmTrayDeferredBuild() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	InitFile := WindowsDir . "\ui\menu\menu_llm\init.ahk"
	BootFile := WindowsDir . "\ErgoptiPlus.ahk"

	InitBody := ""
	try InitBody := FileRead(InitFile)
	Assert(InitBody != "", "ui/menu/menu_llm/init.ahk must be readable")

	; LLM_Menu_Init must place the (empty) entry itself. A root rebuild records
	; this insertion in TrayMenuStage_Add and publishes it atomically afterwards.
	Assert(InStr(InitBody, 'TrayMenuStage_Add(t("menu.llm.title"), _LLM_Menu_Handle)') > 0,
		"LLM_Menu_Init must stage the (empty) IA submenu in its canonical tray position")

	; … but must NOT build the menu synchronously — that is what blocked initMenu.
	Assert(!InStr(InitBody, "LLM_Menu_Build("),
		"LLM_Menu_Init must NOT call LLM_Menu_Build() synchronously — the boot tail arms it")

	; The race-prone bridge flag must be GONE: it was set by LLM_Menu_Init (which at
	; boot runs only inside the deferred tray build) but read by the synchronous boot
	; tail that runs FIRST, so it was always false there and the build never armed.
	Assert(!InStr(InitBody, "_LLM_Menu_BuildPending"),
		"LLM_Menu_Init must NOT use the _LLM_Menu_BuildPending flag — arming is now unconditional at the boot tail (the deferred initMenu set the flag too late to gate the build)")

	; The boot tail must arm the deferred build for the OFF case, gated on the feature
	; being disabled — NOT unconditionally (that blocked the boot thread on a cold
	; /api/tags probe when ON) and NOT behind the race-prone _LLM_Menu_BuildPending
	; flag (which was always false here, so the build never armed at all).
	BootBody := ""
	try BootBody := FileRead(BootFile)
	Assert(BootBody != "", "ErgoptiPlus.ahk must be readable")
	Assert(InStr(BootBody, "SetTimer(LLM_Menu_Build, -LLM_MENU_BUILD_DEFER_MS)") > 0,
		"ErgoptiPlus.ahk boot tail must arm the deferred LLM_Menu_Build (for the OFF case)")
	Assert(!InStr(BootBody, "_LLM_Menu_BuildPending"),
		"ErgoptiPlus.ahk must NOT gate the LLM_Menu_Build arming on _LLM_Menu_BuildPending — that flag is set by the deferred initMenu and is still false when this synchronous boot-tail line runs, so the build was never armed when the feature was OFF")
	; The boot build must be gated on the feature being OFF, immediately before the
	; SetTimer — when ON, the menu is built by the async deps-bootstrap path instead,
	; so the boot thread never hits the synchronous /api/tags install-probe.
	GatePos  := InStr(BootBody, 'if !_LLM_Menu["enabled"]')
	ArmPos   := InStr(BootBody, "SetTimer(LLM_Menu_Build, -LLM_MENU_BUILD_DEFER_MS)")
	Assert(GatePos > 0,
		'ErgoptiPlus.ahk must gate the boot IA build on (if !_LLM_Menu["enabled"]) so it never runs the synchronous /api/tags probe at boot when ON')
	Assert(GatePos < ArmPos and (ArmPos - GatePos) < 60,
		'the (if !_LLM_Menu["enabled"]) gate must immediately precede the SetTimer(LLM_Menu_Build ...) arming — the ON path builds via LLM_Menu_BootstrapOllama after async Ollama-readiness, never at boot')
}

Test("meta llm: LLM_Menu_Init defers the IA submenu build", _MetaCheckLlmTrayDeferredBuild)
