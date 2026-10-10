; tests/meta/test_tray_bootstrap_publication_transaction.ahk

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
		"RebuildTrayMenu(0, _LLM_Menu_PublishRoot, true, true)") > 0
		&& InStr(LlmBuild, "A_TrayMenu.Add") == 0,
		"the LLM builder must submit its detached child to the root coordinator and never publish an IA-only root")
}

Test("tray bootstrap: cold publication stays non-empty, truthful, and root-owned (ahk-009-tray-bootstrap-publication)",
	_TBPT_ColdRootHasOneTruthfulOwner)

_TBPI_CompiledAuthorityPrecedesPublication() {
	global _SharedDir
	Source := _DriverSourceNoComments()
	Assert(InStr(Source, "#Include ../../_shared/modules/menu/startup_tray_projection.ahk") > 0,
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
	Assert(InStr(Projected, "SharedStartupTrayProjection(_I18nLocale)") > 0,
		"the original locale owner selects the genuine compiled shared projection")
	Assert(InStr(Projected, "MenuStartupSafeCommand") > 0,
		"canonical command records retain the existing native capability class")
	Assert(InStr(Projected, "_DriverReady :=") == 0 && InStr(Projected, "_DriverMenuReady :=") == 0,
		"emergency source authority cannot grant configuration/input readiness")
}

Test("startup immutable authority: genuine compiled include and source admission precede native publication", _TBPI_CompiledAuthorityPrecedesPublication)
