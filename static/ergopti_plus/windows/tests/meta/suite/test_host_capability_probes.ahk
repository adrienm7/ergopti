; tests/meta/suite/test_host_capability_probes.ahk

; ==============================================================================
; MODULE: Host Capability Probe Tests
; DESCRIPTION:
; The probes in fixtures/host_capability_probes.ahk decide whether a case runs
; or reports NOT EXECUTED on a developer machine. Each probe is driven both
; ways here, and the gate is shown to fail instead of skipping on hosted CI,
; so a probe that always answers "absent" or a gate that skips on GitHub
; Actions cannot pass (host-capability-probes).
; ==============================================================================

#Requires AutoHotkey v2.0

#Include %A_LineFile%\..\..\..\fixtures\host_capability_probes.ahk

; Runs the gate over one receipt and names its outcome: "ran", "not executed"
; or "failed" with the message.
_HCP_GateOutcome(Receipt, HostedCi?) {
	try {
		TestRequireHostCapability(() => Receipt, HostedCi?)
		return "ran"
	} catch TestNotExecutedSignal as Signal {
		return "not executed: " . Signal.Message
	} catch as Err {
		return "failed: " . Err.Message
	}
}

_HCP_GateDecidesBothWays() {
	Absent := Map("state", "absent", "hosted_ci", "required", "name", "example", "why", "the probe saw it missing")
	AssertEqual("not executed: host capability example is absent: the probe saw it missing",
		_HCP_GateOutcome(Absent, false), "a developer machine reports an absent capability as not executed")
	AssertEqual("failed: hosted CI must provide host capability example, which is absent: the probe saw it missing",
		_HCP_GateOutcome(Absent, true), "hosted CI fails a case whose capability is absent instead of skipping it")
	; A capability a runner is designed to lack (the unattended CurrentUser root
	; admission) declares no hosted_ci rule and stays not executed there too.
	Designed := Map("state", "absent", "name", "example", "why", "the probe saw it missing")
	AssertEqual("not executed: host capability example is absent: the probe saw it missing",
		_HCP_GateOutcome(Designed, true), "hosted CI keeps a designed absence not executed")
	Unknown := Map("state", "absent", "hosted_ci", "optional", "name", "example", "why", "unused")
	AssertContains(_HCP_GateOutcome(Unknown, false), "failed: A host capability receipt hosted_ci must be")
	for State in ["present", "unknown"] {
		Receipt := Map("state", State, "name", "example", "why", "unused")
		AssertEqual("ran", _HCP_GateOutcome(Receipt, false), State . " runs the case on a developer machine")
		AssertEqual("ran", _HCP_GateOutcome(Receipt, true), State . " runs the case on hosted CI")
	}
	Invalid := Map("state", "skipped", "name", "example", "why", "unused")
	AssertContains(_HCP_GateOutcome(Invalid, false), "failed: A host capability receipt state must be")
}
Test("host capability gate: absent skips locally, fails on hosted CI, present and unknown run (host-capability-probes)",
	_HCP_GateDecidesBothWays)

_HCP_GateReadsHostedCiFromEnvironment() {
	AssertEqual(StrCompare(EnvGet("GITHUB_ACTIONS"), "true", true) == 0, TestHostIsHostedCi(),
		"the default gate decision follows GITHUB_ACTIONS")
	Absent := Map("state", "absent", "hosted_ci", "required", "name", "example", "why", "the probe saw it missing")
	Expected := TestHostIsHostedCi() ? "failed: " : "not executed: "
	AssertContains(_HCP_GateOutcome(Absent), Expected, "the omitted seam uses the real environment")
}
Test("host capability gate: the default decision is the real GITHUB_ACTIONS value (host-capability-probes)",
	_HCP_GateReadsHostedCiFromEnvironment)

_HCP_ProbesClassifyBothWays() {
	AssertEqual("present", TestFileSymlinkReceipt(1, 0)["state"])
	AssertEqual("absent", TestFileSymlinkReceipt(0, 1314)["state"], "ERROR_PRIVILEGE_NOT_HELD proves the privilege missing")
	AssertEqual("unknown", TestFileSymlinkReceipt(0, 5)["state"], "another refusal is not evidence of the privilege")
	AssertEqual("present", TestTopRowLetterReceipt(0x51)["state"], "US QWERTY SC010 is Q")
	AssertEqual("present", TestTopRowLetterReceipt(0x41)["state"], "French AZERTY SC010 is A")
	AssertEqual("present", TestTopRowLetterReceipt(0x5A)["state"])
	AssertEqual("absent", TestTopRowLetterReceipt(0xDB)["state"], "Ergopti SC010 is VK_OEM_4, not a letter")
	AssertEqual("unknown", TestTopRowLetterReceipt(0)["state"], "an unmapped key is not evidence of a layout")
	AssertEqual("present", TestSc012NotOReceipt({Count: 1, Text: "e"})["state"], "US QWERTY SC012 types e")
	AssertEqual("absent", TestSc012NotOReceipt({Count: 1, Text: "o"})["state"], "Ergopti SC012 types o")
	AssertEqual("unknown", TestSc012NotOReceipt({Count: -1, Text: "^"})["state"], "a dead key is not a plain character")
	AssertEqual("unknown", TestSc012NotOReceipt({Count: 0, Text: ""})["state"])
	Probe := (Valid, Kana) => Map("hkl", 0x4090409, "rmenu_sc", Kana ? 0 : 0xE038, "altgr_vk", 0xDF,
		"valid", Valid, "kana", Kana, "altgr_level", false)
	AssertEqual("present", TestNonKanaLayoutReceipt(Probe(true, false))["state"], "QWERTY keeps VK_RMENU")
	AssertEqual("absent", TestNonKanaLayoutReceipt(Probe(true, true))["state"], "a real Kana layout is active")
	AssertEqual("unknown", TestNonKanaLayoutReceipt(Probe(false, false))["state"], "an unreadable layout decides nothing")
}
Test("host capability probes: each probe decides present, absent and unknown from its observation (host-capability-probes)",
	_HCP_ProbesClassifyBothWays)

; The real observation: an actual file symlink attempt in a private folder. It
; can only be present or absent here, and hosted CI must be able to create it.
_HCP_RealSymlinkAttempt() {
	Root := A_Temp . "\ergopti_host_capability_symlink_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(100000, 999999)
	Created := FSCreateDirectoryExclusiveStrict(Root)
	AssertTrue(Created is Integer && Created == 1, "the probe root must be exclusively owned")
	try {
		Target := Root . "\target.txt", Link := Root . "\link.txt"
		FileAppend("target", Target)
		Native := DllCall("Kernel32\CreateSymbolicLinkW", "Str", Link, "Str", Target, "UInt", 2, "UChar")
		NativeError := A_LastError
		Receipt := TestFileSymlinkReceipt(Native, NativeError)
		_TestAppendProgress("# RECEIPT host-capability-symlink state=" . Receipt["state"])
		AssertTrue(Receipt["state"] == "present" || Receipt["state"] == "absent",
			"a real symlink attempt either succeeds or is refused for the privilege, not Win32 error " . NativeError)
		if TestHostIsHostedCi()
			AssertEqual("present", Receipt["state"], "hosted CI runners hold the symlink privilege")
		if Receipt["state"] == "present"
			AssertEqual("target", FileRead(Link), "a present receipt names a working link")
	} finally DirDelete(Root, true)
}
Test("host capability probes: a real symlink attempt is classified, and hosted CI can create one (host-capability-probes)",
	_HCP_RealSymlinkAttempt)
