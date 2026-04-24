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




; ==========================
; RunFirstSimpleAction — all 10 actions
; ==========================
TestDisp_ActionCapsWord() {
	ResetStubRecorders()
	G := Map("CapsWord", { Enabled: true })
	AssertTrue(RunFirstSimpleAction(G))
	AssertEqual("toggle_capsword", _Stub_SentText[1].kind)
}
Test("RunFirstSimpleAction: CapsWord action fires ToggleCapsWord stub",
	TestDisp_ActionCapsWord)

TestDisp_ActionOneShotShift() {
	ResetStubRecorders()
	G := Map("OneShotShift", { Enabled: true })
	AssertTrue(RunFirstSimpleAction(G))
	AssertEqual("one_shot_shift", _Stub_SentText[1].kind)
}
Test("RunFirstSimpleAction: OneShotShift action fires OneShotShift stub",
	TestDisp_ActionOneShotShift)

; BackSpace, Tab, Delete, Enter, Escape, CtrlBackSpace, CtrlDelete send via
; SendInput which in test mode goes through _SendHook (no stub recording in
; _Stub_SentText). We verify the function returns true and no exception is thrown.
TestDisp_ActionBackSpace() {
	ResetHotstringRecorders()
	G := Map("BackSpace", { Enabled: true })
	AssertTrue(RunFirstSimpleAction(G))
}
Test("RunFirstSimpleAction: BackSpace action returns true without crashing",
	TestDisp_ActionBackSpace)

TestDisp_ActionTab() {
	ResetHotstringRecorders()
	G := Map("Tab", { Enabled: true })
	AssertTrue(RunFirstSimpleAction(G))
}
Test("RunFirstSimpleAction: Tab action returns true without crashing",
	TestDisp_ActionTab)

TestDisp_ActionDelete() {
	ResetHotstringRecorders()
	G := Map("Delete", { Enabled: true })
	AssertTrue(RunFirstSimpleAction(G))
}
Test("RunFirstSimpleAction: Delete action returns true without crashing",
	TestDisp_ActionDelete)

TestDisp_ActionEnter() {
	ResetHotstringRecorders()
	G := Map("Enter", { Enabled: true })
	AssertTrue(RunFirstSimpleAction(G))
}
Test("RunFirstSimpleAction: Enter action returns true without crashing",
	TestDisp_ActionEnter)

TestDisp_ActionEscape() {
	ResetHotstringRecorders()
	G := Map("Escape", { Enabled: true })
	AssertTrue(RunFirstSimpleAction(G))
}
Test("RunFirstSimpleAction: Escape action returns true without crashing",
	TestDisp_ActionEscape)

TestDisp_ActionCtrlBackSpace() {
	ResetHotstringRecorders()
	G := Map("CtrlBackSpace", { Enabled: true })
	AssertTrue(RunFirstSimpleAction(G))
}
Test("RunFirstSimpleAction: CtrlBackSpace action returns true without crashing",
	TestDisp_ActionCtrlBackSpace)

TestDisp_ActionCtrlDelete() {
	ResetHotstringRecorders()
	G := Map("CtrlDelete", { Enabled: true })
	AssertTrue(RunFirstSimpleAction(G))
}
Test("RunFirstSimpleAction: CtrlDelete action returns true without crashing",
	TestDisp_ActionCtrlDelete)




; ==========================
; Priority order — first wins
; ==========================
TestDisp_FirstEnabledWins() {
	ResetStubRecorders()
	; Both CapsLock and CapsWord enabled; CapsLock must fire because Map
	; iteration order in AHK v2 is insertion order.
	G := Map(
		"CapsLock", { Enabled: true },
		"CapsWord", { Enabled: true },
	)
	AssertTrue(RunFirstSimpleAction(G))
	AssertEqual(1, _Stub_SentText.Length)
	AssertEqual("toggle_capslock", _Stub_SentText[1].kind)
}
Test("RunFirstSimpleAction: stops after the first enabled action (no double-fire)",
	TestDisp_FirstEnabledWins)

TestDisp_SkipsDisabledThenFiresEnabled() {
	ResetStubRecorders()
	G := Map(
		"CapsLock",   { Enabled: false },
		"OneShotShift", { Enabled: true },
	)
	AssertTrue(RunFirstSimpleAction(G))
	AssertEqual("one_shot_shift", _Stub_SentText[1].kind)
}
Test("RunFirstSimpleAction: skips disabled entries and fires first enabled one",
	TestDisp_SkipsDisabledThenFiresEnabled)




; ==========================
; TAPHOLD_ALTGR_ACTIONS shape
; ==========================
TestDisp_AltGrAllCallable() {
	_AssertAllCallable(TAPHOLD_ALTGR_ACTIONS)
}
Test("TAPHOLD_ALTGR_ACTIONS: every entry is callable", TestDisp_AltGrAllCallable)

TestDisp_AltGrTabAction() {
	ResetHotstringRecorders()
	G := Map("Tab", { Enabled: true })
	AssertTrue(RunFirstAltGrTapHoldAction(G))
}
Test("RunFirstAltGrTapHoldAction: Tab action returns true without crashing",
	TestDisp_AltGrTabAction)
