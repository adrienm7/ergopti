; static/ergopti_plus/windows/tests/test_hook_dispatcher.ahk

; ==============================================================================
; MODULE: HookDispatcher Regression Tests
; DESCRIPTION:
; Locks the subscriber-registration contract of lib/hook_dispatcher.ahk.
;
; Regression guard for the critical BoundFunc ".Ptr" bug: Register() and
; Unregister() compared callbacks via `existing.Ptr = callback_fn.Ptr`, but a
; BoundFunc (what every caller passes) has NO .Ptr property. The access threw
; "has no property named Ptr", the bare try swallowed it, and the .Push() that
; followed was skipped — so every subscriber AFTER the first for a given event
; type was silently dropped and a whole feature (keylogger / LLM bridge / prefix
; watcher) went deaf to the keyboard depending on registration order. The fix is
; object-identity comparison (`existing == callback_fn`), which never throws.
;
; Also guards keyboard_hook.ahk's bind-once-and-cache contract: KHStart must
; register a cached BoundFunc and KHStop must Unregister the SAME object, else
; identity matching fails and KHStop leaks the subscriber.
;
; NOTE: tests use named functions (block bodies). AHK v2 fat-arrow closures take
; a SINGLE expression — `() => { ... }` parses as an object literal, not a block.
; ==============================================================================





; ==========================================
; ========================================
; ======= 1/ Register / Unregister =======
; ========================================
; ==========================================

_HD_RegisterKeepsMultipleSubscribers() {
	Evt := "test_evt_multi_" . A_TickCount
	B1 := ((*) => 0).Bind()
	B2 := ((*) => 0).Bind()
	HookDispatcher.Register(Evt, B1)
	HookDispatcher.Register(Evt, B2)
	AssertEqual(2, HookDispatcher._subscribers[Evt].Length,
		"two distinct BoundFunc subscribers must both register (BoundFunc has no .Ptr)")
}
Test("HookDispatcher.Register keeps multiple distinct BoundFunc subscribers", _HD_RegisterKeepsMultipleSubscribers)

_HD_RegisterIsIdempotent() {
	Evt := "test_evt_idem_" . A_TickCount
	B := ((*) => 0).Bind()
	HookDispatcher.Register(Evt, B)
	HookDispatcher.Register(Evt, B)
	AssertEqual(1, HookDispatcher._subscribers[Evt].Length,
		"re-registering the same reference must not add a duplicate")
}
Test("HookDispatcher.Register is idempotent for the same BoundFunc reference", _HD_RegisterIsIdempotent)

_HD_UnregisterRemovesByIdentity() {
	Evt := "test_evt_unreg_" . A_TickCount
	B1 := ((*) => 0).Bind()
	B2 := ((*) => 0).Bind()
	HookDispatcher.Register(Evt, B1)
	HookDispatcher.Register(Evt, B2)
	HookDispatcher.Unregister(Evt, B1)
	AssertEqual(1, HookDispatcher._subscribers[Evt].Length,
		"Unregister must remove exactly the matching reference")
	HookDispatcher.Unregister(Evt, B2)
	AssertEqual(0, HookDispatcher._subscribers[Evt].Length,
		"Unregister of the last subscriber leaves the list empty")
}
Test("HookDispatcher.Unregister removes a subscriber by identity", _HD_UnregisterRemovesByIdentity)

_HD_DispatchFansOutToAll() {
	Evt := "test_evt_fanout_" . A_TickCount
	Hits := []
	HookDispatcher.Register(Evt, ((V) => Hits.Push(V)).Bind())
	; Second distinct subscriber — the one the .Ptr bug used to drop.
	HookDispatcher.Register(Evt, ((V) => Hits.Push(V * 10)).Bind())
	HookDispatcher.Dispatch(Evt, 5)
	AssertEqual(2, Hits.Length, "both subscribers must fire on dispatch")
}
Test("HookDispatcher.Dispatch fans out to every registered subscriber", _HD_DispatchFansOutToAll)





; ==================================================
; ===================================================
; ======= 2/ keyboard_hook bind-once contract =======
; ===================================================
; ==================================================

_HD_KeyboardHookStartStopDetaches() {
	CharEvt := HookDispatcherConst.EVT_KB_CHAR
	DownEvt := HookDispatcherConst.EVT_KB_DOWN
	BaseChar := HookDispatcher._subscribers.Has(CharEvt) ? HookDispatcher._subscribers[CharEvt].Length : 0
	BaseDown := HookDispatcher._subscribers.Has(DownEvt) ? HookDispatcher._subscribers[DownEvt].Length : 0
	KHStart(Map("onChar", (e) => 0, "onKey", (e) => 0))
	AssertEqual(BaseChar + 1, HookDispatcher._subscribers[CharEvt].Length, "KHStart registers a char subscriber")
	AssertEqual(BaseDown + 1, HookDispatcher._subscribers[DownEvt].Length, "KHStart registers a key subscriber")
	KHStop()
	AssertEqual(BaseChar, HookDispatcher._subscribers[CharEvt].Length, "KHStop detaches the char subscriber (same cached ref)")
	AssertEqual(BaseDown, HookDispatcher._subscribers[DownEvt].Length, "KHStop detaches the key subscriber (same cached ref)")
}
Test("keyboard_hook KHStart then KHStop fully detaches its subscribers", _HD_KeyboardHookStartStopDetaches)
