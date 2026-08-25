; tests/meta/test_tray_bootstrap_publication_transaction.ahk

; ==============================================================================
; MODULE: Cold Tray Bootstrap Publication Transaction
; DESCRIPTION:
; AHK-009 regression guard. The stock tray must be replaced before the blocking
; onboarding pump, and the post-i18n cold root must truthfully say that startup
; is still in progress until the root coordinator publishes one complete tree.
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
		'_InstallSafeBootstrapTray(t("menu.global.starting"))', , Max(1, I18nReady))
	Ready := InStr(Source, '_DriverBootPhase := "ready"', , Max(1, LocalizedBootstrap))

	Assert(FirstBootstrap > 0 && Onboarding > FirstBootstrap,
		"stock actions must be replaced immediately by a safe bootstrap before the blocking onboarding pump")
	Assert(I18nReady > Onboarding && LocalizedBootstrap > I18nReady
		&& Ready > LocalizedBootstrap,
		"after i18n is ready, the cold root must publish a localized Starting status before the driver advertises ready")

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
