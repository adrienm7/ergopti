; static/ergopti_plus/windows/tests/unit/test_hook_dispatcher.ahk

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





; ========================================
; ========================================
; ======= 1/ Register / Unregister =======
; ========================================
; ========================================

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





; ===================================================
; ===================================================
; ======= 2/ keyboard_hook bind-once contract =======
; ===================================================
; ===================================================

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





; ==================================================
; ==================================================
; ======= 3/ Self-unregister during dispatch =======
; ==================================================
; ==================================================

; A subscriber that Unregisters ITSELF from within its own dispatched callback —
; mirrors GestureReleaseLeftClick/RightClick (gestures.ahk), which call
; HookDispatcher.Unregister from inside the handler. Module-level named functions
; so Register and the in-callback Unregister pass the identical Func object.
global _HD_SelfUnregEvt := ""
global _HD_SelfUnregHits := []

_HD_SelfUnregSub(*) {
	global _HD_SelfUnregEvt, _HD_SelfUnregHits
	_HD_SelfUnregHits.Push("a")
	HookDispatcher.Unregister(_HD_SelfUnregEvt, _HD_SelfUnregSub)
}

_HD_PeerSub(*) {
	global _HD_SelfUnregHits
	_HD_SelfUnregHits.Push("b")
}

_HD_DispatchSelfUnregisterDoesNotSkipPeer() {
	global _HD_SelfUnregEvt, _HD_SelfUnregHits
	_HD_SelfUnregEvt := "test_evt_selfunreg_" . A_TickCount
	_HD_SelfUnregHits := []
	; Self-unregistering sub registered FIRST, plain peer SECOND. If Dispatch
	; walks the LIVE array, RemoveAt of the first shifts the peer into the
	; already-passed slot 1 and the enumerator skips it (Hits == ["a"]).
	HookDispatcher.Register(_HD_SelfUnregEvt, _HD_SelfUnregSub)
	HookDispatcher.Register(_HD_SelfUnregEvt, _HD_PeerSub)
	HookDispatcher.Dispatch(_HD_SelfUnregEvt)
	AssertEqual(2, _HD_SelfUnregHits.Length,
		"a subscriber that unregisters itself mid-dispatch must not skip the peer that follows it — Dispatch must iterate a snapshot (.Clone()), not the live array")
	AssertEqual("b", _HD_SelfUnregHits[2], "the peer must still fire after the self-unregistering subscriber")
	; The self-unregistering sub must have actually been removed from the registry.
	remaining := HookDispatcher._subscribers.Has(_HD_SelfUnregEvt) ? HookDispatcher._subscribers[_HD_SelfUnregEvt].Length : 0
	AssertEqual(1, remaining, "the self-unregistering subscriber must be removed from the live registry while the peer remains")
	HookDispatcher.Unregister(_HD_SelfUnregEvt, _HD_PeerSub)
}
Test("HookDispatcher.Dispatch does not skip a peer when a subscriber self-unregisters (dispatch-skips-peer-on-self-unregister)", _HD_DispatchSelfUnregisterDoesNotSkipPeer)





; ===============================================================
; ===============================================================
; ======= 4/ _ih initialised as readable false, not unset =======
; ===============================================================
; ===============================================================

; Regression guard for the crash reported 2026-06-16:
;   PropertyError: "This value of type 'Class' has no property named '_ih'."
;   hook_dispatcher.ahk (314): If HookDispatcher._ih is InputHook
;
; Root cause: `static _ih := unset` declares the property as unreadable.
; The `is` operator reads the left-hand side before evaluating — accessing
; an unset property raises PropertyError. The same crash reproduced on any
; Stop()/Start() cycle because Stop() also reset `_ih := unset`.
; Fix: use `false` as the sentinel (a non-object value that `is InputHook`
; safely evaluates to false without throwing).

_HD_IhInitialisedReadable() {
	; `_ih` must be readable immediately — no PropertyError on first access.
	; Before the fix, this line itself threw: "has no property named '_ih'".
	ihVal := HookDispatcher._ih
	AssertEqual(false, ihVal, "_ih must be false (readable sentinel) on a fresh class, not unset")
}
Test("HookDispatcher._ih is initialised as false (readable), not unset — prevents PropertyError on Start() boot", _HD_IhInitialisedReadable)

_HD_IhIsInputHookCheckDoesNotThrow() {
	; The exact expression from Start() line 314 must not throw when _ih is false.
	; Before the fix, `unset is InputHook` raised PropertyError before evaluation.
	threw := false
	result := false
	try {
		result := HookDispatcher._ih is InputHook
	} catch {
		threw := true
	}
	AssertEqual(false, threw, "'_ih is InputHook' must not throw when _ih is the false sentinel")
	AssertEqual(false, result, "'false is InputHook' must evaluate to false")
}
Test("HookDispatcher._ih is InputHook does not throw when _ih is the false sentinel", _HD_IhIsInputHookCheckDoesNotThrow)





