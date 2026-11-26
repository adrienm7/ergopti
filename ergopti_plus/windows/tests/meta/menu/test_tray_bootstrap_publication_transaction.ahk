; tests/meta/menu/test_tray_bootstrap_publication_transaction.ahk

; ==============================================================================
; MODULE: Cold Tray Bootstrap Publication Transaction
; DESCRIPTION:
; AHK-009 regression guard. The stock tray must be replaced before the blocking
; onboarding pump, and the post-i18n cold root must keep genuine native commands
; without a temporary loading surface until the coordinator publishes the tree.
; The LLM builder owns only a detached child and may never create an IA-only
; live root. Source order is required here because these statements execute in
; include order before the driver publishes ready; runtime unit tests cannot
; safely load the full auto-execute entrypoint.
; ==============================================================================

#Requires AutoHotkey v2.0

_TBPT_ColdRootHasOneTruthfulOwner() {
	Source := _DriverSourceNoComments()
	Assert(Source != "", "the concatenated production source must be readable")

	FirstBootstrap := InStr(Source, "_InstallSafeBootstrapTray()")
	Onboarding := InStr(Source, "Onboarding_Run()", , FirstBootstrap)
	I18nReady := InStr(Source, "I18nInit(", , Onboarding)
	LocalizedBootstrap := InStr(Source,
		'_InstallNativeStartupTray(ObjBindMethod(_TrayStartupCommands, "Request"))', , Max(1, I18nReady))
	Ready := InStr(Source, '_DriverBootPhase := "ready"', , Max(1, LocalizedBootstrap))

	Assert(FirstBootstrap > 0 && Onboarding > FirstBootstrap,
		"stock actions must be replaced immediately by a safe bootstrap before the blocking onboarding pump")
	Assert(I18nReady > Onboarding && LocalizedBootstrap > I18nReady
		&& Ready > LocalizedBootstrap,
		"after i18n is ready, genuine native commands must remain available before input readiness")
	Assert(InStr(Source, "TrayStartupPanel(") == 0,
		"a loading window must never replace the native startup menu")

	Bootstrap := _DriverFuncBody("_InstallSafeBootstrapTray")
	Assert(Bootstrap != "", "the bootstrap publication helper must remain source-visible")
	CriticalPos := InStr(Bootstrap, 'Critical("On")')
	DeletePos := InStr(Bootstrap, "MenuObj.Delete()")
	AddPos := InStr(Bootstrap, "MenuObj.Add(")
	DisablePos := InStr(Bootstrap, "MenuObj.Disable(")
	Assert(CriticalPos > 0 && DeletePos > CriticalPos && AddPos > DeletePos
		&& DisablePos > AddPos,
		"Delete, Add, and Disable must belong to one critical bootstrap publication transaction")

	LlmBuild := _DriverFuncBody("LLM_Menu_Build")
	Assert(LlmBuild != "", "LLM_Menu_Build must remain source-visible")
	Assert(InStr(LlmBuild,
		"RebuildTrayMenu(0, _LLM_Menu_PublishRoot.Bind(StagedHandle), true, true, StagedHandle)") > 0
		&& InStr(LlmBuild, "A_TrayMenu.Add") == 0,
		"the LLM builder must submit its detached child to the root coordinator and never publish an IA-only root")
}

Test("tray bootstrap: cold publication stays non-empty, truthful, and root-owned (ahk-009-tray-bootstrap-publication)",
	_TBPT_ColdRootHasOneTruthfulOwner)

