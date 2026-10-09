; tests/meta/test_prior_key_guards_use_helper.ahk

; ==============================================================================
; MODULE: Tap-hold prior-key guards go through one helper
; DESCRIPTION:
; Every tap-hold module used to compare A_PriorKey with its own hand-written
; name. Two of them could never match ("SC138" for the Kana AltGr, "BackSpace"
; for Backspace), and the others only worked on layouts whose virtual keys keep
; their standard names (tap-hold-prior-key-2026-09-25). The only sound
; comparison derives the expected name from the key's scan code at call time,
; which TapHoldPriorKeyIsSelf owns. This test forbids any other comparison
; against A_PriorKey in the driver and checks that each guard names the key its
; own block times.
; ==============================================================================

#Requires AutoHotkey v2.0

_PKGH_CountMatches(Haystack, Pattern) {
	Count := 0
	Position := 1
	while (Found := RegExMatch(Haystack, Pattern, &Match, Position)) {
		Count++
		Position := Found + Max(Match.Len, 1)
	}
	return Count
}

_PKGH_NoRawPriorKeyComparison() {
	Src := _DriverSourceConcat()
	Assert(Src != "", "the driver source must be readable for the prior-key meta-test")
	Code := _DriverMaskNonCode(&Src)
	Subjects := _PKGH_CountMatches(Code, "\bA_PriorKey\b")
	Assert(Subjects > 0, "the driver must still read A_PriorKey somewhere; otherwise this test proves nothing")
	Comparisons := _PKGH_CountMatches(Code,
		"i)\bA_PriorKey\s*(?:==|!==|!=|<>|=(?!=))|(?:==|!=|<>|[^:<>!=]=)\s*A_PriorKey\b|\b(?:switch|InStr|RegExMatch|StrCompare)\b\W*A_PriorKey")
	AssertEqual(0, Comparisons,
		"compare A_PriorKey only through TapHoldPriorKeyIsSelf: a hand-written key name breaks on AHK's spelling or on the active layout")
	Body := _DriverFuncBody("TapHoldPriorKeyIsSelf")
	Assert(Body != "", "TapHoldPriorKeyIsSelf must exist")
	Assert(InStr(Body, "A_PriorKey") > 0, "TapHoldPriorKeyIsSelf must read A_PriorKey itself")
}
Test("tap-hold prior key: no guard compares A_PriorKey with a literal (tap-hold-prior-key-2026-09-25)",
	_PKGH_NoRawPriorKeyComparison)

; Each guard must name the tap-hold key whose own block it gates. Within the
; concatenated remap sources every file stays contiguous, so the nearest
; preceding TapHoldDuration(TapHold, "<id>") belongs to the same block.
_PKGH_EveryGuardNamesItsOwnKey() {
	Src := _StripFullLineComments(_DriverDirConcat("platform/remap"))
	Assert(Src != "", "the tap-hold remap sources must be readable")
	Guards := 0
	Position := 1
	while (Found := RegExMatch(Src, 'TapHoldPriorKeyIsSelf\("([a-z_]+)"\)', &Call, Position)) {
		Position := Found + Call.Len
		Before := SubStr(Src, 1, Found)
		LastId := ""
		ScanAt := 1
		while (Timed := RegExMatch(Before, 'TapHoldDuration\(TapHold, "([a-z_]+)"\)', &Duration, ScanAt)) {
			LastId := Duration[1]
			ScanAt := Timed + Duration.Len
		}
		AssertEqual(LastId, Call[1],
			"a prior-key guard must name the tap-hold key its own block times")
		Guards++
	}
	Assert(Guards >= 20, "every tap-hold release guard must go through the helper, found " . Guards)
}
Test("tap-hold prior key: every guard names the key its block times (tap-hold-prior-key-2026-09-25)",
	_PKGH_EveryGuardNamesItsOwnKey)
