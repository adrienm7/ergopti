; tests/meta/test_onboarding_magic_key_sentinel.ahk

; ==============================================================================
; MODULE: Regression — "nothing chosen yet" must not be a real magic key
; DESCRIPTION:
; ONBOARDING_DEFAULT_MAGIC_KEY is the black star, which is also a perfectly
; valid answer — it is the documented Ergopti default. _Onboarding_Step3
; nevertheless used it as the "unset" sentinel:
;
;     current_key := (_ob_magic_key != "" and _ob_magic_key != ONBOARDING_DEFAULT_MAGIC_KEY)
;         ? _ob_magic_key : _Onboarding_PickDefaultMagicKey()
;
; ROOT CAUSE ENCODED:
; A guard cannot distinguish "the user deliberately chose the default" from
; "nothing was loaded" when the loaded value IS the sentinel. A user whose
; config held that trigger char with the layout emulation off — a combination
; the wizard itself produces — re-ran the wizard and had the saved character
; replaced during page CONSTRUCTION, before touching anything. The step then
; wrote the substitute back into wizard state and Finish committed it: every
; hotstring trigger changed. The comment above that write calls it a
; preservation measure, which is precisely what it defeated.
;
; Nothing was logged, and the radio faithfully pre-selected the NEW value, so
; the page looked internally consistent and the user had no way to see it.
;
; The fix tracks provenance explicitly instead of inferring it from the value.
; Written for the CLASS: it fails if any site goes back to inferring "unset"
; from the default's value, and it checks every writer keeps the flag truthful
; — a flag set in one place and forgotten in another is the same bug in a hat.
;
; SCOPE: source introspection, function-scoped so the files can move freely.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================================================
; =============================================================
; ======= 1/ The default is never used as an unset test =======
; =============================================================
; =============================================================

_OMK_DefaultIsNotAnUnsetSentinel() {
	Src := _DriverDirConcat("ui/onboarding")
	Assert(Src != "", "the onboarding source must be readable")
	Assert(InStr(Src, "!= ONBOARDING_DEFAULT_MAGIC_KEY") == 0,
		"no onboarding site may test a saved magic key against ONBOARDING_DEFAULT_MAGIC_KEY to decide whether one was chosen — the default is itself a valid answer, so that test silently discards the user's saved character and substitutes the layout default")
}

; The provenance flag must exist AND be consulted where the fallback is picked,
; otherwise the flag is dead weight and the old inference has simply moved.
_OMK_ResolutionConsultsProvenance() {
	Body := _DriverFuncBody("_Onboarding_Step3")
	Assert(Body != "", "_Onboarding_Step3() must exist")
	Assert(InStr(Body, "_ob_magic_key_explicit") > 0,
		"_Onboarding_Step3 must choose between the saved key and the computed default from the explicit-provenance flag, not from the value itself")
	Assert(InStr(Body, "_Onboarding_PickDefaultMagicKey()") > 0,
		"_Onboarding_Step3 must still fall back to the computed default when nothing was chosen")
}





; =======================================================
; =======================================================
; ======= 2/ Every writer keeps the flag truthful =======
; =======================================================
; =======================================================

; Policed as a class: four separate paths own this answer — the native step's
; page build and its Next handler, the WebView2 finish handler, and the
; existing-config preload. Each writes a value that IS a real choice, so each
; must mark it explicit. A writer that forgets leaves a chosen key looking
; unchosen to the next page build, which is exactly the original defect.
_OMK_EveryWriterMarksProvenance() {
	Writers := ["_Onboarding_Step3", "_Step3_Next", "_OnbWeb_Finish",
		"_Onboarding_PreloadFromExistingConfig"]
	Checked := 0
	for Name in Writers {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist")
		if (InStr(Body, "_ob_magic_key :=") == 0)
			continue
		Checked += 1
		Assert(InStr(Body, "_ob_magic_key_explicit := true") > 0,
			Name . " assigns _ob_magic_key without marking it explicit — a value written without its provenance reads as unchosen and gets overwritten by the layout default on the next page build")
	}
	Assert(Checked >= 4,
		"expected all four magic-key writers to be policed (found " . Checked . ") — if a writer was renamed, rename it here too rather than letting it drop out of the class")
}

; The reset path must clear the flag along with the value: a stale true would
; make a wiped answer look like a deliberate choice.
_OMK_ResetClearsBothHalves() {
	Body := _DriverFuncBody("_Onboarding_ResetAnswers")
	if (Body == "")
		Body := _DriverFuncBody("_Onboarding_Step1")
	Assert(Body != "", "the answer-reset path must exist")
	if (InStr(Body, "_ob_magic_key := ONBOARDING_DEFAULT_MAGIC_KEY") == 0)
		return
	Assert(InStr(Body, "_ob_magic_key_explicit := false") > 0,
		"the site that resets _ob_magic_key to the default must clear _ob_magic_key_explicit in the same place")
}


Test("meta onboarding: the default magic key is not an unset sentinel", _OMK_DefaultIsNotAnUnsetSentinel)
Test("meta onboarding: step 3 resolves the key from provenance", _OMK_ResolutionConsultsProvenance)
Test("meta onboarding: every magic-key writer records provenance", _OMK_EveryWriterMarksProvenance)
Test("meta onboarding: resetting the magic key clears its provenance", _OMK_ResetClearsBothHalves)
