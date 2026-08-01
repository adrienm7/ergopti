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
	Assert(Body != "", "ReloadWithDefaultConfig() must exist")

	Assert(InStr(Body, "catch as") > 0,
		"the delete loop must catch explicitly — a bare try turns a locked or read-only config into a silent no-op")
	Assert(InStr(Body, "LoggerError") > 0,
		"a file that could not be deleted must be reported")

	; Aborting matters more than logging here: continuing to the FSAppend after a
	; failed delete is what appends a SECOND [_meta] section to the surviving
	; config, leaving it in a state the user never chose.
	AbortPos := InStr(Body, "return")
	AppendPos := InStr(Body, "FSAppend(")
	Assert(AbortPos > 0 and AppendPos > 0, "prerequisite: both the abort and the placeholder write must exist")
	Assert(AbortPos < AppendPos,
		"a failed delete must return BEFORE the placeholder write — otherwise the append lands on the file that was not deleted and duplicates its [_meta] section")
}

; FSAppend signals failure by return value, not by throwing, so ignoring it is
; the same as swallowing an exception.
_CFAS_PlaceholderWriteIsChecked() {
	Body := _DriverFuncBody("ReloadWithDefaultConfig")
	Assert(Body != "", "ReloadWithDefaultConfig() must exist")
	Assert(RegExMatch(Body, "if\s*!FSAppend\(") > 0,
		"the placeholder write's return value must be checked — FSAppend reports failure rather than throwing, so an ignored return means the promise that the wizard is skipped can silently not hold")
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

; The tap-hold disable is the only write that turns tap-holds off. Swallowing it
; lets "tout desactiver" report success over a config that still says enabled.
_CFAS_TapHoldDisableIsNotSwallowed() {
	Body := _DriverFuncBody("_GlobalClearAllBindings")
	Assert(Body != "", "_GlobalClearAllBindings() must exist")

	ThPos := InStr(Body, "_TH_WriteTapHoldDisabled")
	Assert(ThPos > 0, "the tap-hold disable must still be attempted")
	Tail := SubStr(Body, ThPos)
	Assert(InStr(Tail, "catch as") > 0 and InStr(Tail, "LoggerError") > 0,
		"a failed tap-hold disable must be caught and reported — otherwise the bulk disable claims success while tap-holds remain enabled on disk")
}


Test("meta config: a failed reset reports and aborts before the placeholder write",
	_CFAS_ResetReportsUndeletedFiles)
Test("meta config: the placeholder write's return value is checked",
	_CFAS_PlaceholderWriteIsChecked)
Test("meta config: both shortcut readers report an unresolvable action",
	_CFAS_BothShortcutReadersReport)
Test("meta config: both section toggles explain a refusal to act",
	_CFAS_BothSectionTogglesReport)
Test("meta config: the tap-hold disable failure is not swallowed",
	_CFAS_TapHoldDisableIsNotSwallowed)

; A bulk toggle mutates Features, CategoryEnabled and the WPMWidget fields in
; MEMORY before it persists. If the write throws — the same locked or read-only
; trigger as the reset path — memory and disk disagree, and the trailing Reload
; that would have resynced them is skipped, so the tray goes on rendering a
; state that was never saved. On the live-category path the engine rebuild is
; skipped too, leaving memory, disk and the hotstring engine in three different
; states.
_CFAS_BulkTogglesRecoverFromAFailedWrite() {
	for Name in ["ToggleAllFeatures", "ToggleCategoryAllFeatures"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist")

		Assert(InStr(Body, "catch as") > 0,
			Name . " must catch a failed persist — the in-memory flip has already happened by then, so an uncaught throw leaves memory and disk disagreeing")
		Assert(InStr(Body, "LoggerError") > 0,
			Name . " must report a failed persist")

		; Reload is the recovery: it re-reads the config from disk and therefore
		; discards the unpersisted flip. Without it the driver keeps running on
		; state the user never saved.
		CatchPos := InStr(Body, "catch as")
		Recovery := SubStr(Body, CatchPos, 700)
		Assert(InStr(Recovery, "Reload") > 0,
			Name . " must Reload after a failed persist — re-reading disk is what discards the unpersisted mutation and puts the driver back in a state that matches what was saved")
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
