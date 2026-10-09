; tests/unit/test_altgr_family_follows_layout.ahk

; ==============================================================================
; MODULE: The AltGr family follows the foreground layout without a reload
; DESCRIPTION:
; The AltGr family (_ALTGR_KANA_FIXUP, the probe record, and every reader and
; #HotIf built on them) was decided once per process, and a layout switch
; reloaded the driver to decide it again. With Windows' "use a different input
; method for each app window", each window switch could change the layout: a
; reload per switch, and the wrong family until it finished (audit X-09,
; altgr-family-live-2026-09-27). The family now follows the foreground layout:
; each layout is probed once, a switch republishes the family live, #HotIf
; criteria pick the new family's variants at the next press, the one boot
; registration that read the family (the Kana script chords) decides per
; press, and the layout poll reloads only for the registrations that truly
; depend on the layout (LayoutRemapSignature).
; The cases switch back and forth between a standard AltGr layout (AZERTY), a
; layout whose right Alt is a plain Alt (QWERTY) and a Kana-style layout (the
; maintainer's own), through the modules' seams; no layout is activated, no key
; sent, and no hook installed.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================
; ==================================
; ======= 1/ Fixture layouts =======
; ==================================
; ==================================

global _AFFL_AZERTY := 0x040C040C
global _AFFL_QWERTY := 0x04090409
global _AFFL_KANA := 0xFC06040C
; HKL -> number of probes, reset by _AFFL_Begin.
global _AFFL_Probes := Map()

; The probe of each fixture layout, through the real KS_ProbeAltGrLayout:
; AZERTY and QWERTY keep VK_RMENU on 0xE038 (AZERTY with an AltGr level),
; the Kana layout leaves VK_RMENU unmapped and puts the AltGr key on VK_OEM_8.
_AFFL_Probe(Hkl) {
	global _AFFL_Probes, _AFFL_AZERTY, _AFFL_KANA
	_AFFL_Probes[Hkl] := _AFFL_Probes.Get(Hkl, 0) + 1
	Kana := (Hkl == _AFFL_KANA)
	Answers := Map(KS_VK_RMENU, Kana ? 0 : 0xE038, KS_SC_ALTGR_EXTENDED, Kana ? 0xDF : 0xA5)
	return KS_ProbeAltGrLayout(Hkl, (Code, MapType, Layout) => Answers[Code],
		(Layout) => Layout == _AFFL_AZERTY)
}

_AFFL_Name(Hkl) {
	global _AFFL_AZERTY, _AFFL_QWERTY
	return Hkl == _AFFL_AZERTY ? "azerty" : Hkl == _AFFL_QWERTY ? "qwerty" : "kana"
}

; Boot the family on Hkl with the fixture probe, the AltGr key held as AltGr
; (the default tap-hold) and no TOML override; returns what to restore.
_AFFL_Begin(Hkl, Override := "auto") {
	global _ALTGR_KANA_FIXUP, _ALTGR_LAYOUT_PROBE, ScriptInformation, TapHold, LayerEnabled
	global _AltGrFamilyProbeCache, _AltGrFamilyProbeFn, _AFFL_Probes
	Saved := { Kana: _ALTGR_KANA_FIXUP, Probe: _ALTGR_LAYOUT_PROBE,
		HadOverride: ScriptInformation.Has("AltGrIsKanaRemap"),
		Override: ScriptInformation.Get("AltGrIsKanaRemap", ""),
		Cache: _AltGrFamilyProbeCache, ProbeFn: _AltGrFamilyProbeFn,
		TapHold: TapHold, Layer: LayerEnabled }
	ScriptInformation["AltGrIsKanaRemap"] := Override
	TapHold := Map("keys", Map("alt_gr", Map("time_activation_seconds", 0.2,
		"tap_action", "tab", "hold_modifier", "alt_gr")), "layers", Map())
	LayerEnabled := false
	_AFFL_Probes := Map()
	HotstringEngineInit(() => Hkl, _AFFL_Probe)
	return Saved
}

_AFFL_End(Saved) {
	global _ALTGR_KANA_FIXUP, _ALTGR_LAYOUT_PROBE, ScriptInformation, TapHold, LayerEnabled
	global _AltGrFamilyProbeCache, _AltGrFamilyProbeFn, _AltGrFamilyRetryArmed
	SetTimer(_AltGrFamilyRetryTick, 0)
	_AltGrFamilyRetryArmed := false
	_ALTGR_KANA_FIXUP := Saved.Kana
	_ALTGR_LAYOUT_PROBE := Saved.Probe
	_AltGrFamilyProbeCache := Saved.Cache
	_AltGrFamilyProbeFn := Saved.ProbeFn
	TapHold := Saved.TapHold
	LayerEnabled := Saved.Layer
	if Saved.HadOverride
		ScriptInformation["AltGrIsKanaRemap"] := Saved.Override
	else
		ScriptInformation.Delete("AltGrIsKanaRemap")
}

; Every reader of the family, and the #HotIf criteria built on them, must
; describe layout Hkl's family.
_AFFL_AssertFamily(Hkl, Context) {
	global _AFFL_AZERTY, _AFFL_QWERTY, _AFFL_KANA
	Kana := (Hkl == _AFFL_KANA)
	AltGr := (Hkl != _AFFL_QWERTY)
	Where := Context . " (" . _AFFL_Name(Hkl) . ")"
	AssertEqual(Hkl, _ALTGR_LAYOUT_PROBE["hkl"], Where . ": the record names the layout")
	AssertEqual(Kana ? "SC138" : "RAlt", KS_AltGrKeyName(), Where . ": AltGr key name")
	AssertEqual(Kana ? "vkDF" : "RAlt", KS_AltGrSendKey(), Where . ": AltGr send name")
	AssertEqual(AltGr, KS_LayoutHasAltGr(), Where . ": right Alt is an AltGr")
	AssertEqual(Hkl == _AFFL_AZERTY, KS_AltGrAddsFakeLCtrl(), Where . ": AltGr adds the fake LCtrl")
	AssertTrue(AltGrOwnerPassesThrough(Kana), Where . ": this family's AltGr owner takes the press")
	AssertFalse(AltGrOwnerPassesThrough(!Kana) or AltGrOwnerHolds(!Kana),
		Where . ": the other family's AltGr owner never takes it")
	AssertEqual(AltGr, ScriptAltGrChordIsLive(true), Where . ": script chords need an AltGr")
	AssertEqual(Kana, ScriptAltGrKanaChordIsLive(true), Where . ": the Kana chord twins")
	AssertFalse(ScriptAltGrKanaChordIsLive(false), Where . ": no Kana chord without SC138 down")
}





; ===========================================
; ===========================================
; ======= 2/ Switching families, live =======
; ===========================================
; ===========================================

_AFFL_FollowsEveryFamilyBackAndForth() {
	global _AFFL_AZERTY, _AFFL_QWERTY, _AFFL_KANA, _AFFL_Probes
	Saved := _AFFL_Begin(_AFFL_AZERTY)
	try {
		_AFFL_AssertFamily(_AFFL_AZERTY, "boot")
		Idle := () => false
		; Every ordered pair of the three families, each at least once.
		Sequence := [_AFFL_KANA, _AFFL_QWERTY, _AFFL_AZERTY, _AFFL_KANA, _AFFL_AZERTY,
			_AFFL_QWERTY, _AFFL_KANA, _AFFL_QWERTY]
		for Index, Hkl in Sequence {
			AssertTrue(AltGrFamilyFollow(Hkl, Idle), "switch " . Index . " must republish the family")
			_AFFL_AssertFamily(Hkl, "after switch " . Index)
		}
		for _, Hkl in [_AFFL_AZERTY, _AFFL_QWERTY, _AFFL_KANA]
			AssertEqual(1, _AFFL_Probes.Get(Hkl, 0), _AFFL_Name(Hkl) . " must be probed once, then read from the cache")
		AssertFalse(AltGrFamilyFollow(_AFFL_QWERTY, Idle), "the layout already decided changes nothing")
		AssertFalse(AltGrFamilyFollow(0, Idle), "no foreground window (HKL 0) keeps the family")
		_AFFL_AssertFamily(_AFFL_QWERTY, "after HKL 0")
	} finally _AFFL_End(Saved)
}
Test("altgr family: follows the foreground layout across the three families, probing each once (altgr-family-live-2026-09-27)",
	_AFFL_FollowsEveryFamilyBackAndForth)

_AFFL_OverrideAppliesToEveryLayout() {
	global _AFFL_AZERTY, _AFFL_QWERTY, _AFFL_KANA
	Saved := _AFFL_Begin(_AFFL_AZERTY, "true")
	try {
		AssertTrue(_ALTGR_KANA_FIXUP, "boot: the override forces the Kana family")
		AltGrFamilyFollow(_AFFL_QWERTY, () => false)
		AssertTrue(_ALTGR_KANA_FIXUP, "the manual override keeps forcing the family on every layout")
		AssertEqual("override", _ALTGR_LAYOUT_PROBE["source"], "the record names the override")
		AssertEqual(_AFFL_QWERTY, _ALTGR_LAYOUT_PROBE["hkl"], "the record still names the layout")
	} finally _AFFL_End(Saved)
}
Test("altgr family: the TOML override applies to every followed layout (altgr-family-live-2026-09-27)",
	_AFFL_OverrideAppliesToEveryLayout)

; A switch between an AltGr press and its release would make every reader name
; the other key while the owner still holds the first: it waits, and applies
; once nothing is in flight.
_AFFL_SwitchWaitsForAnInFlightPress() {
	global _AFFL_AZERTY, _AFFL_KANA, _AltGrFamilyRetryArmed
	global _TH_OwnedPresses, _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, HSE_Suppressed
	Saved := _AFFL_Begin(_AFFL_AZERTY)
	try {
		AssertFalse(AltGrFamilyFollow(_AFFL_KANA, () => true), "a busy switch must be held back")
		_AFFL_AssertFamily(_AFFL_AZERTY, "held back")
		AssertTrue(_AltGrFamilyRetryArmed, "a held-back switch is tried again shortly")
		SetTimer(_AltGrFamilyRetryTick, 0)
		_AltGrFamilyRetryArmed := false
		AssertTrue(AltGrFamilyFollow(_AFFL_KANA, () => false), "once idle, the switch applies")
		_AFFL_AssertFamily(_AFFL_KANA, "applied")
		; The production busy check reads the owners' ledgers.
		AssertFalse(AltGrFamilyIsBusy(), "nothing in flight: not busy")
		Cases := [
			["a tap-hold owner resolving a press", _TH_OwnedPresses, "space"],
			["a synthetic Kana AltGr held", _TH_SyntheticHeldKeys, "SC138"],
			["a synthetic right Alt held", _TH_SyntheticHeldKeys, "RAlt"],
			["a synthetic AltGr awaiting its release", _TH_SyntheticReleasePendingKeys, "SC138"],
		]
		for _, Row in Cases {
			Row[2][Row[3]] := 1
			try AssertTrue(AltGrFamilyIsBusy(), Row[1] . " must hold the switch back")
			finally Row[2].Delete(Row[3])
		}
		SavedSuppressed := HSE_Suppressed
		HSE_Suppressed := 1
		try AssertTrue(AltGrFamilyIsBusy(), "a hotstring expansion sending must hold the switch back")
		finally HSE_Suppressed := SavedSuppressed
	} finally _AFFL_End(Saved)
}
Test("altgr family: a switch waits for an in-flight AltGr press or tap-hold (altgr-family-live-2026-09-27)",
	_AFFL_SwitchWaitsForAnInFlightPress)





; ===============================================
; ===============================================
; ======= 3/ What a layout switch reloads =======
; ===============================================
; ===============================================

; A fake layout poll: Signatures maps each HKL to what the boot registrations
; would read from it; the driver booted on _AFFL_AZERTY.
_AFFL_PollPort(Signatures, Reloads) {
	global _AFFL_AZERTY
	return Map(
		"needs_reload", (Hkl) => Signatures[Hkl] != Signatures[_AFFL_AZERTY],
		"reload", (RefusedFn) => (Reloads.Push(RefusedFn), true),
		"pending", () => false,
		"veto_honored", () => true,
		"now", () => A_TickCount,
		"notify", () => 0)
}

_AFFL_OnlyARegistrationChangeReloads() {
	global _AFFL_AZERTY, _AFFL_QWERTY, _AFFL_KANA, _LAST_KEYBOARD_HKL, _PENDING_KEYBOARD_HKL
	global _LayoutPollRetry
	; The entry owns the trackers; the harness never loads it.
	Saved := { Last: IsSet(_LAST_KEYBOARD_HKL) ? _LAST_KEYBOARD_HKL : 0,
		Pending: IsSet(_PENDING_KEYBOARD_HKL) ? _PENDING_KEYBOARD_HKL : 0, Retry: _LayoutPollRetry }
	Bepo := 0xF0CF040C
	; Without the Ergopti emulation, AZERTY, QWERTY and the Kana layout type
	; the magic key's source character on the same key here; bépo types it on
	; another one. The real probes under the shipped defaults, where no switch
	; reloads, are test_layout_digit_row_probe.ahk's.
	Signatures := Map(_AFFL_AZERTY, "same", _AFFL_QWERTY, "same", _AFFL_KANA, "same", Bepo, "other")
	Reloads := []
	Port := _AFFL_PollPort(Signatures, Reloads)
	_LAST_KEYBOARD_HKL := _AFFL_AZERTY
	_PENDING_KEYBOARD_HKL := 0
	_LayoutPollRetry := _LayoutPollNewRetry(0)
	try {
		for _, Hkl in [_AFFL_KANA, _AFFL_QWERTY, _AFFL_AZERTY, _AFFL_KANA, _AFFL_QWERTY] {
			Loop 3
				LayoutPollTick(Hkl, false, false, 0, 0, 5000, false, Port)
			AssertEqual(0, Reloads.Length, "a switch to " . _AFFL_Name(Hkl) . " changes only the AltGr family: no reload")
			AssertEqual(Hkl, _LAST_KEYBOARD_HKL, "the poll adopts " . _AFFL_Name(Hkl) . " as its baseline")
		}
		Loop 3
			LayoutPollTick(Bepo, false, false, 0, 0, 5000, false, Port)
		AssertEqual(1, Reloads.Length, "a layout the boot registrations do not fit still reloads, once")
	} finally {
		_LAST_KEYBOARD_HKL := Saved.Last
		_PENDING_KEYBOARD_HKL := Saved.Pending
		_LayoutPollRetry := Saved.Retry
	}
}
Test("layout poll: a switch between AltGr families never reloads; a layout the registrations do not fit does (altgr-family-live-2026-09-27)",
	_AFFL_OnlyARegistrationChangeReloads)

; A fake of what the registrations read from each layout: MagicScans per HKL.
_AFFL_RemapPort(Emulated, MagicScans) {
	return Map(
		"emulated", () => Emulated,
		"magic_char", () => "j",
		"magic_scan", (Hkl, Char) => MagicScans.Get(Hkl, 0))
}

_AFFL_SignatureNamesTheLayoutRegistrations() {
	global _AFFL_AZERTY, _AFFL_QWERTY, _AFFL_KANA
	Bepo := 0xF0CF040C
	Magic := Map(_AFFL_AZERTY, 0x24, _AFFL_QWERTY, 0x24, _AFFL_KANA, 0x2E, Bepo, 0x13)
	Sig := (Hkl, Emulated) => LayoutRemapSignature(Hkl, _AFFL_RemapPort(Emulated, Magic))
	; The Ergopti emulation on (the shipped default): no registration reads the
	; layout, the digit row included (it follows the foreground layout live).
	for _, Hkl in [_AFFL_QWERTY, _AFFL_KANA, Bepo, 0]
		AssertEqual(Sig(_AFFL_AZERTY, true), Sig(Hkl, true),
			Format("with the emulation on, layout 0x{:X} registers what AZERTY does", Hkl))
	; Without the emulation, only the magic key's source key can differ.
	AssertEqual(Sig(_AFFL_AZERTY, false), Sig(_AFFL_QWERTY, false),
		"the magic key's source on the same key registers the same hotkey")
	AssertTrue(Sig(_AFFL_AZERTY, false) != Sig(_AFFL_KANA, false),
		"the magic key's source on another key must reload")
	AssertTrue(InStr(Sig(0, false), "magic=default") > 0,
		"no layout read (HKL 0) keeps the default magic key, as the boot scan does")
}
Test("layout poll: the remap signature names what the boot registrations read from a layout (altgr-family-live-2026-09-27)",
	_AFFL_SignatureNamesTheLayoutRegistrations)





; ===================================================
; ===================================================
; ======= 4/ No registration reads the family =======
; ===================================================
; ===================================================

; The lines of Src grouped by the function that holds them, "<top level>" for
; the rest. A definition is a name and its parameters opening a block, at any
; indentation (win.ahk defines its functions inside a top-level block); its body
; ends at the closing brace at the definition's own indentation.
_AFFL_FunctionBuckets(Src) {
	static Keywords := Map("if", 1, "while", 1, "for", 1, "loop", 1, "switch", 1, "catch", 1,
		"return", 1, "until", 1, "try", 1, "else", 1)
	Lines := StrSplit(Src, "`n", "`r")
	Buckets := Map()
	Current := "<top level>"
	Indent := ""
	for Index, Line in Lines {
		Next := (Index < Lines.Length) ? Lines[Index + 1] : ""
		if (Current == "<top level>"
				and RegExMatch(Line, "^(\s*)([A-Za-z_]\w*)\(.*\)\s*(\{)?\s*$", &Def)
				and !Keywords.Has(StrLower(Def[2]))
				and (Def[3] == "{" or RegExMatch(Next, "^\s*\{\s*$"))) {
			Current := Def[2]
			Indent := Def[1]
		}
		if !Buckets.Has(Current)
			Buckets[Current] := []
		Buckets[Current].Push(Line)
		if (Current != "<top level>" and RegExMatch(Line, "^" . Indent . "\}\s*$"))
			Current := "<top level>"
	}
	return Buckets
}

; A hotkey registered while reading the family is fixed to the boot family:
; the Kana script chords were registered only when the boot layout was a Kana
; one. Every registration must leave the family to its live criterion
; (a HotIf lambda or a #HotIf line), which AutoHotkey evaluates per press.
_AFFL_NoRegistrationReadsTheFamily() {
	static Readers := "_ALTGR_KANA_FIXUP|KS_AltGrKeyName\(|KS_AltGrSendKey\(|KS_LayoutHasAltGr\("
		. "|KS_AltGrAddsFakeLCtrl\(|KS_AltGrScanCode\("
	SplitPath(A_ScriptDir, , &Root)
	Offenders := []
	Registering := 0
	Loop Files, Root . "\*.ahk", "FR" {
		P := StrReplace(A_LoopFileFullPath, "\", "/")
		if (InStr(P, "/tests/") or InStr(P, "/vendor/") or InStr(P, "/_generated/"))
			continue
		Buckets := _AFFL_FunctionBuckets(_StripFullLineComments(FileRead(A_LoopFileFullPath, "UTF-8")))
		for Name, Lines in Buckets {
			Registers := false
			for _, Line in Lines {
				if RegExMatch(Line, "(^|[^\w.])Hotkey\(")
					Registers := true
			}
			if !Registers
				continue
			Registering += 1
			for _, Line in Lines {
				if (RegExMatch(Line, Readers) and !InStr(Line, "HotIf("))
					Offenders.Push(P . " " . Name . ": " . Trim(Line))
			}
		}
	}
	AssertTrue(Registering >= 5, "the scan must find the driver's hotkey registrations; found " . Registering)
	AssertEqual(0, Offenders.Length, "a registration must not read the AltGr family outside its live criterion: "
		. (Offenders.Length ? Offenders[1] : ""))
	; The registrar takes every chord and criterion from the plan, which binds the
	; Kana twin to a criterion reading the family per press (script-chord-slot-2026-09-30).
	Body := _StripFullLineComments(_DriverFuncBody("_RegisterScriptAltGrHotkeys"))
	AssertTrue(InStr(Body, "ScriptAltGrChordPlan(") > 0 and InStr(Body, 'HotIf(Row["criterion"])') > 0,
		"the script chords must be registered from the plan, each under its own criterion")
	Plan := _StripFullLineComments(_DriverFuncBody("ScriptAltGrChordPlan"))
	AssertTrue(InStr(Plan, '"$" . Sc') > 0 and InStr(Plan, "ScriptAltGrKanaChordRunsSlot.Bind(Slot)") > 0,
		"the Kana script chords must be registered on every layout, gated per press")
	AssertTrue(InStr(_DriverFuncBody("ScriptAltGrKanaChordRunsSlot"), 'ScriptAltGrKanaChordIsLive(GetKeyState("SC138", "P"))') > 0,
		"the Kana twins' criterion must read the family per press")
}
Test("altgr family: no hotkey registration reads the family outside its live criterion (altgr-family-live-2026-09-27)",
	_AFFL_NoRegistrationReadsTheFamily)

; The entry wires the follower: the foreground hook starts with the poll, the
; poll follows the layout before deciding a reload, the reload asks the remap
; signature, and shutdown unhooks.
_AFFL_EntryFollowsTheForegroundLayout() {
	Tick := _StripFullLineComments(_DriverFuncBody("CheckKeyboardLayoutChange"))
	Follow := InStr(Tick, "AltGrFamilyFollow(curHkl)")
	AssertTrue(Follow > 0, "the layout poll must follow the foreground layout")
	AssertTrue(Follow < InStr(Tick, "LayoutPollTick("), "the family follows before the reload decision")
	Port := _StripFullLineComments(_DriverFuncBody("LayoutPollPort"))
	AssertTrue(InStr(Port, '"needs_reload", LayoutRemapNeedsReload') > 0,
		"the poll's reload must ask whether the boot registrations fit the layout")
	; A top-level call, in the whole driver source: only the entry's
	; auto-execute section starts following.
	AssertTrue(RegExMatch(_DriverSourceNoComments(), "m)^AltGrFamilyStartFollowing\(\)") > 0,
		"the entry must start following the foreground window")
	AssertTrue(InStr(_StripFullLineComments(_DriverFuncBody("Ergopti_OnShutdown")), "AltGrFamilyStopFollowing()") > 0,
		"shutdown must unhook the foreground hook")
	; A start that dies before its success line must still leave its START.
	Start := _StripFullLineComments(_DriverFuncBody("AltGrFamilyStartFollowing"))
	Opened := InStr(Start, "LoggerStart(")
	AssertTrue(Opened > 0 and Opened < InStr(Start, "CallbackCreate(") and Opened < InStr(Start, "LoggerSuccess("),
		"starting to follow must open its lifecycle before creating the hook and closing it")
}
Test("altgr family: the entry follows the foreground layout and unhooks at shutdown (altgr-family-live-2026-09-27)",
	_AFFL_EntryFollowsTheForegroundLayout)
