; lib/hook_dispatcher.ahk

; ==============================================================================
; MODULE: Hook Dispatcher
; DESCRIPTION:
; Central singleton that owns every low-level input hook in the process and
; fan-outs to registered subscriber callbacks. Before this module existed
; each feature (keylogger, adapter contract, future modules) registered its
; own InputHook or Hotkey independently, which meant the OS received multiple
; overlapping hook requests and event ordering was undefined. Now a single
; InputHook and a single set of mouse Hotkeys are created once; all other
; modules subscribe through this dispatcher.
;
; FEATURES & RATIONALE:
; 1. Single InputHook — one InputHook("V L0") for the whole process. Avoids
;    the "multiple InputHook" contention that can cause AHK to silently drop
;    events when hooks race to grab the same key stream.
; 2. Single mouse-button set — LButton/RButton/MButton/Wheel hotkeys are
;    registered exactly once via the dispatcher's Start(). Additional mouse
;    subscribers just Register() without touching Hotkey() themselves.
; 3. Multi-subscriber fan-out — the internal handler loops over every
;    registered callback for the fired event type and calls each in turn,
;    wrapped in try/catch so one bad callback cannot silence the others.
; 4. Event types — string constants on HookDispatcherConst match the ones
;    used by callers: "keyboard_char", "keyboard_down", "keyboard_up",
;    "mouse_ldown", "mouse_lup", "mouse_rdown", "mouse_rup",
;    "mouse_mdown", "mouse_mup", "mouse_wup", "mouse_wdn",
;    "mouse_wright", "mouse_wleft".
; 5. Thread safety — every handler that mutates subscriber lists runs under
;    Critical so concurrent pseudo-threads cannot corrupt the Arrays.
;
; LIFECYCLE:
; - HookDispatcher.Register(event_type, callback_fn) — called at module init
;   time, before or after Start().
; - HookDispatcher.Start() — called once from ErgoptiPlus.ahk in the startup
;   section. Idempotent.
; - HookDispatcher.Stop() — releases the InputHook and all mouse Hotkeys.
;   Called by the script's OnExit handler if cleanup is needed.
;
; USAGE EXAMPLE:
;   ; In a module's init / start function:
;   HookDispatcher.Register("keyboard_char", MyModule_OnChar.Bind())
;   HookDispatcher.Register("mouse_lup",     MyModule_OnLUp.Bind())
;   ; Start is called centrally — do NOT call it per-module.
; ==============================================================================

#Requires AutoHotkey v2.0






; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

class HookDispatcherConst {
	; InputHook options: V = visible (events pass through to apps),
	; L0 = no length cutoff so OnChar fires for every character.
	static INPUT_HOOK_OPTS := "V L0"

	; Event type string constants — callers import these or use the
	; string literals directly; having them here prevents typos.
	static EVT_KB_CHAR    := "keyboard_char"
	static EVT_KB_DOWN    := "keyboard_down"
	static EVT_KB_UP      := "keyboard_up"
	static EVT_MS_LDOWN   := "mouse_ldown"
	static EVT_MS_LUP     := "mouse_lup"
	static EVT_MS_RDOWN   := "mouse_rdown"
	static EVT_MS_RUP     := "mouse_rup"
	static EVT_MS_MDOWN   := "mouse_mdown"
	static EVT_MS_MUP     := "mouse_mup"
	static EVT_MS_WUP     := "mouse_wup"
	static EVT_MS_WDN     := "mouse_wdn"
	static EVT_MS_WRIGHT  := "mouse_wright"
	static EVT_MS_WLEFT   := "mouse_wleft"
}





; ==================================
; ==================================
; ======= 2/ Singleton state =======
; ==================================
; ==================================

class HookDispatcher {
	; Map<event_type_string, Array<Func>> — populated by Register().
	static _subscribers := Map()

	; Live InputHook instance, or false when not yet started / after Stop().
	; Using false (not unset) so `_ih is InputHook` never throws on first boot
	; or after a Stop()/Start() cycle — `unset` makes the property unreadable
	; and the `is` operator raises PropertyError before it can evaluate.
	static _ih := false

