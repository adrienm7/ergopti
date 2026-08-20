; tests/meta/test_config_failures_are_surfaced.ahk

; ==============================================================================
; MODULE: Config-Write Failure Surfacing Meta Test
; DESCRIPTION:
; Four places in infra/config_io.ahk where an operation the user explicitly asked
; for could fail, or decline to run, without saying anything.
;
; ReloadWithDefaultConfig was the worst of them. Its delete loop sat in a bare
; try, so a config.toml held by an editor or a cloud-sync client survived — and
; the FSAppend afterwards then APPENDED a second [_meta] section to the file it
; had failed to delete. "Reset to defaults" produced neither a reset nor an
; error, and left the config in a state it had never been in. FSAppend also
; REPORTS failure by return value rather than throwing, and that return was
; discarded, so the guarantee its own comment promises (the wizard is skipped on
; reload) could quietly not hold.
;
; The other three are drifted twins: one copy of a pair learned to report and
; the other did not. ReadScriptShortcutsConfig fell back silently where its
; keyboard twin logs — and the keyboard twin carries a comment explaining that
; falling back silently is wrong. HS_TogglePersonalAllSections returned bare
; where its sibling ToggleCategoryAllSections warns. _GlobalClearAllBindings
; swallowed the one write that disables tap-holds, so "tout desactiver" could
; report success while they stayed enabled on disk.
;
; SCOPE: source introspection of infra/config_io.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================================
; ===============================================
; ======= 1/ Reset to defaults fails loud =======
; ===============================================
; ===============================================

_CFAS_ResetReportsUndeletedFiles() {
	Body := _DriverFuncBody("ReloadWithDefaultConfig")
	NoticeBody := _DriverFuncBody("_ConfigResetShowFailure")
	Assert(Body != "" && NoticeBody != "",
		"ReloadWithDefaultConfig() and its refusal presenter must exist")
	AcquirePos := InStr(Body, "ConfigTransitionAcquireLifecycleBundle(")
	QuiescePos := InStr(Body, "LLM_Menu_QuiesceTriggerForLifecycle(")
	BuildPos := InStr(Body, "_ConfigResetTransitionTargets(")
	CommitPos := InStr(Body, "ConfigTransitionCommitOwned(")
	StrictPos := InStr(Body,
		'ConfigTransitionResultIs(CommitResult, "committed_new")')
	ReloadPos := InStr(Body, "ReloadPreservingSuspend(0, OwnerBundle)")
	RollbackPos := InStr(Body, "ConfigTransitionRollbackOwned(")
	ReleasePos := InStr(Body, "_ConfigWriteTerminalRelease(OwnerBundle)")
	Assert(AcquirePos > 0 && QuiescePos > AcquirePos && BuildPos > QuiescePos
		&& CommitPos > BuildPos && StrictPos > CommitPos && ReloadPos > StrictPos
		&& RollbackPos > ReloadPos && ReleasePos > RollbackPos,
		"reset must hold one terminal owner from quiescence through strict commit, Reload, rollback, then release")
	Assert(InStr(Body, "ConfigTransitionLogFailure") > 0
		&& InStr(Body, "_ConfigResetShowFailure(") > 0
		&& InStr(NoticeBody, "MsgBox(") > 0
		&& InStr(Body, "return false") > 0,
		"a refused reset transition must be logged, shown, and abort before Reload")
	Assert(InStr(Body, "FileDelete(") == 0 && InStr(Body, "FSAppend(") == 0,
		"reset must not bypass its WAL with raw delete/append operations")
}

; FSAppend signals failure by return value, not by throwing, so ignoring it is
; the same as swallowing an exception.
_CFAS_PlaceholderWriteIsChecked() {
	Helper := _DriverFuncBody("_ConfigResetTransitionTargets")
	Body := _DriverFuncBody("ReloadWithDefaultConfig")
	Assert(Helper != "" && Body != "")
	Assert(InStr(Helper, "ConfigTransitionPresentTarget(ConfigPath") > 0
		&& InStr(Helper, "[_meta]") > 0
		&& InStr(Helper, "schema_version = 2") > 0,
		"the reset transaction must declare one complete valid placeholder image")
	Assert(InStr(Helper, "ConfigTransitionAbsentTarget(TapHoldPath)") > 0
		&& InStr(Helper, "ConfigTransitionAbsentTarget(ApiEntriesPath)") > 0,
		"the sibling deletes must be intentions in the same WAL")
	Assert(InStr(Body,
		'ConfigTransitionResultIs(CommitResult, "committed_new")') > 0,
		"the complete three-target result must be checked before Reload")
}