_TBPI_CompiledAuthorityPrecedesPublication() {
	global _SharedDir
	Source := _DriverSourceNoComments()
	Assert(InStr(Source, "#Include ../../_shared/menu/data/startup_tray_projection.ahk") > 0,
		"the actual native helper must include the genuine generated shared owner")
	ProjectionPath := _DriverProductionFileForSymbol("SharedStartupTrayProjection", _SharedDir)
	Projection := _StripFullLineComments(FileRead(ProjectionPath, "UTF-8"))
	Assert(Projection != "" && InStr(Projection, "SharedStartupTrayProjection(Locale)") > 0,
		"the actual included generated shared owner must be readable and executable")
	for Name in ["_InstallNativeStartupTray", "_InstallSafeBootstrapTray"] {
		Body := _DriverFuncBody(Name)
		Projected := InStr(Body, "_TrayBootstrapProjectedRows(")
		CriticalPos := InStr(Body, 'Critical("On")')
		Assert(Projected > 0 && CriticalPos > Projected,
			"genuine immutable source admission must finish before native retirement")
		Assert(InStr(Body, "_MM_GetManifestRoot(") == 0,
			"startup must not infer emergency authority from the live loader's conflated false result")
	}
	Projected := _DriverFuncBody("_TrayBootstrapProjectedRows")
	Assert(InStr(Projected, "SharedStartupTrayProjection(Locale)") > 0
		&& InStr(Projected, "Locale := _I18nLocale") > 0,
		"the active locale owner, or an explicit one, selects the genuine compiled shared projection")
	Assert(InStr(Projected, "MenuStartupSafeCommand") > 0,
		"canonical command records retain the existing native capability class")
	Assert(InStr(Projected, "_DriverReady :=") == 0 && InStr(Projected, "_DriverMenuReady :=") == 0,
		"emergency source authority cannot grant configuration/input readiness")
}

Test("startup immutable authority: genuine compiled include and source admission precede native publication", _TBPI_CompiledAuthorityPrecedesPublication)

; TRAY-01: the cold tray once appeared before I18nInit, so every user of
; another language saw French startup rows (_I18nLocale still held the module
; default) and heard the script's file name as the icon's name. The Linux daemon
; had the same order bug (test_i18n_is_ready_before_the_tray.lua). Source order,
; because these statements run in include order in the auto-execute section.
_TBPT_ColdTrayAppearsLocalizedAndNamed() {
	Source := _DriverSourceNoComments()
	I18nReady := InStr(Source, "I18nInit(_IniCache)")
	FirstNative := InStr(Source, '_InstallNativeStartupTray(ObjBindMethod(_TrayStartupCommands, "Request"))')
	Assert(I18nReady > 0 && FirstNative > I18nReady,
		"the native startup commands are projected only once the configured locale is read")
	Assert(InStr(Source, '_InstallNativeStartupTray(ObjBindMethod(_TrayStartupCommands, "Request"))', ,
		FirstNative + 1) == 0, "the localized startup commands are published once")
	Reveal := _DriverFuncBody("_DriverRevealTrayIcon")
	Assert(InStr(Reveal, "A_IconHidden := false") > 0, "one owner reveals the tray icon")
	Normal := InStr(Source, "TrayRevealNamed(TrayStateTipText(A_IsSuspended), _DriverRevealTrayIcon)")
	Assert(Normal > FirstNative, "a normal boot names its icon in the configured locale, then shows it")
	FirstRun := InStr(Source, "_InstallSafeBootstrapTray(TrayBootstrapInertLabel(ONBOARDING_FIRST_RUN_LOCALE))")
	Onboarding := InStr(Source, "Onboarding_Run()", , Max(1, FirstRun))
	Assert(FirstRun > 0 && Onboarding > FirstRun && FirstRun < I18nReady,
		"a first run shows its icon before the wizard, in the wizard's language")
	Assert(InStr(Source, 'TrayRevealNamed(_Onboarding_Translate(ONBOARDING_FIRST_RUN_LOCALE, "accessibility.tray_tip"),',
		, FirstRun) > FirstRun, "a first run names its icon before showing it")
	Position := 1, Uses := 0
	while Position := InStr(Source, "_DriverRevealTrayIcon", , Position) {
		Uses += 1
		Position += 1
	}
	Assert(Uses == 3, "the reveal owner is defined once and used by the two named reveals, found " . Uses)
}

Test("tray bootstrap: the cold tray appears in the configured locale, named (tray-01-2026-11-20)",
	_TBPT_ColdTrayAppearsLocalizedAndNamed)
