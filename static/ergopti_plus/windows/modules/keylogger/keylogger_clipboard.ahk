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
; 2. Clipboard paste detection — when the user presses Ctrl+V (or
;    Shift+Insert) we emit a clipboard_paste event. Pairing it with the
;    last clipboard_copy gives the copy→paste interval and reveals whether
;    the user is collage-typing (copy, immediately paste elsewhere) or has
;    the clipboard as a staging buffer.
; 3. Paste burst — if more than PASTE_BURST_THRESHOLD paste events occur
;    within PASTE_BURST_WINDOW_MS a paste_burst event is emitted. Paste
;    bursts indicate research-heavy or template-assembly work patterns that
;    are qualitatively different from original composition.
; 4. Privacy — only the character count (StrLen) and content type are
;    stored; the raw clipboard text is never written to any log. Image
;    clipboards are logged as type "image" with size 0.
;
; INTEGRATION:
; KL_Clip_Start() must be called after KL_Init(). It installs an
; OnClipboardChange callback and two pass-through hotkeys (Ctrl+V and
; Shift+Insert) that forward the event before passing through to the app.
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





; ========================================
; ========================================
; ======= 4/ Paste hotkey handlers =======
; ========================================
; ========================================

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

		; Register the clipboard observer and both pass-through paste hotkeys as
		; one transaction.  A rejection after the first Hotkey used to leave a
		; half-live observer/hotkey set and an unhandled boot exception.
		Handler := KL_Clip_OnChange
		ClipboardRegistered := false
		try {
				; Adapter writes made before observation started have no corresponding
				; callback for this handler and must not consume the first user change.
				CB_DiscardOwnedNotifications()
				OnClipboardChange(Handler)
				ClipboardRegistered := true
				; ``~`` ensures the paste still reaches the active application unchanged.
				Hotkey("~^v",      KL_Clip_OnPasteHK, "On")
				Hotkey("~+Insert", KL_Clip_OnPasteHK, "On")
				KLClip.clip_handler := Handler
				return true
		} catch as Err {
				try Hotkey("~^v",      KL_Clip_OnPasteHK, "Off")
				try Hotkey("~+Insert", KL_Clip_OnPasteHK, "Off")
				if ClipboardRegistered
						try OnClipboardChange(Handler, 0)
				LoggerError("Keylogger", "Clipboard observer registration failed: {1}", Err.Message)
				return false
		}
}

KL_Clip_OnPasteHK(*) {
		try KL_Clip_OnPaste()
}

KL_Clip_Stop() {
		if KLClip.HasOwnProp("clip_handler") && IsObject(KLClip.clip_handler) {
				try OnClipboardChange(KLClip.clip_handler, 0)
				KLClip.clip_handler := unset
		}
		try Hotkey("~^v",      KL_Clip_OnPasteHK, "Off")
		try Hotkey("~+Insert", KL_Clip_OnPasteHK, "Off")
		CB_DiscardOwnedNotifications()
		_KL_Clip_InvalidateProvenance()
		KLClip.paste_ticks := []
}
