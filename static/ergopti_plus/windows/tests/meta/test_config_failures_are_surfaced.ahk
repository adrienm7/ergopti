; tests/meta/test_config_failures_are_surfaced.ahk

; ==============================================================================
; MODULE: Config-Write Failure Surfacing Meta Test
; DESCRIPTION:
; Four places in lib/config_io.ahk where an operation the user explicitly asked
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
; SCOPE: source introspection of lib/config_io.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================
; ===============================================
; ======= 1/ Reset to defaults fails loud =======
; ===============================================
; ==============================================

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