	; Bound references for mouse Hotkey() calls so Stop() can disable them, or
	; false when not yet bound / after Stop(). Using false (not unset) so
	; `_hk_ldown is Func` never throws even without the HasOwnProp guard in
	; Stop() — the same PropertyError trap fixed for `_ih` above: an `unset`
	; static is unreadable, and `is` reads its left side before evaluating.
	static _hk_ldown  := false
	static _hk_lup    := false
	static _hk_rdown  := false
	static _hk_rup    := false
	static _hk_mdown  := false
	static _hk_mup    := false
	static _hk_wup    := false
	static _hk_wdn    := false
	static _hk_wright := false
	static _hk_wleft  := false

	; Guards against double-Start().
	static _started := false




	; =====================================================
	; ======================================
	; ======= 2.1) Subscriber registry =======
	; ======================================
	; =====================================================

	; Registers a callback for the given event type.
	; Idempotent per (event_type, callback_fn) pair — the same function
	; object will not be added twice for the same event type.
	; @param event_type {String} One of the HookDispatcherConst.EVT_* values.
	; @param callback_fn {Func} The function to call when the event fires.
	static Register(event_type, callback_fn) {
		local _prev_crit := Critical("On")
		try {
			if !HookDispatcher._subscribers.Has(event_type)
				HookDispatcher._subscribers[event_type] := Array()

			; Guard against duplicate registration — compare by object identity.
			; A BoundFunc (what every caller passes) has NO .Ptr property, so the
			; previous `existing.Ptr = callback_fn.Ptr` threw "has no property named
			; Ptr"; the bare try swallowed it and the .Push() below was skipped —
			; silently dropping every subscriber after the first for a given event
			; type (a whole feature went deaf to the keyboard). `==` is reference
			; identity for objects and never throws.
			for existing in HookDispatcher._subscribers[event_type] {
				if (existing == callback_fn)
					return
			}
			HookDispatcher._subscribers[event_type].Push(callback_fn)
			LoggerDebug("HookDispatcher", "Subscriber registered for '{1}' (total: {2}).",
				event_type, HookDispatcher._subscribers[event_type].Length)
		} finally {
			Critical(_prev_crit)
		}
	}

	; Removes a previously registered callback.
	; A no-op if the callback was never registered.
	; @param event_type {String} The event type to unsubscribe from.
	; @param callback_fn {Func} The function to remove.
	static Unregister(event_type, callback_fn) {
		local _prev_crit := Critical("On")
		try {
			if !HookDispatcher._subscribers.Has(event_type)
				return
			arr := HookDispatcher._subscribers[event_type]
			loop arr.Length {
				; Iterate in reverse so removal by index does not shift unvisited items
				idx := arr.Length - A_Index + 1
				; Identity compare — see Register(): .Ptr throws on a BoundFunc.
				if (arr[idx] == callback_fn) {
					arr.RemoveAt(idx)
					LoggerDebug("HookDispatcher", "Subscriber removed from '{1}'.", event_type)
					break
				}
			}
		} finally {
			Critical(_prev_crit)
		}
	}




	; ====================================================
	; ======================================
	; ======= 2.2) Internal dispatch =======
	; ======================================
	; ====================================================

	; Calls every registered subscriber for event_type, passing extra args.
	; Each callback is wrapped in try/catch so a broken subscriber cannot
	; prevent the remaining ones from running.
	; @param event_type {String} The event type to dispatch.
	; @param args* Variadic — forwarded as-is to each subscriber.
	static Dispatch(event_type, args*) {
		static _err_cache := Map()  ; Cap: .Count >= 256 triggers .Clear() before each .Has(sig) de-dup
		; Native Suspend only disarms hotkeys/hotstrings — this InputHook fan-out
		; keeps firing while paused, driving the LLM bridge and keylogger. Gate the
		; whole shared pipeline here so « pause = tout éteint » in one place.
		if A_IsSuspended
			return
		if !HookDispatcher._subscribers.Has(event_type)
			return
		; Iterate the live array in REVERSE index order. A subscriber that
		; Unregisters ITSELF from within its callback (the gesture click-hold
		; release path) calls arr.RemoveAt, which shifts only elements at
		; HIGHER indices — indices we have already visited in reverse order.
		; This makes the self-Unregister case safe without the per-event
		; Clone() heap allocation the old forward loop required.
		; NOTE: only safe for SELF-Unregister. A callback that removes a
		; PEER at a LOWER index during dispatch would still silently skip
		; the removed peer (not exercised by any production caller — the
		; gesture release is the sole self-Unregister consumer).
		arr := HookDispatcher._subscribers[event_type]
		loop arr.Length {
			cb := arr[arr.Length - A_Index + 1]
			try {
				cb(args*)
			} catch as e {
				sig := event_type . ":" . e.Message
				now := A_TickCount
				if (_err_cache.Count >= 256)
					_err_cache.Clear()
				if (!_err_cache.Has(sig) || ((now - _err_cache[sig]) & 0xFFFFFFFF) > 60000) {
					_err_cache[sig] := now
					try LoggerWarn("HookDispatcher", "Subscriber for '{1}' threw: {2}.", event_type, e.Message)
					; Escalate once per fault signature — releases stuck modifiers.
					try ErgoptiGlobalErrorHandler(e, "Continue")
				}
			}
		}
	}




	; ===========================================================
	; ==============================================
	; ======= 2.3) InputHook internal handlers =======
	; ==============================================
	; ===========================================================

	; Bound to IH.OnChar — receives (ih, char) from AHK.
	static _OnChar(ih, char) {
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_CHAR, ih, char)
	}

	; Bound to IH.OnKeyDown — receives (ih, vk, sc) from AHK.
	static _OnKeyDown(ih, vk, sc) {
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_DOWN, ih, vk, sc)
	}

	; Bound to IH.OnKeyUp — receives (ih, vk, sc) from AHK.
	static _OnKeyUp(ih, vk, sc) {
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_UP, ih, vk, sc)
	}




	; =====================================================
	; ========================================
	; ======= 2.4) Mouse internal handlers =======
	; ========================================
	; =====================================================

	static _OnLDown(*) {
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_MS_LDOWN)
	}
	static _OnLUp(*) {
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_MS_LUP)
	}
	static _OnRDown(*) {
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_MS_RDOWN)
	}
	static _OnRUp(*) {
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_MS_RUP)
	}
	static _OnMDown(*) {
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_MS_MDOWN)
	}
	static _OnMUp(*) {
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_MS_MUP)
	}
	static _OnWheelUp(*) {
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_MS_WUP)
	}
	static _OnWheelDown(*) {
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_MS_WDN)
	}
	static _OnWheelRight(*) {
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_MS_WRIGHT)
	}
	static _OnWheelLeft(*) {
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_MS_WLEFT)
	}




	; ==========================================
	; ==============================
	; ======= 2.5) Lifecycle =======
	; ==============================
	; ==========================================

	; Starts the unified InputHook and mouse Hotkeys.
	; Must be called exactly once from ErgoptiPlus.ahk after all modules
	; have registered their subscribers. Idempotent — a second call is a no-op.
	static Start() {
		if HookDispatcher._started {
			LoggerWarn("HookDispatcher", "Start() called more than once — ignoring duplicate call.")
			return
		}
		LoggerStart("HookDispatcher", "Starting unified hook dispatcher…")

		; ── InputHook ────────────────────────────────────────────────────────
		; Reuse a live InputHook if one already exists. A partial Start failure
		; (a mouse Hotkey throwing below) leaves _started false but the InputHook
		; live; without this guard a retry would create a SECOND InputHook racing
		; the first for the key stream — the multi-hook contention this module
		; exists to prevent.
		if HookDispatcher._ih is InputHook {
			ih := HookDispatcher._ih
		} else {
			; Construction/configuration/.Start() is guarded — symmetric with the
			; safe-hotkey-wrapper pattern used for the mouse hotkeys below. Contested
			; low-level hook creation (RDP, another AHK/accessibility tool,
			; transient OS resource exhaustion) can throw here; the bare call from
			; ErgoptiPlus.ahk would otherwise only be caught by the global error
			; handler, leaving every hook-dependent feature (remap, hotstrings,
			; keylogger, CapsWord cancel, gestures, LLM dismiss-on-click) silently
			; dead for the rest of the session with no dispatcher-specific signal.
			try {
				ih := InputHook(HookDispatcherConst.INPUT_HOOK_OPTS)
				; Notify on every key (no end-key filter needed)
				ih.KeyOpt("{All}", "+N")
				; Non-text keys (arrows, F-keys, Esc, BS, Enter) must raise OnKeyDown
				ih.NotifyNonText := true
				ih.OnChar    := HookDispatcher._OnChar.Bind(HookDispatcher)
				ih.OnKeyDown := HookDispatcher._OnKeyDown.Bind(HookDispatcher)
				ih.OnKeyUp   := HookDispatcher._OnKeyUp.Bind(HookDispatcher)
				ih.Start()
				HookDispatcher._ih := ih
			} catch as e {
				; The InputHook is the only non-recoverable resource here — bail
				; out so _started stays false rather than proceeding with a dead
				; or half-configured hook (fail-fast, §5.3).
				LoggerError("HookDispatcher", "InputHook construction failed: {1} — hook-dependent features unavailable this session.", e.Message)
				return
			}
		}

		; The InputHook (the only non-recoverable resource) is now live, so the
		; dispatcher is functionally started. Set the flag BEFORE the optional
		; mouse hotkeys so a later per-hotkey failure cannot leave _started false
		; with a live hook (which would invite the duplicate-InputHook race above).
		HookDispatcher._started := true

		; ── Mouse Hotkeys ─────────────────────────────────────────────────────
		; Bind once, store references so Stop() can disable them cleanly.
		; The ~ prefix ensures the event is NOT consumed by AHK — the target
		; application still receives the click/wheel event normally.
		HookDispatcher._hk_ldown  := HookDispatcher._OnLDown.Bind(HookDispatcher)
		HookDispatcher._hk_lup    := HookDispatcher._OnLUp.Bind(HookDispatcher)
		HookDispatcher._hk_rdown  := HookDispatcher._OnRDown.Bind(HookDispatcher)
		HookDispatcher._hk_rup    := HookDispatcher._OnRUp.Bind(HookDispatcher)
		HookDispatcher._hk_mdown  := HookDispatcher._OnMDown.Bind(HookDispatcher)
		HookDispatcher._hk_mup    := HookDispatcher._OnMUp.Bind(HookDispatcher)
		HookDispatcher._hk_wup    := HookDispatcher._OnWheelUp.Bind(HookDispatcher)
		HookDispatcher._hk_wdn    := HookDispatcher._OnWheelDown.Bind(HookDispatcher)
		HookDispatcher._hk_wright := HookDispatcher._OnWheelRight.Bind(HookDispatcher)
		HookDispatcher._hk_wleft  := HookDispatcher._OnWheelLeft.Bind(HookDispatcher)

		; Guard each Hotkey() individually: on a hardened machine or unusual input
		; stack a single wheel/button registration can be rejected. Aborting the
		; whole Start on one rejection would leave a live InputHook with _started
		; mis-set; instead log a WARNING and keep the rest of the pipeline up.
		HookDispatcher._SafeHotkey("~LButton",    HookDispatcher._hk_ldown)
		HookDispatcher._SafeHotkey("~LButton Up", HookDispatcher._hk_lup)
		HookDispatcher._SafeHotkey("~RButton",    HookDispatcher._hk_rdown)
		HookDispatcher._SafeHotkey("~RButton Up", HookDispatcher._hk_rup)
		HookDispatcher._SafeHotkey("~MButton",    HookDispatcher._hk_mdown)
		HookDispatcher._SafeHotkey("~MButton Up", HookDispatcher._hk_mup)
		HookDispatcher._SafeHotkey("~WheelUp",    HookDispatcher._hk_wup)
		HookDispatcher._SafeHotkey("~WheelDown",  HookDispatcher._hk_wdn)
		HookDispatcher._SafeHotkey("~WheelRight", HookDispatcher._hk_wright)
		HookDispatcher._SafeHotkey("~WheelLeft",  HookDispatcher._hk_wleft)

		LoggerSuccess("HookDispatcher", "Unified hook dispatcher started ({1} event type(s) with subscribers).",
			HookDispatcher._subscribers.Count)
	}

	; Registers a single mouse Hotkey, logging a WARNING (instead of throwing) if
	; the OS rejects it. Used by Start() so one unsupported mouse event cannot
	; abort the whole start sequence and orphan the live InputHook.
	; @param key_name {String} The Hotkey() key spec (e.g. "~WheelLeft").
	; @param callback_fn {Func} The bound handler to register.
	static _SafeHotkey(key_name, callback_fn) {
		try {
			Hotkey(key_name, callback_fn, "On")
		} catch as e {
			LoggerWarn("HookDispatcher", "Mouse hotkey '{1}' could not be registered: {2}.", key_name, e.Message)
		}
	}

	; Releases the InputHook and disables all mouse Hotkeys.
	; Safe to call when not started. Registered as the process OnExit handler from
	; ErgoptiPlus.ahk so the InputHook is released explicitly on a plain ExitApp,
	; not just when Reload() tears the process down.
	static Stop() {
		if !HookDispatcher._started
			return
		LoggerStart("HookDispatcher", "Stopping unified hook dispatcher…")

		; Release InputHook
		if HookDispatcher._ih is InputHook {
			try HookDispatcher._ih.Stop()
			HookDispatcher._ih := false
		}

		; Disable mouse Hotkeys
		if HookDispatcher.HasOwnProp("_hk_ldown") && HookDispatcher._hk_ldown is Func {
			try Hotkey("~LButton",    HookDispatcher._hk_ldown,  "Off")
			try Hotkey("~LButton Up", HookDispatcher._hk_lup,    "Off")
			try Hotkey("~RButton",    HookDispatcher._hk_rdown,  "Off")
			try Hotkey("~RButton Up", HookDispatcher._hk_rup,    "Off")
			try Hotkey("~MButton",    HookDispatcher._hk_mdown,  "Off")
			try Hotkey("~MButton Up", HookDispatcher._hk_mup,    "Off")
			try Hotkey("~WheelUp",    HookDispatcher._hk_wup,    "Off")
			try Hotkey("~WheelDown",  HookDispatcher._hk_wdn,    "Off")
			try Hotkey("~WheelRight", HookDispatcher._hk_wright, "Off")
			try Hotkey("~WheelLeft",  HookDispatcher._hk_wleft,  "Off")
		}

		; Reset the hotkey references to false so a subsequent Start() rebinds
		; cleanly rather than reusing stale BoundFuncs. false (not unset) keeps
		; `_hk_ldown is Func` readable on a second Stop() with no live hotkeys.
		HookDispatcher._hk_ldown  := false
		HookDispatcher._hk_lup    := false
		HookDispatcher._hk_rdown  := false
		HookDispatcher._hk_rup    := false
		HookDispatcher._hk_mdown  := false
		HookDispatcher._hk_mup    := false
		HookDispatcher._hk_wup    := false
		HookDispatcher._hk_wdn    := false
		HookDispatcher._hk_wright := false
		HookDispatcher._hk_wleft  := false

		; Clear the subscriber registry so a fresh Start() begins with an empty
		; fan-out table. Without this a Stop()/Start() cycle would inherit the
		; previous (possibly stale) subscribers and double-fire every event.
		HookDispatcher._subscribers := Map()

		HookDispatcher._started := false
		LoggerSuccess("HookDispatcher", "Unified hook dispatcher stopped.")
	}
}