; Every refusal branch must explain the operation that failed. The shared
; template still owns the sentence structure, while typed results contribute
; their exact status/kind instead of inheriting the old deletion-only text.
_CFAS_ResetFailureMessagesCarryPreciseReasons() {
	Body := _StripFullLineComments(_DriverFuncBody("ReloadWithDefaultConfig"))
	Helper := _StripFullLineComments(
		_DriverFuncBody("_ConfigResetShowFailure"))
	Assert(Body != "" && Helper != "",
		"reset and its localized failure helper must remain source-visible")
	RegExReplace(Body, "_ConfigResetShowFailure\(", "", &FailureCallCount)
	AssertEqual(6, FailureCallCount,
		"the complete reset refusal class must remain enumerated")
	for Key in [
		"dialog.reset_defaults.reason.acquire",
		"dialog.reset_defaults.reason.trigger_recovery",
		"dialog.reset_defaults.reason.trigger_journal",
		"dialog.reset_defaults.reason.commit",
		"dialog.reset_defaults.reason.reload_refused",
		"dialog.reset_defaults.reason.rollback"
	] {
		Assert(InStr(Body, Key) > 0,
			"every reset refusal branch must pass its precise reason key: " . Key)
	}
	Assert(InStr(Body, 'MsgBox(t("dialog.reset_defaults.failed")') == 0,
		"reset branches must not display the unformatted placeholder directly")
	Assert(InStr(Helper,
		'Format(t("dialog.reset_defaults.failed"), Reason)') > 0,
		"the shared reset template must always receive the localized reason")
	Assert(InStr(Helper, 'Result.Has("status")') > 0
		&& InStr(Helper, 'Result.Has("kind")') > 0
		&& InStr(Helper, "Format(Reason, Status, Kind)") > 0,
		"typed transition refusals must preserve their exact status/kind")
}




; =================================================
; =================================================
; ======= 2/ Drifted twins both report now ========
; =================================================
; =================================================

; Both shortcut readers must report an unresolvable persisted action. They are
; the same logic in two copies, and only one of them had learned to.
_CFAS_BothShortcutReadersReport() {
	for Name in ["ReadKeyboardShortcutsConfig", "ReadScriptShortcutsConfig"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist")
		Assert(InStr(Body, "LoggerWarn") > 0,
			Name . " must report an unresolvable persisted action — the slot keeps its compiled-in default, so the key fires a DIFFERENT action than the one configured, with nothing to explain it")
	}
}

; Both "toggle all sections" entry points must explain a refusal to act.
_CFAS_BothSectionTogglesReport() {
	for Name in ["HS_TogglePersonalAllSections", "ToggleCategoryAllSections"] {
		Body := _DriverFuncBody(Name)
		if (Body == "")
			continue
		Assert(InStr(Body, "Logger") > 0,
			Name . " must log when it declines to act — a menu item that does nothing and says nothing is indistinguishable from one that is broken")
	}
}

; The bulk toggle now owns only the config.toml master gate. The standalone
; destructive action still owns tap_hold.toml, so its false result must abort
; before the detached candidate reaches live state
_CFAS_TapHoldDisableIsNotSwallowed() {
	Body := _DriverFuncBody("_TH_WriteTapHoldDisabled")
	Assert(Body != "", "_TH_WriteTapHoldDisabled() must exist")

	Assert(InStr(Body, "_TH_CommitTapHoldMutation(") > 0,
		"the standalone disable must consume the shared admitted transaction result")
	Assert(InStr(Body, "TapHold :=") == 0,
		"the standalone disable must not publish live state outside the shared transaction")
	CommitBody := _DriverFuncBody("_TH_CommitTapHoldMutation")
	WriterBody := _DriverFuncBody("_TH_WriteTapHoldToml")
	Publisher := _DriverFuncBody("_TH_PublishTapHoldCandidate")
	Assert(CommitBody != "" && WriterBody != "" && Publisher != "")
	Assert(InStr(CommitBody, "Result := _TH_WriteTapHoldToml(Candidate") > 0,
		"the transaction result must be retained through owner release")
	Assert(InStr(WriterBody, "if !Written") > 0
		&& InStr(WriterBody, "if !Replaced") > 0
		&& InStr(WriterBody, "if !Published") > 0,
		"every non-throwing persistence refusal must abort explicitly")
	Assert(InStr(Publisher, "TapHold := Candidate") > 0,
		"only the post-replacement publisher may swap live TapHold")
}


