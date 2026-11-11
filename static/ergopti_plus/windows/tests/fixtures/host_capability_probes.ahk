; static/ergopti_plus/windows/tests/fixtures/host_capability_probes.ahk

; ==============================================================================
; MODULE: Host Capability Probes
; DESCRIPTION:
; Classifies one real observation of this machine into a host capability
; receipt for TestRequireHostCapability. Each case makes the observation it
; already depends on (the layout handle it reads, the symlink it creates) and
; passes it here, so the probe and the case can never look at different
; things. A receipt is "absent" only for an observation that positively proves
; the prerequisite missing; anything unexpected is "unknown" and the case runs.
; The GitHub runner provides all of them (en-US QWERTY active with the shipped
; Kana layout installed but not active, and the symlink privilege).
; ==============================================================================

#Requires AutoHotkey v2.0

#Include host_capability_gate.ahk

; ERROR_PRIVILEGE_NOT_HELD, CreateSymbolicLinkW's refusal without Developer
; Mode or SeCreateSymbolicLinkPrivilege.
global TEST_ERROR_PRIVILEGE_NOT_HELD := 1314

; Receipt for the file symlink a case has just tried to create.
; @param Created {Integer} CreateSymbolicLinkW's result.
; @param LastError {Integer} A_LastError read right after that call.
; @return {Map}
TestFileSymlinkReceipt(Created, LastError) {
	global TEST_ERROR_PRIVILEGE_NOT_HELD
	State := Created != 0 ? "present" : LastError == TEST_ERROR_PRIVILEGE_NOT_HELD ? "absent" : "unknown"
	return Map("state", State, "hosted_ci", "required", "name", "file symlink creation",
		"why", "CreateSymbolicLinkW refused with Win32 error " . LastError
			. " (ERROR_PRIVILEGE_NOT_HELD); enable Developer Mode or run elevated to execute it here")
}

; Receipt for the virtual key the layout gives the first top-row key (SC010).
; The row probes inject that physical key and need it to be a letter.
; @param Vk {Integer} MapVirtualKey(SC010, MAPVK_VSC_TO_VK_EX) under the layout.
; @return {Map}
TestTopRowLetterReceipt(Vk) {
	State := Vk >= 0x41 && Vk <= 0x5A ? "present" : Vk != 0 ? "absent" : "unknown"
	return Map("state", State, "hosted_ci", "required", "name", "a letter on the first top-row key",
		"why", Format("the active keyboard layout maps SC010 to VK 0x{:02X}, not a letter;", Vk)
			. " switch to a layout such as US QWERTY or French AZERTY to execute it here")
}

; Receipt for the plain character the OS layout types on SC012.
; @param KeyText {Object} KS_KeyTextNoStateChange's { Count, Text } for SC012.
; @return {Map}
TestSc012NotOReceipt(KeyText) {
	State := KeyText.Count != 1 ? "unknown" : KeyText.Text == "o" ? "absent" : "present"
	return Map("state", State, "hosted_ci", "required", "name", "an OS character other than o on SC012",
		"why", "the foreground keyboard layout already types o on SC012, like the Ergopti+ top row,"
			. " so the OS character cannot be told from the selected one; switch to US QWERTY or French AZERTY to execute it here")
}

; Receipt for a case that simulates the Kana AltGr family over a real layout
; whose VK_OEM_8 is an ordinary key. A real Kana layout makes SC138 its own
; level modifier, so its original OEM keydown does not reach the receiver the
; way the oracle expects.
; @param Probe {Map} KS_ProbeAltGrLayout's record for the layout under test.
; @return {Map}
TestNonKanaLayoutReceipt(Probe) {
	State := !Probe["valid"] ? "unknown" : Probe["kana"] ? "absent" : "present"
	return Map("state", State, "hosted_ci", "required", "name", "a non-Kana active keyboard layout",
		"why", Format("the active keyboard layout 0x{:X} is itself a Kana-family layout (SC138 is VK 0x{:02X}, no VK_RMENU);",
			Probe["hkl"] & 0xFFFFFFFF, Probe["altgr_vk"])
			. " switch to a layout such as US QWERTY or French AZERTY to execute it here")
}
