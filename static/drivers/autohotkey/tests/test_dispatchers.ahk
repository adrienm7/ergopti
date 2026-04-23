; static/drivers/autohotkey/tests/test_dispatchers.ahk

; ==============================================================================
; MODULE: Dispatcher Tests
; DESCRIPTION:
; Verifies the SIMPLE_ACTIONS / TAPHOLD_ALTGR_ACTIONS Maps and the
; HasAnyEnabled / RunFirstSimpleAction / RunFirstAltGrTapHoldAction helpers.
; ==============================================================================




; Helper used by table-shape tests below.
_AssertHasAll(M, Names) {
	for _, N in Names {
		AssertTrue(M.Has(N), "missing key: " . N)
	}
}
_AssertAllCallable(M) {
	for K, V in M {
		AssertTrue(IsObject(V), "value for " . K . " not callable")
	}
}
ALL_TEN_ACTIONS := ["BackSpace", "CapsLock", "CapsWord", "CtrlBackSpace",
	"CtrlDelete", "Delete", "Enter", "Escape", "OneShotShift", "Tab"]




; ==========================
; SIMPLE_ACTIONS Map
; ==========================
TestDisp_SimpleHasAll() {
	_AssertHasAll(SIMPLE_ACTIONS, ALL_TEN_ACTIONS)
}
Test("SIMPLE_ACTIONS: contains all 10 canonical action names", TestDisp_SimpleHasAll)

TestDisp_SimpleAllCallable() {
	_AssertAllCallable(SIMPLE_ACTIONS)
}
Test("SIMPLE_ACTIONS: every entry is callable", TestDisp_SimpleAllCallable)

TestDisp_AltGrHasAll() {
	_AssertHasAll(TAPHOLD_ALTGR_ACTIONS, ALL_TEN_ACTIONS)
}
Test("TAPHOLD_ALTGR_ACTIONS: contains all 10 canonical action names",
	TestDisp_AltGrHasAll)




; ==========================
; HasAnyEnabled
; ==========================
TestDisp_HasAnyEmpty() {
	AssertFalse(HasAnyEnabled(Map()))
}
Test("HasAnyEnabled: empty Map returns false", TestDisp_HasAnyEmpty)

TestDisp_HasAnyAllDisabled() {
	G := Map(
		"A", { Enabled: false },
		"B", { Enabled: false },
	)
	AssertFalse(HasAnyEnabled(G))
}
Test("HasAnyEnabled: all-disabled Map returns false", TestDisp_HasAnyAllDisabled)

TestDisp_HasAnyOneEnabled() {
	G := Map(
		"A", { Enabled: false },
		"B", { Enabled: true },
		"C", { Enabled: false },
	)
	AssertTrue(HasAnyEnabled(G))
}
Test("HasAnyEnabled: one enabled entry returns true", TestDisp_HasAnyOneEnabled)

TestDisp_HasAnyIgnoreConfig() {
	G := Map(
		"__Configuration", { Enabled: true, TimeActivationSeconds: 0.2 },
		"A", { Enabled: false },
	)
	AssertFalse(HasAnyEnabled(G))
}
Test("HasAnyEnabled: __Configuration sentinel is ignored",
	TestDisp_HasAnyIgnoreConfig)

TestDisp_HasAnySkipString() {
	G := Map(
		"oddball", "string",
		"A", { Enabled: true },
	)
	AssertTrue(HasAnyEnabled(G))
}
Test("HasAnyEnabled: non-object value is skipped without crashing",
	TestDisp_HasAnySkipString)




; ==========================
; RunFirstSimpleAction
; ==========================
TestDisp_RunFirstNone() {
	ResetStubRecorders()
	G := Map(
		"BackSpace", { Enabled: false },
		"Tab", { Enabled: false },
	)
	AssertFalse(RunFirstSimpleAction(G))
	AssertEqual(0, _Stub_LastChars.Length)
}
Test("RunFirstSimpleAction: no enabled entry runs nothing", TestDisp_RunFirstNone)

TestDisp_RunFirstCapsLock() {
	ResetStubRecorders()
	G := Map(
		"CapsLock", { Enabled: true },
		"Tab", { Enabled: true },
	)
	AssertTrue(RunFirstSimpleAction(G))
	; ToggleCapsLock stub records {kind: "toggle_capslock"} on _Stub_SentText.
	AssertTrue(_Stub_SentText.Length >= 1)
	AssertEqual("toggle_capslock", _Stub_SentText[1].kind)
}
Test("RunFirstSimpleAction: fires the first enabled action via stub",
	TestDisp_RunFirstCapsLock)

TestDisp_RunFirstSkipsConfig() {
	ResetStubRecorders()
	G := Map(
		"__Configuration", { Enabled: true },
		"OneShotShift", { Enabled: true },
	)
	AssertTrue(RunFirstSimpleAction(G))
	AssertEqual("one_shot_shift", _Stub_SentText[1].kind)
}
Test("RunFirstSimpleAction: skips __Configuration", TestDisp_RunFirstSkipsConfig)




; ==========================
; RunFirstAltGrTapHoldAction
; ==========================
TestDisp_AltGrTapHoldOSS() {
	ResetStubRecorders()
	G := Map(
		"OneShotShift", { Enabled: true },
	)
	AssertTrue(RunFirstAltGrTapHoldAction(G))
	; OneShotShift stub records {kind: "one_shot_shift"}.
	AssertEqual("one_shot_shift", _Stub_SentText[1].kind)
}
Test("RunFirstAltGrTapHoldAction: OneShotShift action fires the stub",
	TestDisp_AltGrTapHoldOSS)
