; tests/meta/test_onboarding_no_appstate.ahk

; ==============================================================================
; MODULE: Onboarding No-AppState Meta Test
; DESCRIPTION:
; Static source guard for the "_Onboarding_Commit crashes on AppState access"
; finding (onboarding-no-appstate).
;
; _Onboarding_Commit() in infra/onboarding.ahk previously set
; AppState["toml_strict_canon_in_progress"] as its first statement. AppState
; is never defined in production (the Map was deliberately removed from
; infra/app_state.ahk). This throws UnsetError immediately, aborting the entire
; first-run wizard commit: config is never written and the script never
; reloads.
;
; A later plain-global guard avoided AppState but preserved the deeper problem:
; TOML_BatchWrite re-entered SaveFullConfig before onboarding or menu callers
; published their candidates. The low-level writer now renders canonically in
; its single atomic pass and never re-enters live global state, so onboarding
; needs neither AppState nor a canonicalization guard.
;
; These are meta-static tests because the crash occurs at the very first
; statement of the commit path, before any injectable seam is reached.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================================
; =============================================
; ======= 1/ Source scan helpers ==============
; =============================================
; =============================================

; The i18n key each _Onboarding_CommitError call of Body passes as a literal,
; in source order.
; @param Body string Commit source, full-line comments stripped.
; @returns {Array}
_ONA_CommitFailureKeys(Body) {
	Keys := []
	Position := 1
	while (Position := RegExMatch(Body, '_Onboarding_CommitError\(\s*"([a-z_.]+)"\s*\)', &Match, Position)) {
		Keys.Push(Match[1])
		Position += Match.Len
	}
	return Keys
}





; =====================================================
; =====================================================
; ======= 2/ Onboarding commit assertions =============
; =====================================================
; =====================================================

_ONA_CommitDoesNotUseAppState() {
	Seg := _DriverFuncBody("_Onboarding_Commit")
	Assert(Seg != "", "_Onboarding_Commit declaration must exist in the driver source")
	; Any AppState[...] index-assign in this function throws UnsetError in production
	; because the Map was removed from infra/app_state.ahk
	Assert(InStr(Seg, "AppState[") = 0,
		"_Onboarding_Commit must NOT use AppState[...] — AppState is not defined in production and throws UnsetError")
}
Test("onboarding: _Onboarding_Commit does not access AppState (UnsetError crash on first-run wizard)", _ONA_CommitDoesNotUseAppState)

_ONA_CommitPublishesOnlyAfterPersistence() {
        Seg := _DriverFuncBody("_Onboarding_Commit")
        WebFinish := _DriverFuncBody("_OnbWeb_Finish")
		BuildPos := InStr(Seg, "TOML_BuildUpdatedContent(")
		TargetsPos := InStr(Seg, "TargetSpecs := [ConfigTransitionPresentTarget(CandidateConfig")
		LocatorPos := InStr(Seg,
			"TargetSpecs.Push(ConfigTransitionPresentTarget(_PathsFile")
		CommitPos := InStr(Seg, "ConfigTransitionCommitOwned(")
		StrictPos := InStr(Seg,
			'ConfigTransitionResultIs(CommitResult, "committed_new")')
		PublishPos := InStr(Seg, "_ConfigDir := CandidateDir")
		ReloadPos := InStr(Seg,
			"ReloadPreservingSuspend(BeforeReloadFn, OwnerBundle,")
		; One rollback helper serves a refused launch and a later refusal alike.
		RollbackPos := InStr(Seg, "Rollback.Call(OwnerBundle)")
		ReleasePos := InStr(Seg, "_ConfigWriteTerminalRelease(OwnerBundle)")
		Assert(InStr(_DriverFuncBody("_Onboarding_RollbackRefusedReload"),
			"ConfigTransitionRollbackOwned(") > 0,
			"the onboarding rollback helper must restore the committed targets")
		Assert(BuildPos > 0 && TargetsPos > BuildPos && LocatorPos > TargetsPos
			&& CommitPos > LocatorPos && StrictPos > CommitPos,
				"onboarding must render first, declare config before locator, and strictly commit one WAL")
		Assert(PublishPos > StrictPos,
				"onboarding must not publish _ConfigDir before the candidate config write succeeds")
		Assert(ReloadPos > PublishPos,
			"onboarding must retain its transaction until the persisted state is handed directly to Reload")
		Assert(RollbackPos > ReloadPos && ReleasePos > RollbackPos,
			"a refused Reload must restore all-old before releasing the terminal owner")
	Assert(InStr(Seg, "_TOML_STRICT_CANON_IN_PROGRESS") = 0,
		"onboarding must not carry a stale canonicalization workaround after the batch writer stopped re-entering SaveFullConfig")
	Assert(InStr(Seg, "FileOpen(") == 0 && InStr(Seg, "FSMove(") == 0,
		"onboarding must not publish config or locator outside the transition WAL")
		Assert(RegExMatch(WebFinish, "_Onboarding_Commit\([^\r\n]*, _OnbWeb_Reset\)") > 0,
				"WebView onboarding must retain its retry UI until the owned reload hand-off accepts")
}
Test("onboarding: commit persists transactionally before publishing or reloading", _ONA_CommitPublishesOnlyAfterPersistence)

