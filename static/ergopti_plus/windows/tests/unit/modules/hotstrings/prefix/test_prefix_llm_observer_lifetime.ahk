; tests/unit/modules/hotstrings/prefix/test_prefix_llm_observer_lifetime.ahk

; Instrument the actual owner with a native AHK destructor, not a process RSS
; estimate. Its real timer is retired before the only local owner is released.
_LPOL_Deleted(Counter, This) {
	Counter.Deleted += 1
}
_LPOL_Sequence(Mode, Fx, Lines, Sent, State, Schedule, Focus) {
	global _LLM_Bridge_PrefixObserver
	Control := {Deleted: 0}
	Acyclic := {}
	Acyclic.DefineProp("__Delete", {Call: _LPOL_Deleted.Bind(Control)})
	Acyclic := 0
	AssertEqual(1, Control.Deleted, "the actual runtime must synchronously retire an ordinary owner")
	AssertEqual(0, State.Scheduled.Length, "the fake scheduler does not own this probe's callback")
	AssertTrue(LLM_Bridge_FeedCharForPrefix("a", TimerSetCallback, Focus))
	Owner := _LLM_Bridge_PrefixObserver
	Callback := Owner.Timer
	Counter := {Deleted: 0}
	Owner.DefineProp("__Delete", {Call: _LPOL_Deleted.Bind(Counter)})
	AssertEqual(0, Counter.Deleted, "an admitted actual owner remains alive")
	if Mode == "cancel" {
		AssertTrue(LLM_Bridge_CancelPrefixObserver())
	} else {
		PreviousCritical := Critical("Off")
		try {
			Started := A_TickCount
			while IsObject(_LLM_Bridge_PrefixObserver) && TickElapsed64(Started) < 1500
				Sleep(10)
		} finally Critical(PreviousCritical)
		AssertFalse(IsObject(_LLM_Bridge_PrefixObserver), "the real one-shot callback must finish and withdraw its actual global owner")
	}
	; An explicit zero-period acknowledgement removes any scheduler reference,
	; including the already-completed one-shot. The local owner still prevents
	; premature destruction until the observation below.
	AssertTrue(TimerSetCallback(Callback, 0))
	Callback := 0
	AssertFalse(IsObject(_LLM_Bridge_PrefixObserver))
	Owner := 0
	_TestPrint("# LLM_PREFIX_OBSERVER_LIFETIME " . KL_JsonEncode(Map("mode", Mode,
		"acyclic_deleted", Control.Deleted, "owner_deleted", Counter.Deleted,
		"global_retired", !IsObject(_LLM_Bridge_PrefixObserver), "fake_callbacks", State.Scheduled.Length)))
	AssertEqual(1, Counter.Deleted, "a retired real prefix observer must release its callback/owner references")
	AssertEqual(0, Fx.Remote.Length), AssertEqual(0, Fx.Ollama.Length)
}
_LPOL_Case(Mode) {
	PreviousCritical := Critical("On")
	try {
		Body(Fx, Lines, Sent) => _PCA_WithObserverFixture(_LPOL_Sequence.Bind(Mode, Fx, Lines, Sent))
		_LAG_Run(_LAG_Menu("action", "cerebras", "cerebras"), _LTN_Screen(""), Body)
	} finally Critical(PreviousCritical)
}
for _LPOL_Mode in ["cancel", "complete"]
	Test("LLM prefix observer lifetime: " . _LPOL_Mode . " retires the actual native callback owner (llm-prefix-observer-lifetime)",
		_LPOL_Case.Bind(_LPOL_Mode))
