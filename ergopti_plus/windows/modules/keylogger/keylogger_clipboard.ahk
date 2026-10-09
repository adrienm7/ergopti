; modules/keylogger/keylogger_clipboard.ahk

_KL_Clip_CharCountFromBuffer(TextPtr, ByteCapacity) {
		if (!TextPtr || ByteCapacity < 2)
				return 0
		MaxCodeUnits := Min(ByteCapacity // 2, KLClipConst.MAX_CHAR_COUNT + 1)
		CodeUnits := DllCall("msvcrt\wcsnlen", "Ptr", TextPtr, "UPtr", MaxCodeUnits, "CDecl UPtr")
		return Min(CodeUnits, KLClipConst.MAX_CHAR_COUNT)
}

; ==============================================================================
; MODULE: Keylogger Clipboard
; DESCRIPTION:
; Monitors clipboard activity to surface copy/paste patterns and detect
; paste-heavy typing sessions (research/collage) vs. original composition.
;
; FEATURES & RATIONALE:
; 1. Clipboard copy — registered via OnClipboardChange which fires whenever
;    any application writes to the clipboard. Records the content type
;    (text/image/other), the text length in characters (never the raw text
;    — only the count), and the source app. This lets the dashboard show
;    "copy rate" alongside keystrokes without ever storing clipboard content.
; 2. Clipboard paste detection — when the application receives Ctrl+V (or
;    Shift+Insert) we emit a clipboard_paste event. Pairing it with the
;    last clipboard_copy gives the copy→paste interval and reveals whether
;    the user is collage-typing (copy, immediately paste elsewhere) or has
;    the clipboard as a staging buffer. The chord is observed on the shared
;    InputHook (HookDispatcher), after every hotkey decision, never claimed by
;    a hotkey: the driver declares every character key by scan code (the AltGr
;    layer, the layout emulation), so AutoHotkey's hook resolves those keys
;    through their scan code only (hook.cpp: ChangeHookState sets
;    sc_takes_precedence, LowLevelCommon looks up the scan-code table alone)
;    and the former "~^v" hotkey, named by its virtual key, never fired.
;    Declaring it by scan code instead cannot work either: the key carrying
;    VK_V follows the foreground layout, and a scan-code variant competes with
;    the emulation's and the navigation layer's hotkeys of the same key.
; 3. Paste burst — if more than PASTE_BURST_THRESHOLD paste events occur
;    within PASTE_BURST_WINDOW_MS a paste_burst event is emitted. Paste
;    bursts indicate research-heavy or template-assembly work patterns that
;    are qualitatively different from original composition.
; 4. Privacy — only the character count (StrLen) and content type are
;    stored; the raw clipboard text is never written to any log. Image
;    clipboards are logged as type "image" with size 0.
;
; INTEGRATION:
; KL_Clip_Start() must be called after KL_Init() and HookDispatcher.Start().
; It installs an OnClipboardChange callback and subscribes KL_Clip_OnKeyDown
; to the dispatcher's key-down events, which recognises the paste chords.
; ==============================================================================

#Requires Autohotkey v2.0+





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

class KLClipConst {
		; Number of paste events within the window that triggers a paste_burst
		static PASTE_BURST_THRESHOLD   := 5
		; Time window (ms) for the burst count
		static PASTE_BURST_WINDOW_MS   := 10000
		; Max character count to store (cap to avoid storing huge clipboard counts
		; that would reveal document length)
		static MAX_CHAR_COUNT          := 100000
		; Virtual keys of the paste chords (WinUser.h). The application's paste
		; accelerator is VK_V whatever physical key carries it on the layout.
		static VK_V                    := 0x56
		static VK_INSERT               := 0x2D
}





; ===============================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===============================

class KLClip {
		; Last copy snapshot
		static last_copy_tick   := 0
		static last_copy_len    := 0
		static last_copy_app    := ""

		; Paste burst accumulator
		static paste_ticks      := []   ; ring of recent paste A_TickCounts

		; OnClipboardChange reference
	static clip_handler     := unset
}

; Optional zero-arity privacy probe used only by the headless regression suite.
; Production keeps the sentinel 0 and resolves the real cached focus filter.
global _KL_CLIP_FILTER_PROBE := 0

_KL_Clip_ShouldFilter() {
	global _KL_CLIP_FILTER_PROBE
	if IsObject(_KL_CLIP_FILTER_PROBE)
		return _KL_CLIP_FILTER_PROBE.Call()
	try return MF_ShouldFilter()
	catch as Err {
		; Provenance is privacy-sensitive too: retaining a secret generation's
		; length/source after the filter failed would leak it on a later paste.
		try LoggerWarn("Keylogger", "Clipboard privacy probe failed closed: {1}", Err.Message)
		return true
	}
}

; The three fields describe one clipboard generation and must never be observed
; half-updated by the paste hotkey.  Keep only the in-memory swap Critical; OS
; clipboard probes and the deferred log sink stay outside it.
_KL_Clip_InvalidateProvenance() {
	PreviousCritical := Critical("On")
	try {
		KLClip.last_copy_tick := 0
		KLClip.last_copy_len := 0
		KLClip.last_copy_app := ""
	} finally {
		Critical(PreviousCritical)
	}
}





; ===========================================
; ===========================================
; ======= 3/ Clipboard change handler =======
; ===========================================
; ===========================================

KL_Clip_OnChange(data_type) {
		; Consume ownership before every lifecycle/privacy return. Otherwise a
		; callback delivered while suspended leaves its FIFO record behind and the
		; next genuine user copy is mistaken for driver traffic after resume.
		OwnedKind := CB_ConsumeOwnedChange()
		if OwnedKind is String {
				; A persistent driver write (copy path, colour value, health report)
				; replaces the clipboard but is not a user copy. Suppress its row and
				; make the next paste provenance unknown. Temporary transport mutations
				; preserve the genuine snapshot which their restore puts back.
				if (OwnedKind == "replace")
						_KL_Clip_InvalidateProvenance()
				return
		}
		if !Keylogger.initialized
				return
		filtered := _KL_Clip_ShouldFilter()
		if filtered {
				; The callback still proves the clipboard generation changed. Keeping
				; public metadata A here attributes a later paste of private B to A.
				_KL_Clip_InvalidateProvenance()
				return
		}

		; data_type: 1 = text, 2 = image, 0 = clipboard cleared
		if (data_type = 0) {
				_KL_Clip_InvalidateProvenance()
				return
		}
		; Pause suppresses telemetry but not Windows clipboard notifications. A
		; change made while paused must still retire pre-pause provenance so resume
		; cannot publish a stale source/length on the next physical paste.
		if A_IsSuspended {
				_KL_Clip_InvalidateProvenance()
				return
		}

		content_type := (data_type = 1) ? "text" : "other"
		char_count   := 0
		if (data_type = 1) {
				try {
						if DllCall("OpenClipboard", "Ptr", 0) {
								if hData := DllCall("GetClipboardData", "UInt", 13, "Ptr") { ; CF_UNICODETEXT
										ptr := DllCall("GlobalLock", "Ptr", hData, "Ptr")
										if ptr {
												bytes := DllCall("GlobalSize", "Ptr", hData, "UPtr")
												char_count := _KL_Clip_CharCountFromBuffer(ptr, bytes)
												DllCall("GlobalUnlock", "Ptr", hData)
										}
								}
								DllCall("CloseClipboard")
						}
				}
		}

		Now := A_TickCount
		App := Keylogger.session_app
		PreviousCritical := Critical("On")
		try {
				KLClip.last_copy_tick := Now
				KLClip.last_copy_len  := char_count
				KLClip.last_copy_app  := App
		} finally {
				Critical(PreviousCritical)
		}

		KL_AppendLog(Map(
				"type",         "clipboard_copy",
				"app",          App,
				"content_type", content_type,
				"char_count",   char_count
		))
}





; =================================
; =================================
; ======= 4/ Paste handlers =======
; =================================
; =================================

; Whether a key-down the application receives is a paste chord: Ctrl+V or
; Shift+Insert with no other modifier, as the former "^v" and "+Insert" hotkeys
; required. The modifiers are read logically, as the application reads them, so
; a Ctrl held by a tap-hold counts like the physical one.
; @param Vk {Integer} Virtual key of the key-down.
; @param KeyIsDownFn {Func} Takes a key name, returns whether it is down.
; @return {Boolean}
_KL_Clip_IsPasteChord(Vk, KeyIsDownFn) {
		if (Vk != KLClipConst.VK_V && Vk != KLClipConst.VK_INSERT)
				return false
		Ctrl := KeyIsDownFn.Call("Ctrl")
		Shift := KeyIsDownFn.Call("Shift")
		if KeyIsDownFn.Call("Alt") || KeyIsDownFn.Call("LWin") || KeyIsDownFn.Call("RWin")
				return false
		if (Vk == KLClipConst.VK_V)
				return Ctrl && !Shift
		return Shift && !Ctrl
}

_KL_Clip_KeyIsLogicallyDown(KeyName) {
		return GetKeyState(KeyName) ? true : false
}

; HookDispatcher EVT_KB_DOWN subscriber. The shared InputHook ("V L0 I1") sees a
; key only once no hotkey suppressed it, physical or sent at SendLevel 1 and
; above: the layout emulation's own Ctrl+V (level 2) and the user's native one
; alike, never the driver's level-0 TextSender paste.
KL_Clip_OnKeyDown(ih, vk, sc) {
		if _KL_Clip_IsPasteChord(vk, _KL_Clip_KeyIsLogicallyDown)
				KL_Clip_OnPaste()
}

KL_Clip_OnPaste() {
		; Synthetic Ctrl+V can arrive while the clipboard's deferred restore is
		; still pending. The shared transaction token, not keyboard timing, owns it.
		if CB_IsDriverPasteActive()
				return
		if !Keylogger.initialized
				return
		if A_IsSuspended
				return
		filtered := _KL_Clip_ShouldFilter()
		if filtered
				return

		now := A_TickCount
		App := Keylogger.session_app
		PreviousCritical := Critical("On")
		try {
				CopyTick := KLClip.last_copy_tick
				CopyLen := KLClip.last_copy_len
				CopyApp := KLClip.last_copy_app
				copy_lag := (CopyTick > 0) ? ((now - CopyTick) & 0xFFFFFFFF) : -1
				KLClip.paste_ticks.Push(now)
				fresh := []
				for _, PasteTick in KLClip.paste_ticks {
						if (((now - PasteTick) & 0xFFFFFFFF) <= KLClipConst.PASTE_BURST_WINDOW_MS)
								fresh.Push(PasteTick)
				}
				EmitBurst := fresh.Length >= KLClipConst.PASTE_BURST_THRESHOLD
				KLClip.paste_ticks := EmitBurst ? [] : fresh
		} finally {
				Critical(PreviousCritical)
		}

		KL_AppendLog(Map(
				"type",         "clipboard_paste",
				"app",          App,
				"char_count",   CopyLen,
				"copy_lag_ms",  copy_lag,
				"source_app",   CopyApp
		))

		if EmitBurst {
				KL_AppendLog(Map(
						"type",   "paste_burst",
						"app",    App,
						"count",  fresh.Length,
						"window_ms", KLClipConst.PASTE_BURST_WINDOW_MS
				))
		}
}





; ============================
; ============================
; ======= 5/ Lifecycle =======
; ============================
; ============================

KL_Clip_Start() {
		if KLClip.HasOwnProp("clip_handler") && IsObject(KLClip.clip_handler)
				return true

		; Register the clipboard observer and the paste-chord observer as one
		; transaction.  A rejection after the first registration used to leave a
		; half-live observer set and an unhandled boot exception.
		Handler := KL_Clip_OnChange
		ClipboardRegistered := false
		OwnershipObserverActive := false
		PasteObserverRegistered := false
		try {
				; Adapter writes made before observation started have no corresponding
				; callback for this handler and must not consume the first user change.
				PreviousCritical := Critical("On")
				try {
						CB_DiscardOwnedNotifications()
						OnClipboardChange(Handler)
						ClipboardRegistered := true
						CB_SetOwnershipObserverActive(true)
						OwnershipObserverActive := true
				} finally {
						Critical(PreviousCritical)
				}
				; An observer, not a hotkey: the paste still reaches the application
				; unchanged, and no hotkey of the key can shadow or be shadowed by it.
				HookDispatcher.Register(HookDispatcherConst.EVT_KB_DOWN, KL_Clip_OnKeyDown)
				PasteObserverRegistered := true
				KLClip.clip_handler := Handler
				return true
		} catch as Err {
				if PasteObserverRegistered
						HookDispatcher.Unregister(HookDispatcherConst.EVT_KB_DOWN, KL_Clip_OnKeyDown)
				PreviousCritical := Critical("On")
				try {
						if ClipboardRegistered
								try OnClipboardChange(Handler, 0)
						if OwnershipObserverActive
								CB_SetOwnershipObserverActive(false)
				} finally {
						Critical(PreviousCritical)
				}
				LoggerError("Keylogger", "Clipboard observer registration failed: {1}", Err.Message)
				return false
		}
}

KL_Clip_Stop() {
		PreviousCritical := Critical("On")
		try {
				if KLClip.HasOwnProp("clip_handler") && IsObject(KLClip.clip_handler) {
						try OnClipboardChange(KLClip.clip_handler, 0)
						KLClip.clip_handler := unset
				}
				CB_SetOwnershipObserverActive(false)
		} finally {
				Critical(PreviousCritical)
		}
		HookDispatcher.Unregister(HookDispatcherConst.EVT_KB_DOWN, KL_Clip_OnKeyDown)
		_KL_Clip_InvalidateProvenance()
		KLClip.paste_ticks := []
}
