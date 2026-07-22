; static/ergopti_plus/windows/tests/unit/test_preview_defers_to_engine.ahk

; ==============================================================================
; MODULE: Preview / Engine Word-Boundary Agreement (regression)
; DESCRIPTION:
; The tooltip advertised an expansion the engine then refused. Typing "at" and
; pressing the magic key produced "att" (the repeat key doubling the "t"), while
; the tooltip offered "tt -> télétravail" — a trigger the engine will not fire
; mid-word. Pressing the magic key again did nothing, because the engine was
; right and the tooltip was wrong.
;
; ROOT CAUSE ENCODED — TWO BUFFERS, TWO QUESTIONS:
; The preview inferred "am I at a word start?" from its OWN anchor: the suffix
; after the last boundary character in _PrefixBuffer. The engine asks
; _HSE_WordBoundaryAllows(HSE_Buffer, Spec). Those are different questions over
; different buffers, and they diverge after any expansion because _PrefixBuffer
; is rebuilt by the watcher's post-expansion sync while HSE_Buffer keeps the real
; typed context.
;
; Measured, from the driver's own DEBUG log (2026-07-21 18:10:30):
;     OnChar: char='★' prefixBuf='at' hseBuf='…télétravail ⚠️ at'
;     FIRE trig='t★' bs=2 burst='{BackSpace 2}{Text}tt'
;     _LookupAndRender: buf='tt'  ->  prefix MATCH for 'tt' (2 candidates)
; The watcher's buffer became "tt"; the engine's stayed "…att". "tt" looked
; word-initial to the preview and mid-word to the engine.
;
; WHY IT WAS SILENT:
; Nothing throws. The tooltip renders, the engine declines, and the two never
; compare notes — the only symptom is a suggestion that refuses to be validated,
; which reads as "the magic key didn't work" rather than as a preview defect.
;
; THE FIX:
; _PreviewEngineWouldFire asks the ENGINE, using the engine's own Spec from
; HSE_RegistryByLastChar and the engine's own HSE_Buffer. A star trigger is
; evaluated against HSE_Buffer plus the magic key, which is exactly the buffer
; the engine will match against one keystroke later.
; ==============================================================================





; ===================================================
; ===================================================
; ======= 1/ The Preview Defers To The Engine =======
; ===================================================
; ===================================================

; Registers a single star trigger with the real engine and points the engine
; buffer at `Buf`, so the predicate under test sees a faithful registry.
; @param Trigger The trigger to register (e.g. "tt★").
; @param Buf     The engine buffer to simulate.
_PreviewAgree_Setup(Trigger, Buf) {
	global HSE_RegistryByLastChar, HSE_StarSpecs, HSE_Buffer, HSE_StartIsWordBoundary
	global ScriptInformation
	if !IsSet(ScriptInformation)
		ScriptInformation := Map()
	if !ScriptInformation.Has("MagicKey")
		ScriptInformation["MagicKey"] := "★"
	; Clear through the engine's own entry point rather than re-initialising the
	; globals by hand: they are not all Maps (HSE_StarSpecs is an Array), and a
	; hand-built registry would be testing a shape the engine never produces.
	HSE_RegistryClear()
	; "*" marks a star trigger, no "?" so the trigger is word-anchored — the
	; same flags a normal magic-key hotstring is registered with.
	HSE_Register("*", Trigger, (*) => "")
	HSE_Buffer := Buf
	; The buffer start is a real word boundary in every case below, so a refusal
	; can only come from the character preceding the trigger — never from an
	; unknown left edge.
	HSE_StartIsWordBoundary := true
}

TestPreviewAgree_RefusesMidWordStarTrigger() {
	; The measured case: engine buffer ends "att", so the "tt" body of "tt★" is
	; preceded by a letter and the engine will not fire it.
	_PreviewAgree_Setup("tt" . "★", "je viens d’activer att")
	AssertFalse(_PreviewEngineWouldFire("tt" . "★"),
		"a star trigger whose body sits mid-word must NOT be offered — the engine refuses it, "
		. "so advertising it produces a tooltip the magic key cannot validate")
}
Test("preview: a mid-word star trigger is not offered",
	TestPreviewAgree_RefusesMidWordStarTrigger)

TestPreviewAgree_OffersStarTriggerAtWordStart() {
	; The mirror case — the fix must not silence legitimate suggestions.
	_PreviewAgree_Setup("tt" . "★", "je viens d’activer tt")
	AssertTrue(_PreviewEngineWouldFire("tt" . "★"),
		"the same trigger at a genuine word start must still be offered, or the fix has "
		. "traded a false positive for a false negative")
}
Test("preview: a word-initial star trigger is still offered",
	TestPreviewAgree_OffersStarTriggerAtWordStart)

TestPreviewAgree_RefusesWhenBodyIsNotTheSuffix() {
	; The SearchKey scan can surface a candidate whose body is not actually at
	; the end of the engine buffer. Offering it would advertise an expansion for
	; text the user has not typed.
	_PreviewAgree_Setup("tt" . "★", "je viens d’activer atx")
	AssertFalse(_PreviewEngineWouldFire("tt" . "★"),
		"a candidate whose body does not end the engine buffer must not be offered")
}
Test("preview: a candidate that does not match the buffer suffix is not offered",
	TestPreviewAgree_RefusesWhenBodyIsNotTheSuffix)

TestPreviewAgree_FailsOpenForUnknownTrigger() {
	; A trigger the engine has never registered is left visible rather than
	; silently dropped: a registry gap must degrade to the previous behaviour,
	; not empty the tooltip.
	_PreviewAgree_Setup("tt" . "★", "je viens d’activer att")
	AssertTrue(_PreviewEngineWouldFire("zz" . "★"),
		"an unregistered trigger must fail OPEN — hiding it would turn a registry gap into a "
		. "silently empty tooltip, which is harder to diagnose than an over-eager one")
}
Test("preview: an unknown trigger fails open",
	TestPreviewAgree_FailsOpenForUnknownTrigger)
