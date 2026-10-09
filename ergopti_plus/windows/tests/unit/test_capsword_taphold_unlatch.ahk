; static/ergopti_plus/windows/tests/unit/test_capsword_taphold_unlatch.ahk

; ==============================================================================
; MODULE: Regression — a tap-hold Space or Enter still ends CapsWord
;         (capsword-taphold-unlatch)
; DESCRIPTION:
; With a space tap-hold configured and CapsWord bound to a chord: activate
; CapsWord, type HELLO, press Space, type "world" — and it came out WORLD.
; CapsWord had survived the word terminator that is supposed to end it.
;
; ROOT CAUSE ENCODED: two hotkey variants claim SC039 at the same time.
; capsword.ahk arms `#HotIf CapsWordEnabled` → SC039 to unlatch, and space.ahk
; arms the tap-hold variant. Both criteria are true simultaneously, and this
; repo's own pinned precedence is that the most-recently-DEFINED variant wins.
; platform/remap.ahk is included AFTER modules/shortcuts.ahk, so the tap-hold
; variant fires and the unlatch hotkey is dead code whenever a space tap-hold is
; configured. Enter is shadowed identically.
;
; So the unlatch cannot live only in capsword.ahk: whichever variant wins has to
; carry the rule. It is placed on the shared tap dispatcher rather than on the
; two key modules, so one owner covers every tap-hold variant that may later
; bind these keys — the AltGr tap dispatch already unlatches this way.
;
; SCOPE: behavioural. TapHoldDispatchTap lives in the tap-hold constants module,
; which the headless runner does include.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================================
; ==================================================================
; ======= 1/ A terminator tap unlatches, a non-terminator does not =
; ==================================================================
; ==================================================================

; Drive one dispatch with CapsWord active and report whether it survived.
; TapHoldDispatchTap consults the activity/suspend guards first, so the fixture
; sets up a key with a real configured duration.
_CTU_DispatchWith(KeyId) {
	global CapsWordEnabled, TapHold
	CapsWordEnabled := true
	Ran := false
	TapHoldDispatchTap(KeyId, (*) => (Ran := true))
	return { Ran: Ran, StillLatched: CapsWordEnabled }
}

; The reported bug, reduced: the space that should have ended CapsWord.
_CTU_SpaceTapUnlatchesCapsWord() {
	R := _CTU_DispatchWith("space")
	Assert(R.Ran,
		"the tap must still run — unlatching CapsWord may not cost the user their space")
	Assert(!R.StillLatched,
		"a tap-hold Space must end CapsWord. Its own `#HotIf CapsWordEnabled` unlatch hotkey is shadowed by the later-defined tap-hold variant, so if the dispatcher does not unlatch, nothing does and the next word is capitalised too")
}

; Enter is the sibling site, shadowed by exactly the same precedence rule.
_CTU_EnterTapUnlatchesCapsWord() {
	R := _CTU_DispatchWith("enter")
	Assert(R.Ran, "the tap must still run")
	Assert(!R.StillLatched,
		"a tap-hold Enter must end CapsWord for the same reason as Space — capsword.ahk's Enter unlatch is shadowed identically")
}

; The rule must stay narrow. CapsWord exists to capitalise a whole word, so a
; tap that is NOT a word terminator has to leave it latched; unlatching on every
; tap-hold tap would quietly destroy the feature instead of fixing it.
_CTU_NonTerminatorTapKeepsCapsWord() {
	for KeyId in ["backspace", "escape", "delete", "caps_lock"] {
		R := _CTU_DispatchWith(KeyId)
		Assert(R.StillLatched,
			"a tap-hold " . KeyId . " is not a word terminator and must leave CapsWord latched — unlatching on every tap would make CapsWord unusable for its one purpose")
	}
	global CapsWordEnabled := false
}




; ==================================================================
; ==================================================================
; ======= 2/ The shadowing precondition is still true ==============
; ==================================================================
; ==================================================================

; This whole fix exists because the tap-hold variant wins. If the include order
; ever flipped, capsword.ahk's own hotkeys would take over and the dispatcher
; unlatch would become a second, redundant owner — worth knowing about rather
; than discovering through behaviour.
_CTU_TapHoldsAreIncludedAfterShortcuts() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := ""
	try Src := FileRead(WindowsDir . "\ErgoptiPlus.ahk")
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")
	Code := _StripFullLineComments(Src)

	ShortcutsPos := InStr(Code, "#Include modules/shortcuts.ahk")
	TapHoldsPos  := InStr(Code, "#Include platform/remap.ahk")
	Assert(ShortcutsPos > 0 and TapHoldsPos > 0,
		"both module groups must still be included from the entry")
	Assert(TapHoldsPos > ShortcutsPos,
		"tap_holds must still be included AFTER shortcuts. That order is why the tap-hold Space/Enter variants win over capsword.ahk's unlatch hotkeys, which is the premise the dispatcher-side unlatch is built on")
}

; And capsword must keep its own unlatch hotkeys: they are the ones that run
; when NO tap-hold is configured for those keys, which is the default.
_CTU_CapsWordKeepsItsOwnUnlatch() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/shortcuts"))
	Assert(InStr(Src, "#HotIf CapsWordEnabled") > 0,
		"capsword.ahk must keep its own CapsWordEnabled hotkey context — with no tap-hold configured on Space or Enter, those variants are the only unlatch path there is")
	Assert(InStr(Src, "DisableCapsWord()") > 0,
		"capsword.ahk must keep calling DisableCapsWord from its terminator hotkeys")
}


Test("capsword-taphold-unlatch: a tap-hold Space ends CapsWord",
	_CTU_SpaceTapUnlatchesCapsWord)
Test("capsword-taphold-unlatch: a tap-hold Enter ends CapsWord",
	_CTU_EnterTapUnlatchesCapsWord)
Test("capsword-taphold-unlatch: a non-terminator tap leaves CapsWord latched",
	_CTU_NonTerminatorTapKeepsCapsWord)
Test("capsword-taphold-unlatch: tap_holds is still included after shortcuts",
	_CTU_TapHoldsAreIncludedAfterShortcuts)
Test("capsword-taphold-unlatch: capsword keeps its own unlatch hotkeys",
	_CTU_CapsWordKeepsItsOwnUnlatch)
