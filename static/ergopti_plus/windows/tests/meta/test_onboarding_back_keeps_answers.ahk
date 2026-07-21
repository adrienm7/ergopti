; tests/meta/test_onboarding_back_keeps_answers.ahk

; ==============================================================================
; MODULE: Regression — navigating Back must not wipe the answers already given
; DESCRIPTION:
; _Onboarding_Step1 opened by re-zeroing every collected answer — _ob_layout,
; _ob_magic_key, _ob_metrics, _ob_gestures, _ob_register_pending. That is
; correct for a wizard that is starting, and Step1 IS the first page, so it
; read as a harmless one-time initialiser.
;
; ROOT CAUSE ENCODED:
; It is also the Back target. _StepConfigDir_Back navigates to Step1, so a user
; who answered the layout, magic-key and metrics steps and then went Back to
; correct the interface language had every one of those answers silently reset
; to its default. Walking forward again restored nothing: the preload that
; could have refilled them returns early when no config.toml exists yet, which
; is precisely the first-run case. The user clicked through their remaining
; steps and shipped a config with the layout and metrics disabled.
;
; A renderer must not own lifecycle state. The reset now lives in a one-shot
; _Onboarding_ResetAnswers called from the wizard's entry points, and Step1 is
; purely a page — so reaching it by Back is navigation, not a restart.
;
; Guarded as a class over every entry point: the defect was that ONE caller of
; Step1 out of three meant something different by the call, so the test walks
; all the callers rather than pinning the Back handler that exposed it.
;
; SCOPE: source introspection of ui/onboarding.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================================
; ======================================================
; ======= 1/ The page renders, it does not reset =======
; ======================================================
; ======================================================

_OBK_Step1DoesNotResetAnswers() {
	Body := _DriverFuncBody("_Onboarding_Step1")
	Assert(Body != "", "_Onboarding_Step1() must exist")

	for Name in ["_ob_layout", "_ob_metrics", "_ob_gestures", "_ob_magic_key", "_ob_register_pending"] {
		Assert(InStr(Body, Name . " :=") == 0 and InStr(Body, Name . "  ") == 0,
			"_Onboarding_Step1 must not assign " . Name . " — it is the Back target from the config-folder step, so resetting answers there silently discards everything the user already answered on the later steps, and the preload cannot restore them on a first run because no config.toml exists yet")
	}
}

; The reset still has to happen, just once and at the start.
_OBK_ResetExistsAsItsOwnStep() {
	Body := _DriverFuncBody("_Onboarding_ResetAnswers")
	Assert(Body != "", "_Onboarding_ResetAnswers() must exist — the reset was moved out of the page renderer, not deleted")

	for Name in ["_ob_layout", "_ob_metrics", "_ob_gestures", "_ob_magic_key"] {
		Assert(InStr(Body, Name) > 0,
			"_Onboarding_ResetAnswers must still clear " . Name . " — dropping an answer from the reset leaks the previous run's value into a fresh wizard")
	}
}





; ==========================================================
; ==========================================================
; ======= 2/ Every entry point resets, Back does not =======
; ==========================================================
; ==========================================================

; The two ways into the wizard must start from a clean slate; the Back handler
; must not. Walking all three callers is the point — the bug was that they all
; called the same function while meaning different things by it.
_OBK_EntryPointsResetAndBackDoesNot() {
	Entries := 0
	for Name in ["Onboarding_Run", "Onboarding_ShowFromMenu"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist")
		Assert(InStr(Body, "_Onboarding_ResetAnswers()") > 0,
			Name . " must reset the collected answers before building the first page — otherwise a second run of the wizard inherits the previous run's answers")
		Entries += 1
	}
	Assert(Entries >= 2, "expected both wizard entry points to be policed")

	Back := _DriverFuncBody("_StepConfigDir_Back")
	Assert(Back != "", "_StepConfigDir_Back() must exist")
	Assert(InStr(Back, "_Onboarding_ResetAnswers()") == 0,
		"the Back handler must NOT reset the answers — going back a page is navigation, and wiping the later answers is exactly the defect this guards")
}


Test("meta onboarding: step 1 renders without resetting answers", _OBK_Step1DoesNotResetAnswers)
Test("meta onboarding: the answer reset is its own one-shot step", _OBK_ResetExistsAsItsOwnStep)
Test("meta onboarding: entry points reset, Back navigates", _OBK_EntryPointsResetAndBackDoesNot)
