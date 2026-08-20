; tests/meta/test_onboarding_effective_config_dir.ahk

; ==============================================================================
; MODULE: Regression — the wizard must act on the folder the user just chose
; DESCRIPTION:
; _ob_config_dir holds the folder chosen on the config-folder step. _ConfigDir
; still holds the BOOT value until the commit succeeds, deliberately so — the
; published state must not move before persistence does. Two places read the
; wrong one of the pair.
;
; ROOT CAUSE ENCODED:
;
; 1. CLEARING THE FIELD WAS A NO-OP. _StepConfigDir_Next stores "" and its own
;    comment states this means "use the OS default" and that "the commit step
;    will write a commented-out line to paths.toml so the boot resolver picks
;    the default again". _Onboarding_Commit did no such thing: the empty string
;    failed its `!= ""` test, the redirect block was skipped wholesale, and
;    paths.toml was left pointing at the old custom folder. A user moving back
;    to the default location got a successful-looking commit, a normal Reload,
;    and their config written straight back into the folder they asked to
;    leave. Nothing was logged on that branch.
;
; 2. THE PRIVACY WARNING NAMED THE WRONG FOLDER. The keystroke-logging consent
;    text on the metrics step was built from _ConfigDir, so a user who had just
;    picked a new folder consented to logging while being shown a path that
;    keystrokes would never be written to. Consent shown against the wrong
;    location is the one string on this page that has to be right.
;
; Both are policed here as one class — "resolve the EFFECTIVE directory, not
; the boot one" — because they are the same mistake in two places and a third
; site would make it again.
;
; The fix must not disturb the deliberate ordering pinned by
; tests/meta/test_onboarding_no_appstate.ahk: _ConfigDir is published only
; AFTER the config has been persisted.
;
; SCOPE: source introspection of ui/onboarding.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================================
; ============================================================
; ======= 1/ Clearing the field reverts to the default =======
; ============================================================
; ============================================================

_OEC_EmptyChoiceRevertsToTheDefault() {
	Body := _DriverFuncBody("_Onboarding_Commit")
	Assert(Body != "", "_Onboarding_Commit() must exist")
	; Assert on the assignment, not on the mere mention: _DefaultConfigDir
	; already appears in this function's `global` line, so a name check alone
	; would pass without a single line of the behaviour being present.
	Assert(InStr(Body, "CandidateDir := _DefaultConfigDir") > 0,
		"_Onboarding_Commit must handle the empty choice by targeting _DefaultConfigDir — an empty field means `use the OS default`, and skipping the redirect block instead leaves paths.toml pointing at the folder the user asked to leave")

	; The redirect must actually be requested, or paths.toml is never rewritten
	; and the old ConfigDirPath survives the whole flow.
	Assert(InStr(Body, "PathRedirectRequired := true") > 0,
		"the empty-choice branch must still request the paths.toml rewrite")
}

; The published directory must move only after persistence — the ordering
; test_onboarding_no_appstate.ahk pins. Checked here too so a fix for the
; empty-choice case cannot quietly reorder it.
_OEC_PublishStillFollowsPersistence() {
	Body := _DriverFuncBody("_Onboarding_Commit")
	Assert(Body != "", "_Onboarding_Commit() must exist")
	BuildPos := InStr(Body, "TOML_BuildUpdatedContent(")
	CommitPos := InStr(Body, "ConfigTransitionCommitOwned(")
	StrictPos := InStr(Body,
		'ConfigTransitionResultIs(CommitResult, "committed_new")')
	PublishPos := InStr(Body, "_ConfigDir := CandidateDir")
	Assert(BuildPos > 0 && CommitPos > BuildPos && StrictPos > CommitPos
		&& PublishPos > StrictPos,
		"the commit must render, durably commit, verify, then publish the directory")
	Assert(CommitPos < PublishPos,
		"_ConfigDir must be published only AFTER the config has been persisted — moving it earlier would leave the driver pointing at a folder whose config was never written")
}





; ===========================================================
; ===========================================================
; ======= 2/ The consent text names the chosen folder =======
; ===========================================================
; ===========================================================

; Policed across both hosts: the native step and the WebView2 payload build the
; same warning from the same pair of globals, and only one of them was wrong at
; a time. Reading _ConfigDir here is the bug; reading the effective directory is
; the fix.
_OEC_MetricsWarningUsesTheChosenDir() {
	Checked := 0
	for Name in ["_Onboarding_Step4", "_OnbWeb_LocaleStringsExpr"] {
		Body := _DriverFuncBody(Name)
		if (InStr(Body, "enable_warning") == 0)
			continue
		Checked += 1
		Assert(InStr(Body, "_Onboarding_EffectiveConfigDir()") > 0,
			Name . " builds the keystroke-logging consent text but does not resolve the EFFECTIVE config dir — _ConfigDir still holds the boot value at this point, so the user consents to logging while being shown a folder that keystrokes will never be written to")
	}
	Assert(Checked >= 2,
		"expected BOTH wizard hosts to build the metrics consent warning (found " . Checked . ") — the native step and the WebView2 payload each build it from the same globals, and only one of them was wrong at a time")
}

; One resolver, so the two hosts cannot drift apart again.
_OEC_ResolverIsSharedAndHonoursTheChoice() {
	Body := _DriverFuncBody("_Onboarding_EffectiveConfigDir")
	Assert(Body != "", "_Onboarding_EffectiveConfigDir() must exist as the single resolver")
	Assert(InStr(Body, "_ob_config_dir") > 0,
		"the resolver must prefer the folder chosen in the wizard")
	Assert(InStr(Body, "_ConfigDir") > 0,
		"the resolver must fall back to the current directory when nothing was chosen")
}


Test("meta onboarding: clearing the config folder reverts to the default", _OEC_EmptyChoiceRevertsToTheDefault)
Test("meta onboarding: the directory is published only after persistence", _OEC_PublishStillFollowsPersistence)
Test("meta onboarding: the metrics consent names the chosen folder", _OEC_MetricsWarningUsesTheChosenDir)
Test("meta onboarding: one shared resolver for the effective folder", _OEC_ResolverIsSharedAndHonoursTheChoice)
