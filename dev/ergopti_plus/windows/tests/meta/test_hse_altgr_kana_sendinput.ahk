; tests/meta/test_hse_altgr_kana_sendinput.ahk

; ==============================================================================
; MODULE: HSE AltGr Kana Fixup SendInput Regression Test
; DESCRIPTION:
; Guards that the _ALTGR_KANA_FIXUP SC138-Up injection in HSE_DispatchMatch uses
; SendInput, not SendEvent.
;
; WHY THIS MATTERS (the regression this encodes):
;   SendEvent is synchronous: it flushes the event through the Windows message
;   queue and all active keyboard hooks before returning. On a system with the
;   AHK hook at input level 2, that round-trip adds ~10-20 ms to every hotstring
;   expansion on AltGr-fixup keyboards. Since _ALTGR_KANA_FIXUP=true is the
;   default for French AZERTY layouts, this hit every expansion — the 70 ms
;   HSE.Dispatch warning for "l'" was partly caused by this.
;   SendInput injects the SC138 Up directly into the kernel input queue
;   (consistent with the SendInput burst that follows it) and returns immediately,
;   eliminating the hook-chain round-trip latency. Reverting to SendEvent
;   silently re-adds the expansion latency on AltGr-fixup keyboards.
;
; SCOPE: source introspection of lib/hotstrings/hotstring_engine_main.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckHseAltGrKanaSendInput() {
	; Move-resilient: isolate HSE_DispatchMatch's body across the whole driver
	; source. Scoping to the function body (not the lib/hotstrings dir) is
	; required because a SIBLING function in hotstring_engine.ahk legitimately
	; uses SendEvent("{SC138 Up}"); the absent check must stay scoped to
	; HSE_DispatchMatch alone.
	Body := _DriverFuncBody("HSE_DispatchMatch")
	Assert(Body != "", "HSE_DispatchMatch must be present for the AltGr SendInput meta-test")

	; The fixup must use SendInput for the SC138 Up.
	Assert(InStr(Body, 'SendInput("{SC138 Up}")'),
		"HSE_DispatchMatch must use SendInput for the SC138 Up AltGr kana fixup (perf-hse-altgr-sendinput)")

	; SendEvent on SC138 must be absent — it was the source of the hook-chain latency.
	Assert(!InStr(Body, 'SendEvent("{SC138 Up}")'),
		"HSE_DispatchMatch must NOT use SendEvent for SC138 Up — use SendInput to avoid hook-chain round-trip (perf-hse-altgr-sendinput)")
}

Test("meta perf: HSE AltGr kana fixup uses SendInput not SendEvent (perf-hse-altgr-sendinput)",
	_MetaCheckHseAltGrKanaSendInput)
