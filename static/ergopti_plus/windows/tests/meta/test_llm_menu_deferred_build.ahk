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
;   no enable toggle, no way to turn the feature back on. THE FIX: arm the owned
;   LLM request from the successful deferred root-build owner (the module is
;   always loaded) and drop the race-prone flag entirely.
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
;
; FOURTH REGRESSION (LLM timer invalidates the boot root generation):
;   The independent 200 ms LLM timer preempted the 16 ms deferred root worker on
;   every measured boot. Its nested RebuildTrayMenu request replaced the boot
;   worker, discarded the staged root, and forced a second InitSubMenus scan.
;   The boot finalizer never ran and 354-604 ms of filesystem/menu work was
;   repeated. The LLM request must be armed only after the boot root publishes.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckLlmTrayDeferredBuild() {
	InitBody := _DriverFuncBody("LLM_Menu_Init")
	Assert(InitBody != "", "LLM_Menu_Init must be readable")

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
		"LLM_Menu_Init must NOT use the _LLM_Menu_BuildPending flag — the published root owner reads restored state directly")

	; The successful deferred root owner must arm the LLM request for the OFF case.
	; An independent boot-tail timer can preempt and invalidate that root generation.
	DriverBody := _DriverSourceConcat()
	Assert(DriverBody != "", "driver source must be readable")
	BootWorkerBody := _DriverFuncBody("_TrayRootBuildBoot")
	Assert(BootWorkerBody != "", "_TrayRootBuildBoot must remain source-visible")
	RootPos := InStr(BootWorkerBody, "initMenu(PublishAuthorizeFn)")
	ArmPos := InStr(BootWorkerBody,
		"_TrayRootScheduleBootProjectionIfDisabled(")
	Assert(RootPos > 0 && ArmPos > RootPos,
		"the boot worker must arm the LLM request only after its root publishes")
	Assert(!InStr(DriverBody, "_LLM_Menu_BuildPending"),
		"the driver must not restore the race-prone _LLM_Menu_BuildPending bridge")
	; When ON, async dependency readiness remains the only build owner.
	EnabledPos := InStr(BootWorkerBody, '_LLM_Menu["enabled"]', false,
		ArmPos)
	RequestPos := InStr(BootWorkerBody,
		'LLM_Menu_RequestBuild.Bind("boot")', false, ArmPos)
	Assert(EnabledPos > ArmPos && RequestPos > EnabledPos,
		"_TrayRootBuildBoot must pass restored LLM enabled state and the owned boot request to the scheduler gate")
}

Test("meta llm: LLM_Menu_Init defers the IA submenu build", _MetaCheckLlmTrayDeferredBuild)