Test("meta config: a failed reset reports and aborts before the placeholder write",
	_CFAS_ResetReportsUndeletedFiles)
Test("meta config: the placeholder write's return value is checked",
	_CFAS_PlaceholderWriteIsChecked)
Test("meta config: every reset refusal formats its precise transaction reason "
	. "(reset-failure-reason-i18n)",
	_CFAS_ResetFailureMessagesCarryPreciseReasons)
Test("meta config: both shortcut readers report an unresolvable action",
	_CFAS_BothShortcutReadersReport)
Test("meta config: both section toggles explain a refusal to act",
	_CFAS_BothSectionTogglesReport)
Test("meta config: the tap-hold disable failure is not swallowed",
	_CFAS_TapHoldDisableIsNotSwallowed)

; A boolean-returning write failure must be detected BEFORE any candidate is
; published. Reload is not recovery: it is itself a side effect and cannot be
; used to hide a mutation that never committed.
_CFAS_BulkTogglesRecoverFromAFailedWrite() {
	for Name in ["ToggleAllFeatures", "ToggleCategoryAllFeatures"] {
		Body := _StripFullLineComments(_DriverFuncBody(Name))
		Assert(Body != "", Name . "() must exist")
		PersistPos := InStr(Body, "ConfigCommitUpdates(")
		PublishPos := InStr(Body, "Features := CandidateFeatures")
		ReloadPos := InStr(Body, "ReloadPreservingSuspend()")
		Assert(PersistPos > 0 and InStr(Body, "if !ConfigCommitUpdates(") > 0,
			Name . " must test the non-throwing persistence result")
		Assert(PublishPos == 0 or PublishPos > PersistPos,
			Name . " must publish detached state only after persistence succeeds")
		Assert(ReloadPos == 0 or ReloadPos > PersistPos,
			Name . " must never reload on the failed-commit branch")
	}
}
Test("meta config: a bulk toggle recovers when its write fails",
	_CFAS_BulkTogglesRecoverFromAFailedWrite)

; Three latent defects, each an inconsistency between two things that must
; agree. None has a caller that reaches it today, which is precisely why they
; would have surfaced as a puzzle rather than a regression.
_CFAS_LatentContractsAreConsistent() {
	; _HSCategorySnapshot is declared in ErgoptiPlus.ahk, not in infra/, so the
	; headless harness does not load it. Guarding one global of a pair and not
	; the other means the unguarded read throws before the guard can apply.
	Body := _DriverFuncBody("_HSRestoreCategory")
	Assert(Body != "", "_HSRestoreCategory() must exist")
	Assert(InStr(Body, "IsSet(_HSCategorySnapshot)") > 0,
		"_HSRestoreCategory must IsSet-guard _HSCategorySnapshot as well as Features — it is declared outside infra/, so reading it first throws under the headless harness")

	; AltGr is Ctrl + right Alt. Without its own case it fell through to the
	; default and returned "", dropping the modifier from the sent keystroke.
	Prefix := _DriverFuncBody("_TextSenderModifierPrefix")
	Assert(Prefix != "", "_TextSenderModifierPrefix() must exist")
	Assert(InStr(Prefix, '"altgr"') > 0,
		"the modifier-prefix map must handle altgr — the sibling name map normalises to it, and without a case here it silently returns an empty prefix")

	; Every other path in this function returns a boolean, so a bare return
	; would make a legitimate zero-count call read as a failure.
	Erase := _DriverFuncBody("TextEraseChars")
	Assert(Erase != "", "TextEraseChars() must exist")
	Assert(RegExMatch(Erase, "Count\s*<\s*1\s*\r?\n\s*return\s+true") > 0,
		"TextEraseChars must return true when asked to erase nothing — erasing zero characters succeeded, and a bare return yields the empty string against a boolean contract")
}
Test("meta contracts: three latent inconsistencies stay fixed",
	_CFAS_LatentContractsAreConsistent)
