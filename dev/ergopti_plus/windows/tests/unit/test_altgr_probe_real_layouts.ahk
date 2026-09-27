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
		; No activation/reordering flag; also prove the caller and foreground
		; layouts stay unchanged (KLF_NOTELLSHELL alone is not that guarantee).
		Before := DllCall("GetKeyboardLayout", "UInt", 0, "Ptr")
		Window := DllCall("GetForegroundWindow", "Ptr")
		Thread := DllCall("GetWindowThreadProcessId", "Ptr", Window, "Ptr", 0, "UInt")
		Foreground := DllCall("GetKeyboardLayout", "UInt", Thread, "Ptr")
		Hkl := DllCall("LoadKeyboardLayoutW", "Str", Klid, "UInt", 0x80, "Ptr")
		Assert(Hkl != 0, "the CI runner must be able to load keyboard layout " . Klid)
		AssertEqual(Before, DllCall("GetKeyboardLayout", "UInt", 0, "Ptr"), "loading the probe must not activate its layout")
		AssertEqual(Foreground, DllCall("GetKeyboardLayout", "UInt", Thread, "Ptr"), "the foreground thread must keep its layout")
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

; Resolve a physical key through the real DLL without sending it or changing
; dead-key state. Independent character expectations catch a probe that simply
; returns a self-consistent but wrong family record.
_APRL_Text(Hkl, Sc, Modifiers) {
	State := Buffer(256, 0)
	for _, Vk in Modifiers
		NumPut("UChar", 0x80, State, Vk)
	Vk := DllCall("MapVirtualKeyExW", "UInt", Sc, "UInt", 3, "Ptr", Hkl, "UInt")
	Chars := Buffer(32, 0)
	Count := DllCall("ToUnicodeEx", "UInt", Vk, "UInt", Sc, "Ptr", State,
		"Ptr", Chars, "Int", 16, "UInt", 4, "Ptr", Hkl, "Int")
	return Count > 0 ? StrGet(Chars, Count, "UTF-16") : ""
}

_APRL_ShippedKanaLayout() {
	if (EnvGet("GITHUB_ACTIONS") != "true")
		return ; Installing or loading a layout belongs to the ephemeral CI runner.
	Klid := EnvGet("ERGOPTI_TEST_KANA_KLID")
	AssertTrue(RegExMatch(Klid, "i)^[0-9a-f]{8}$") != 0, "CI must install and identify the shipped Kana layout")
	Hkl := _APRL_Layout(Klid)
	Probe := KS_ProbeAltGrLayout(Hkl)
	AssertTrue(Probe["valid"], "the shipped Kana DLL maps its AltGr key")
	AssertTrue(Probe["kana"], "the shipped layout belongs to the Kana family")
	AssertEqual(0, Probe["rmenu_sc"], "Kana has no VK_RMENU scan code")
	AssertEqual(0xDF, Probe["altgr_vk"], "Kana SC138 maps to VK_OEM_8")
	AssertFalse(Probe["altgr_level"], "Kana does not use a Ctrl+Alt character level")
	AssertEqual("y", _APRL_Text(Hkl, 0x11, []), "the shipped layout's physical key types y")
	AssertEqual("@", _APRL_Text(Hkl, 0x11, [0xDF]), "OEM8 selects the real Kana level")
	AssertEqual("œ", _APRL_Text(Hkl, 0x12, [0xDF]), "another real Kana key types its level character")
	AssertEqual("", _APRL_Text(Hkl, 0x11, [0x11, 0x12, 0xA2, 0xA5]), "Ctrl+Alt is not the Kana level")
	AssertEqual("y", _APRL_Text(Hkl, 0x11, [0x12, 0xA5]), "synthetic RAlt does not select Kana")
}
Test("altgr probe: the shipped Kana DLL has real OEM8 character semantics (kana-ci-2026-09-27)",
	_APRL_ShippedKanaLayout)
