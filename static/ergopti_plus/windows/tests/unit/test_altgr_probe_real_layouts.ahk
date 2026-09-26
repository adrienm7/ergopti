; tests/unit/test_altgr_probe_real_layouts.ahk

; ==============================================================================
; MODULE: The AltGr probe on real keyboard layouts
; DESCRIPTION:
; Every other AltGr test stands in for the layout. This one runs the boot probe
; (KS_ProbeAltGrLayout) on real layout DLLs, so a probe that misreads a real
; AZERTY or US layout fails somewhere. On the CI runner it loads French AZERTY
; and US QWERTY (without activating them) and checks both families; on a
; developer machine, where loading layouts would touch the user's session, it
; checks those two only if they are already installed, and the probe's own
; invariants on every installed layout. No key is sent and no hook installed
; (altgr-probe-real-layouts-2026-09-26).
; ==============================================================================

#Requires AutoHotkey v2.0

; HKL of the layout with KLID Klid: loaded on the CI runner, looked up among
; the installed ones elsewhere (0 when absent).
_APRL_Layout(Klid) {
	if (EnvGet("GITHUB_ACTIONS") = "true") {
		; KLF_NOTELLSHELL (0x80): load for the probe, activate nothing.
		Hkl := DllCall("LoadKeyboardLayoutW", "Str", Klid, "UInt", 0x80, "Ptr")
		Assert(Hkl != 0, "the CI runner must be able to load keyboard layout " . Klid)
		return Hkl
	}
	Wanted := Integer("0x" . Klid)
	for _, Hkl in KS_InstalledKeyboardLayouts() {
		if ((Hkl & 0xFFFFFFFF) == ((Wanted << 16) | Wanted))
			return Hkl
	}
	return 0
}

_APRL_StandardAndQwertyOnRealLayouts() {
	Azerty := _APRL_Layout("0000040C")
	if (Azerty != 0) {
		Probe := KS_ProbeAltGrLayout(Azerty)
		AssertFalse(Probe["kana"], "French AZERTY is a standard AltGr layout, not a Kana one")
		AssertEqual(0xE038, Probe["rmenu_sc"], "French AZERTY puts VK_RMENU on the AltGr key")
		AssertTrue(Probe["altgr_level"], "French AZERTY types characters under Ctrl+Alt (its AltGr level)")
	}
	Qwerty := _APRL_Layout("00000409")
	if (Qwerty != 0) {
		Probe := KS_ProbeAltGrLayout(Qwerty)
		AssertFalse(Probe["kana"], "US QWERTY is not a Kana layout")
		AssertFalse(Probe["altgr_level"], "US QWERTY has no AltGr level: right Alt is a plain Alt")
	}
	Checked := 0
	for _, Hkl in KS_InstalledKeyboardLayouts() {
		Probe := KS_ProbeAltGrLayout(Hkl)
		AssertTrue(Probe["valid"], Format("installed layout 0x{:X} must know its AltGr key", Hkl))
		AssertEqual(Probe["rmenu_sc"] == 0, Probe["kana"],
			Format("installed layout 0x{:X}: the family follows the VK_RMENU probe", Hkl))
		Checked += 1
	}
	AssertTrue(Checked >= 1, "at least the session's own layout must be probed")
}
Test("altgr probe: real layouts give the expected family and AltGr level (altgr-probe-real-layouts-2026-09-26)",
	_APRL_StandardAndQwertyOnRealLayouts)
