; tests/meta/test_hse_altgr_kana_sendinput.ahk

; ==============================================================================
; MODULE: HSE AltGr Kana Fixup SendInput Regression Test
; DESCRIPTION:
; Guards that the Kana AltGr lift HSE_DispatchMatch performs before each
; expansion goes through SendInput, not SendEvent.
;
; WHY THIS MATTERS (the regression this encodes):
;   SendEvent is synchronous: it flushes the event through the Windows message
;   queue and all active keyboard hooks before returning. On a system with the
;   AHK hook at input level 2, that round-trip adds ~10-20 ms to every hotstring
;   expansion on AltGr-fixup keyboards. _ALTGR_KANA_FIXUP is true on a
;   Kana-style layout, where the AltGr key is moved off VK_RMENU (the Ergopti
;   layout puts it on VK_OEM_8), or when the AltGr-is-Kana TOML override forces
;   it; it is false on AZERTY, bépo and QWERTY, where VK_RMENU is mapped. On
;   those Kana layouts this hit every expansion — the 70 ms HSE.Dispatch
;   warning for "l'" was partly caused by this.
;   The lift now goes through the tap-hold owner (so a tap-hold's own AltGr
;   hold survives the expansion, kana-altgr-lift-owner-2026-09-25), whose
;   TapHoldLiftKey sends through TextSender, a SendInput funnel. Reverting
;   either hop to SendEvent silently re-adds the expansion latency.
;
; SCOPE: source introspection of HSE_DispatchMatch, _HSE_SendWithAltGrUp and
; TapHoldLiftKey.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckHseAltGrKanaSendInput() {
	Body := _StripFullLineComments(_DriverFuncBody("HSE_DispatchMatch"))
	Assert(Body != "", "HSE_DispatchMatch must be present for the AltGr SendInput meta-test")
	Assert(InStr(Body, "_HSE_SendWithAltGrUp(") > 0,
		"HSE_DispatchMatch must lift the Kana AltGr through the owner (perf-hse-altgr-sendinput)")
	Wrapper := _StripFullLineComments(_DriverFuncBody("_HSE_SendWithAltGrUp"))
	Assert(InStr(Wrapper, "TapHoldSendWithKeyUp(") > 0,
		"the expansion output must lift the Kana AltGr through the tap-hold owner (perf-hse-altgr-sendinput)")
	Assert(!InStr(Body, "SendEvent("),
		"HSE_DispatchMatch must NOT use SendEvent — use SendInput to avoid the hook-chain round-trip (perf-hse-altgr-sendinput)")

	Lift := _StripFullLineComments(_DriverFuncBody("TapHoldLiftKey"))
	Assert(Lift != "", "TapHoldLiftKey must exist")
	Assert(InStr(Lift, "TextPressKey(") > 0 and !InStr(Lift, "SendEvent("),
		"the owner's lift must go through the TextSender SendInput funnel, never SendEvent (perf-hse-altgr-sendinput)")
	Funnel := _DriverFuncBody("_TextSenderSendInput")
	Assert(InStr(Funnel, "_AHK_SendInput") > 0 and !InStr(Funnel, "SendEvent("),
		"the TextSender funnel must stay a SendInput (perf-hse-altgr-sendinput)")
}

Test("meta perf: HSE AltGr kana fixup uses SendInput not SendEvent (perf-hse-altgr-sendinput)",
	_MetaCheckHseAltGrKanaSendInput)