; ======================================================================
; ======================================================================
; ======= 5/ _hk_* mouse sentinels initialised as readable false =======
; ======================================================================
; ======================================================================

; Sibling of the `_ih` PropertyError trap fixed in section 4: the ten mouse
; Hotkey() bound-func caches (_hk_ldown, _hk_lup, _hk_rdown, _hk_rup,
; _hk_mdown, _hk_mup, _hk_wup, _hk_wdn, _hk_wright, _hk_wleft) used to be
; declared `static _hk_* := unset` and reset to `unset` at the end of Stop().
; Stop() reads them behind a `HasOwnProp("_hk_ldown")` guard before the `is
; Func` check, which does prevent the throw in practice (HasOwnProp on an
; unset static returns false, short-circuiting the `&&` before `is` runs) —
; but leaving the sentinel as `unset` is still a latent trap for any future
; caller that reads `_hk_*` without remembering that guard. Fixed to `false`
; for the same defence-in-depth reason as `_ih`.

_HD_HkSentinelsInitialisedReadable() {
	; Every _hk_* static must be readable immediately — no PropertyError on
	; first access, mirroring the _ih contract in section 4.
	AssertEqual(false, HookDispatcher._hk_ldown,  "_hk_ldown must be false (readable sentinel), not unset")
	AssertEqual(false, HookDispatcher._hk_lup,    "_hk_lup must be false (readable sentinel), not unset")
	AssertEqual(false, HookDispatcher._hk_rdown,  "_hk_rdown must be false (readable sentinel), not unset")
	AssertEqual(false, HookDispatcher._hk_rup,    "_hk_rup must be false (readable sentinel), not unset")
	AssertEqual(false, HookDispatcher._hk_mdown,  "_hk_mdown must be false (readable sentinel), not unset")
	AssertEqual(false, HookDispatcher._hk_mup,    "_hk_mup must be false (readable sentinel), not unset")
	AssertEqual(false, HookDispatcher._hk_wup,    "_hk_wup must be false (readable sentinel), not unset")
	AssertEqual(false, HookDispatcher._hk_wdn,    "_hk_wdn must be false (readable sentinel), not unset")
	AssertEqual(false, HookDispatcher._hk_wright, "_hk_wright must be false (readable sentinel), not unset")
	AssertEqual(false, HookDispatcher._hk_wleft,  "_hk_wleft must be false (readable sentinel), not unset")
}
Test("HookDispatcher._hk_* mouse sentinels are initialised as false (readable), not unset", _HD_HkSentinelsInitialisedReadable)

_HD_HkSentinelIsFuncCheckDoesNotThrow() {
	; The exact guarded expression from Stop() must not throw, with or without
	; the HasOwnProp guard, whether called on a fresh class (never Start()ed)
	; or after a Stop()/Start()/Stop() cycle reset it back to false.
	threw := false
	result := false
	try {
		result := HookDispatcher._hk_ldown is Func
	} catch {
		threw := true
	}
	AssertEqual(false, threw, "'_hk_ldown is Func' must not throw when _hk_ldown is the false sentinel")
	AssertEqual(false, result, "'false is Func' must evaluate to false")

	; Same check via the exact guarded pattern used in Stop() itself.
	guardedThrew := false
	try {
		if HookDispatcher.HasOwnProp("_hk_ldown") && HookDispatcher._hk_ldown is Func
			guardedResult := true
		else
			guardedResult := false
	} catch {
		guardedThrew := true
	}
	AssertEqual(false, guardedThrew, "Stop()'s guarded '_hk_ldown is Func' pattern must not throw on the false sentinel")
}
Test("HookDispatcher._hk_ldown is Func does not throw when _hk_ldown is the false sentinel", _HD_HkSentinelIsFuncCheckDoesNotThrow)

_HD_StopBeforeStartDoesNotThrow() {
	; Stop() called before any Start() must be a safe no-op — it must not
	; throw PropertyError while reading the _hk_* sentinels or _ih.
	threw := false
	errMsg := ""
	try {
		HookDispatcher.Stop()
	} catch as e {
		threw := true
		errMsg := e.Message
	}
	AssertEqual(false, threw, "HookDispatcher.Stop() before Start() must not throw" . (threw ? " (" . errMsg . ")" : ""))
}
Test("HookDispatcher.Stop() called before Start() does not throw (hook-dispatcher-hk-property-error)", _HD_StopBeforeStartDoesNotThrow)

_HD_DoubleStopDoesNotThrow() {
	; Two consecutive Stop() calls (the second with every _hk_* already reset
	; to false by the first) must not throw either.
	threw := false
	errMsg := ""
	try {
		HookDispatcher.Stop()
		HookDispatcher.Stop()
	} catch as e {
		threw := true
		errMsg := e.Message
	}
	AssertEqual(false, threw, "HookDispatcher.Stop() called twice in a row must not throw" . (threw ? " (" . errMsg . ")" : ""))
}
Test("HookDispatcher.Stop() called twice in a row does not throw (hook-dispatcher-hk-property-error)", _HD_DoubleStopDoesNotThrow)