; Commit failures can happen before the process-wide locale cache is initialized
; on first boot. Every branch therefore passes a key and the display helper
; resolves it against the locale selected inside the wizard itself.
_ONA_CommitErrorsUseSelectedLocale() {
	; The refused-reload branch lives in the rollback helper both refusal paths
	; share, so the enumerated class spans the commit and that helper.
	CommitBody := _StripFullLineComments(_DriverFuncBody("_Onboarding_Commit"))
		. _StripFullLineComments(
			_DriverFuncBody("_Onboarding_RollbackRefusedReload"))
	ErrorBody := _StripFullLineComments(
		_DriverFuncBody("_Onboarding_ShowError"))
	Assert(InStr(_DriverFuncBody("_Onboarding_CommitError"), "_Onboarding_ShowError(Key)") > 0,
		"commit failures must be shown by the one renderer that follows the wizard's language")
	Assert(CommitBody != "" && ErrorBody != "",
		"onboarding commit and its error renderer must remain source-visible")
	; A count alone let a new branch in unnoticed, or one showing an untranslated
	; string; each branch is named here by the key it shows, in source order.
	RegExReplace(CommitBody, "_Onboarding_CommitError\(", "",
		&ErrorCallCount)
	Keys := _ONA_CommitFailureKeys(CommitBody)
	AssertEqual(ErrorCallCount, Keys.Length,
		"every onboarding commit failure must pass a literal i18n key the wizard's language resolves")
	Listed := ""
	for Key in Keys
		Listed .= Key . "`n"
	; The render and source checks run twice: for config.toml, then for the
	; tap_hold.toml the Tap-Holds page imports into in the same transition.
	AssertEqual("onboarding.error.commit_invalid_config_dir`n"
		. "onboarding.error.commit_transaction_busy`n"
		. "onboarding.error.commit_candidate_render`n"
		. "onboarding.error.commit_source_verification`n"
		. "onboarding.error.commit_candidate_render`n"
		. "onboarding.error.commit_source_verification`n"
		. "onboarding.error.commit_redirect_render`n"
		. "onboarding.error.commit_transition`n"
		. "onboarding.error.commit_unexpected`n"
		. "onboarding.error.commit_rollback`n",
		Listed, "the complete onboarding commit failure class must remain enumerated, branch by branch")
	Assert(InStr(ErrorBody, "IsSet(_ob_locale)") > 0
		&& InStr(ErrorBody, '_Onboarding_Translate(Code, Key)') > 0
		&& InStr(ErrorBody,
			'_Onboarding_Translate(Code, "onboarding.error.title")') > 0,
		"the message and title must resolve in the wizard-selected locale with a safe first-boot fallback")
	Assert(InStr(ErrorBody, "MsgBox(Message, Title") > 0,
		"the renderer must display only translated values")
}
Test("onboarding: all commit errors use the selected locale "
	. "(onboarding-commit-error-i18n)",
	_ONA_CommitErrorsUseSelectedLocale)





; ============================================================
; ============================================================
; ======= 3/ TOML writer re-entrancy assertion ================
; ============================================================
; ============================================================

_ONA_BatchWriterDoesNotReenterFullSave() {
	Seg := _DriverFuncBody("TOML_BatchWrite")
	Assert(Seg != "", "TOML_BatchWrite declaration must exist in infra/toml/toml_helpers.ahk")
	Assert(InStr(Seg, "SaveFullConfig") = 0
		and InStr(Seg, "TOML_RunStrictCanonicalization") = 0,
		"the low-level batch writer must not re-enter a full save from stale caller globals")
	Assert(InStr(Seg, "AppState.Has") = 0 and InStr(Seg, "AppState[") = 0,
		"the batch writer must not depend on the removed AppState Map")
}
Test("toml_helpers: batch writes never re-enter stale full-config state",
	_ONA_BatchWriterDoesNotReenterFullSave)
