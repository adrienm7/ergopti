; tests/unit/test_altgr_detection.ahk

; ==============================================================================
; MODULE: AltGr family detection at boot
; DESCRIPTION:
; HotstringEngineInit decides the AltGr family the whole driver keys on
; (_ALTGR_KANA_FIXUP, KS_AltGrKeyName) and had no test at all: flipping its
; probe verdict, or dropping the TOML override, left the suite green. It now
; reads the layout once, probes it once (KS_ProbeAltGrLayout) and keeps the
; record every boot consumer reads (altgr-single-probe-2026-09-26). The cases
; drive it through its two seams, so no real layout is involved: a standard
; AltGr layout or QWERTY (VK_RMENU on 0xE038), a Kana-style remap (VK_RMENU
; unmapped, the AltGr key on VK_OEM_8), a layout that could not be read, and
; each spelling of the override.
; ==============================================================================

#Requires AutoHotkey v2.0

; A probe of HKL 0x123 answering RMenuSc to the reverse lookup and AltGrVk to
; the forward one, through the real KS_ProbeAltGrLayout.
_AGD_Probe(RMenuSc, AltGrVk) {
	Answers := Map(KS_VK_RMENU, RMenuSc, KS_SC_ALTGR_EXTENDED, AltGrVk)
	return (Hkl) => KS_ProbeAltGrLayout(Hkl, (Code, MapType, Layout) => Answers[Code])
}

; Run HotstringEngineInit with the layout Hkl, the probe ProbeFn and the TOML
; override Override ("" for none), and return the flag and the record.
_AGD_Init(Hkl, ProbeFn, Override := "") {
	global _ALTGR_KANA_FIXUP, _ALTGR_LAYOUT_PROBE, ScriptInformation
	Saved := { Kana: _ALTGR_KANA_FIXUP, Probe: _ALTGR_LAYOUT_PROBE,
		HadOverride: ScriptInformation.Has("AltGrIsKanaRemap"),
		Override: ScriptInformation.Get("AltGrIsKanaRemap", "") }
	try {
		if (Override == "")
			ScriptInformation["AltGrIsKanaRemap"] := "auto"
		else
			ScriptInformation["AltGrIsKanaRemap"] := Override
		HotstringEngineInit(() => Hkl, ProbeFn)
		return { Kana: _ALTGR_KANA_FIXUP, Probe: _ALTGR_LAYOUT_PROBE }
	} finally {
		_ALTGR_KANA_FIXUP := Saved.Kana
		_ALTGR_LAYOUT_PROBE := Saved.Probe
		if Saved.HadOverride
			ScriptInformation["AltGrIsKanaRemap"] := Saved.Override
		else
			ScriptInformation.Delete("AltGrIsKanaRemap")
	}
}

_AGD_ProbeDecidesTheFamily() {
	Standard := _AGD_Init(0x040C040C, _AGD_Probe(0xE038, 0xA5))
	AssertFalse(Standard.Kana, "a layout with VK_RMENU on the AltGr key is a standard AltGr layout (or QWERTY)")
	AssertEqual("probe", Standard.Probe["source"], "the probe decided")
	AssertEqual(0x040C040C, Standard.Probe["hkl"], "the record keeps the layout it probed")
	Kana := _AGD_Init(0xFC06040C, _AGD_Probe(0, 0xDF))
	AssertTrue(Kana.Kana, "a layout with VK_RMENU unmapped and the AltGr key on VK_OEM_8 is a Kana-style layout")
	AssertEqual(0xDF, Kana.Probe["altgr_vk"], "the record keeps the AltGr key's virtual key")
}
Test("altgr detection: the probe decides the AltGr family (altgr-single-probe-2026-09-26)",
	_AGD_ProbeDecidesTheFamily)

_AGD_OverrideWinsAndKeepsTheLayout() {
	Forced := _AGD_Init(0x040C040C, _AGD_Probe(0xE038, 0xA5), true)
	AssertTrue(Forced.Kana, "the TOML override true forces the Kana family")
	AssertEqual("override", Forced.Probe["source"], "the record names the override")
	AssertEqual(0x040C040C, Forced.Probe["hkl"], "the layout is still read for the poll and the magic-key scan")
	Off := _AGD_Init(0xFC06040C, _AGD_Probe(0, 0xDF), false)
	AssertFalse(Off.Kana, "the TOML override false forces the standard family")
	Auto := _AGD_Init(0xFC06040C, _AGD_Probe(0, 0xDF), "auto")
	AssertTrue(Auto.Kana, "'auto' defers to the probe")
}
Test("altgr detection: the TOML override wins, the layout is still recorded (altgr-single-probe-2026-09-26)",
	_AGD_OverrideWinsAndKeepsTheLayout)

_AGD_UnreadableLayoutIsNotKana() {
	Probed := false
	None := _AGD_Init(0, (Hkl) => (Probed := true, KS_ProbeAltGrLayout(Hkl)))
	AssertFalse(Probed, "HKL 0 (HKL_PREV, another loaded layout) must never be probed")
	AssertFalse(None.Kana, "no readable layout must not be taken for a Kana layout")
	AssertEqual("unresolved", None.Probe["source"], "the record must say the layout could not be read")
	Blank := _AGD_Init(0xDEADBEEF, _AGD_Probe(0, 0))
	AssertFalse(Blank.Kana, "a layout that maps neither direction (an invalid HKL) must not be taken for a Kana layout")
	AssertEqual("unresolved", Blank.Probe["source"], "the record must say the probe read nothing")
}
Test("altgr detection: an unreadable layout is logged as unresolved, never Kana (altgr-single-probe-2026-09-26)",
	_AGD_UnreadableLayoutIsNotKana)
