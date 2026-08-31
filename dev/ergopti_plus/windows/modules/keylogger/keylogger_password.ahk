; modules/keylogger/keylogger_password.ahk

; ==============================================================================
; MODULE: Keylogger - Password Field Filter
; DESCRIPTION:
; Secure / password-field detection (UIA + heuristics) for privacy filtering. Mirrors the macOS context_tracker password detection.
;
; Extracted from keylogger.ahk (audit F1) and #Include'd in place by it. Pure
; definitions only - AHK resolves these symbols across the whole compilation
; unit, so the include position does not affect behaviour.
; ==============================================================================

; Triple-layered detector — any positive layer returns true:
;
;   1. Win32 Edit class with ES_PASSWORD style
;      Native edit boxes (Win32 dialogs, old apps, RDP, Win Logon) expose
;      their password mode through ES_PASSWORD (0x20). Cheapest check.
;
;   2. Class-name allow-list
;      Some controls don't honour ES_PASSWORD but reliably advertise their
;      role via class name (e.g. WPF "PasswordBox", winforms RichEdit50W
;      hosted in credential dialogs).
;
;   3. UIA IsPasswordPattern (vendor/UIA.ahk)
;      The canonical UIA property — works for modern Edge/Chrome web
;      passwords, UWP password boxes, .NET WPF, Electron apps. Slowest
;      check, called last.
;
; Negative results are cached for ``KLPW_CACHE_TTL_MS`` only under the exact
; focused-element identity and focus generation that produced them. Chromium,
; Electron and WPF host multiple fields behind one HWND, so the host handle is
; not an identity boundary. EVENT_OBJECT_FOCUS invalidates the element token
; before another verdict can be reused.

global KLPW_CACHE_TTL_MS := 2000

class KLPasswordCache {
		static last_hwnd := 0
		static last_at   := 0
		static last_val  := false
		static last_focus_generation := 0
		static last_element_id := ""
		; Monotonic publication epoch used by output-journal transactions. A
		; password verdict changing between their open-thread privacy check and
		; RAM commit invalidates telemetry fail-closed without blocking output.
		static generation := 0
		; HWND with an in-flight async UIA confirmation — guards the scheduler so a
		; burst of keystrokes on the same not-yet-classified control cannot pile up
		; one-shot timers.
		static pending_hwnd := 0
		static pending_focus_generation := 0
		; EVENT_OBJECT_FOCUS is the synchronous invalidation boundary. The current
		; UIA RuntimeId is published only by a probe owned by this generation.
		static focus_generation := 1
		static current_element_id := ""
		static focus_hook := 0
		static focus_callback := 0
		static focus_tracking_active := false
}

; Publishes a focused-element verdict to the password cache as a single logical
; commit. last_hwnd is the COMMIT FLAG and is therefore written LAST: the
; keystroke reader matches on last_hwnd, so by the time it observes the new
; hwnd, last_val and last_at already correspond to that hwnd. Without this
; ordering an interrupt between the writes (KL_AsyncPasswordDetect runs on a
; separate pseudo-thread from the reader) could expose last_hwnd matched but
; last_val still holding the previous control's verdict — a single-keystroke
; privacy leak (password char logged) or metric suppression at field
; transitions. The single source of truth for cache-write ordering: every
; writer goes through here, never touches the fields in another order.
KL_CommitPwCache(hwnd, at, val, FocusGeneration := unset, ElementId := unset) {
		if !IsSet(FocusGeneration)
				FocusGeneration := KLPasswordCache.focus_generation
		if !IsSet(ElementId)
				ElementId := "hwnd:" . hwnd
		PreviousCritical := Critical("On")
		try {
				Changed := (KLPasswordCache.last_hwnd != hwnd
						|| KLPasswordCache.last_val != val
						|| KLPasswordCache.last_focus_generation != FocusGeneration
						|| KLPasswordCache.last_element_id !== ElementId)
				KLPasswordCache.last_val := val ? true : false
				KLPasswordCache.last_at := at
				KLPasswordCache.last_focus_generation := FocusGeneration
				KLPasswordCache.last_element_id := ElementId
				if (FocusGeneration = KLPasswordCache.focus_generation)
						KLPasswordCache.current_element_id := ElementId
				if Changed
						KLPasswordCache.generation += 1
				KLPasswordCache.last_hwnd := hwnd   ; commit flag — must be assigned LAST
		} finally {
				Critical(PreviousCritical)
		}
}

; Zero-allocation lookup for the keystroke path. Returns true only when Secure
; received a verdict for the exact focused element. A negative result requires
; the focus hook to be live; losing the invalidator must never turn an
; HWND-scoped cache back into policy.
KL_TryGetPwCachedVerdict(hwnd, FocusGeneration, ElementId, &Secure) {
		global KLPW_CACHE_TTL_MS
		Secure := true
		PreviousCritical := Critical("On")
		try {
				Matches := (KLPasswordCache.last_hwnd = hwnd
						and KLPasswordCache.last_focus_generation = FocusGeneration
						and ElementId != ""
						and KLPasswordCache.last_element_id == ElementId
						and ((A_TickCount - KLPasswordCache.last_at) & 0xFFFFFFFF)
								< KLPW_CACHE_TTL_MS)
				if !Matches
						return false
				if (!KLPasswordCache.last_val
						and !KLPasswordCache.focus_tracking_active)
						return false
				Secure := KLPasswordCache.last_val
				return true
		} finally {
				Critical(PreviousCritical)
		}
}

; Typed wrapper for tests and non-hot-path callers. Unknown remains secure by
; construction so callers cannot accidentally treat a cache miss as ordinary.
KL_PwCachedVerdict(hwnd, FocusGeneration, ElementId) {
		Secure := true
		Known := KL_TryGetPwCachedVerdict(hwnd, FocusGeneration, ElementId, &Secure)
		return KL_PwVerdict(Known, Secure, Known ? ElementId : "")
}

KL_PasswordFocusSnapshot() {
		PreviousCritical := Critical("On")
		try return {
				Generation: KLPasswordCache.focus_generation,
				ElementId: KLPasswordCache.current_element_id
		}
		finally Critical(PreviousCritical)
}

; Invalidates both negative cache reuse and any output-journal transaction that
; opened under the previous focused element.
KL_InvalidatePasswordFocus(*) {
		PreviousCritical := Critical("On")
		try {
				KLPasswordCache.focus_generation += 1
				KLPasswordCache.current_element_id := ""
				KLPasswordCache.generation += 1
				return KLPasswordCache.focus_generation
		} finally {
				Critical(PreviousCritical)
		}
}

; Known non-Edit password class names (Layer 2). Module-level so the cheap
; synchronous classifier and the full UIA detector share one source of truth.
global KL_PASSWORD_CLASSES := Map(
		"PasswordBox", true,           ; WPF / UWP
		"Edit;PASSWORD", true,         ; some older toolkits
		"TPasswordEdit", true,         ; Delphi
		"MaskedEdit", true,
		"TFormPassword", true
)

; Pure Win32 class/style verdict (Layers 1-2): no OS calls, the caller passes
; the already-read class and style. Conclusive is set true when the Win32 layer
; alone fully decides the field — the Edit class is authoritative via its
; ES_PASSWORD bit, and a known password class is a definite yes. When Conclusive
; is false the control is a non-Edit / unknown one that only UIA can classify,
; so the caller must fall through to the (off-thread) UIA layer. Kept pure so it
; can be exercised headlessly.
KL_PwClassStyleVerdict(Cls, Style, &Conclusive) {
		global KL_PASSWORD_CLASSES
		if (Cls = "Edit") {
				Conclusive := true
				return (Style & 0x20) ? true : false   ; ES_PASSWORD
		}
		if KL_PASSWORD_CLASSES.Has(Cls) {
				Conclusive := true
				return true
		}
		Conclusive := false
		return false
}

; Cheap synchronous classification — Win32 class/style only, never UIA, so it is
; safe to call on the keystroke thread. Conclusive mirrors KL_PwClassStyleVerdict;
; a window that cannot be read leaves it false so the caller fails safe.
KL_DetectPasswordCheap(hwnd, &Conclusive) {
		Conclusive := false
		Cls := ""
		Style := 0
		try {
				Cls := WinGetClass("ahk_id " . hwnd)
				if (Cls = "Edit")
						Style := WinGetStyle("ahk_id " . hwnd)
		} catch {
				return false
		}
		return KL_PwClassStyleVerdict(Cls, Style, &Conclusive)
}

KL_FocusedHostHwnd() {
		hwnd := 0
		try hwnd := ControlGetHwnd(ControlGetFocus("A"), "A")
		if !hwnd
				try hwnd := WinGetID("A")
		return hwnd
}

; WinEventProc for EVENT_OBJECT_FOCUS. It performs no COM work: invalidation is
; the only operation that must happen at the event boundary; the next deferred
; detector publishes the new RuntimeId and password verdict together.
KL_PasswordFocusEventCallback(*) {
		try KL_InvalidatePasswordFocus()
		catch as err
				try LoggerError("Keylogger", "Password focus invalidation callback failed: {1}.", err.Message)
}

KL_FreePasswordFocusCallback(CallbackPtr) {
		if !CallbackPtr
				return true
		try {
				CallbackFree(CallbackPtr)
				return true
		} catch as err {
				try LoggerWarn("Keylogger", "Password focus callback teardown failed: {1}.", err.Message)
		}
		return false
}

KL_RetainPasswordFocusCallback(CallbackPtr) {
		if !CallbackPtr
				return
		PreviousCritical := Critical("On")
		try KLPasswordCache.focus_callback := CallbackPtr
		finally Critical(PreviousCritical)
}

KL_PasswordFocusTrackingStart() {
		if KLPasswordCache.focus_tracking_active
				return true
		if (KLPasswordCache.focus_hook or KLPasswordCache.focus_callback) {
				try LoggerError("Keylogger", "Password focus tracking cannot restart while teardown ownership is retained.")
				return false
		}
		if IsSet(_AHK_DRY_RUN)
				return false
		CallbackPtr := 0
		try CallbackPtr := CallbackCreate(KL_PasswordFocusEventCallback, "F", 7)
		catch as err {
				try LoggerError("Keylogger", "Password focus tracking callback creation failed: {1}.", err.Message)
				return false
		}
		Hook := 0
		try Hook := DllCall("SetWinEventHook",
				"UInt", 0x8005,  ; EVENT_OBJECT_FOCUS
				"UInt", 0x8005,
				"Ptr", 0,
				"Ptr", CallbackPtr,
				"UInt", 0,
				"UInt", 0,
				"UInt", 0,
				"Ptr")
		catch as err {
				if !KL_FreePasswordFocusCallback(CallbackPtr)
						KL_RetainPasswordFocusCallback(CallbackPtr)
				try LoggerError("Keylogger", "Password focus tracking hook creation failed: {1}.", err.Message)
				return false
		}
		if !Hook {
				if !KL_FreePasswordFocusCallback(CallbackPtr)
						KL_RetainPasswordFocusCallback(CallbackPtr)
				try LoggerError("Keylogger", "Password focus tracking hook failed; ordinary UIA verdicts will remain fail-closed.")
				return false
		}
		PreviousCritical := Critical("On")
		try {
				KLPasswordCache.focus_callback := CallbackPtr
				KLPasswordCache.focus_hook := Hook
				KLPasswordCache.focus_tracking_active := true
				KLPasswordCache.current_element_id := ""
				KLPasswordCache.focus_generation += 1
		} finally {
				Critical(PreviousCritical)
		}
		return true
}

KL_PasswordFocusTrackingStop() {
		if (!KLPasswordCache.focus_tracking_active
				and !KLPasswordCache.focus_hook
				and !KLPasswordCache.focus_callback)
				return true
		PreviousCritical := Critical("On")
		try {
				Hook := KLPasswordCache.focus_hook
				CallbackPtr := KLPasswordCache.focus_callback
				KLPasswordCache.focus_tracking_active := false
				KLPasswordCache.current_element_id := ""
				KLPasswordCache.focus_generation += 1
				KLPasswordCache.generation += 1
		} finally {
				Critical(PreviousCritical)
		}
		Unhooked := true
		if Hook {
				try {
						Unhooked := !!DllCall("UnhookWinEvent", "Ptr", Hook)
						if !Unhooked
								LoggerWarn("Keylogger", "Password focus tracking hook teardown failed.")
				} catch as err {
						Unhooked := false
						try LoggerWarn("Keylogger", "Password focus tracking hook teardown failed: {1}.", err.Message)
				}
		}
		; WinEvent can still call the thunk after an unhook failure. Retain both
		; native ownership fields so a later stop can retry without freeing live code.
		if !Unhooked
				return false
		PreviousCritical := Critical("On")
		try {
				if (KLPasswordCache.focus_hook = Hook)
						KLPasswordCache.focus_hook := 0
		} finally {
				Critical(PreviousCritical)
		}
		if CallbackPtr and !KL_FreePasswordFocusCallback(CallbackPtr)
				return false
		PreviousCritical := Critical("On")
		try {
				if (KLPasswordCache.focus_callback = CallbackPtr)
						KLPasswordCache.focus_callback := 0
		} finally {
				Critical(PreviousCritical)
		}
		return true
}

; Schedule a single off-thread UIA confirmation for one focus generation.
KL_SchedulePasswordDetect(hwnd, FocusGeneration := unset) {
		if !IsSet(FocusGeneration)
				FocusGeneration := KLPasswordCache.focus_generation
		if (KLPasswordCache.pending_hwnd = hwnd
				and KLPasswordCache.pending_focus_generation = FocusGeneration)
				return
		KLPasswordCache.pending_hwnd := hwnd
		KLPasswordCache.pending_focus_generation := FocusGeneration
		try SetTimer(KL_AsyncPasswordDetect.Bind(hwnd, FocusGeneration), -1)
		catch as err {
				if (KLPasswordCache.pending_hwnd = hwnd
						and KLPasswordCache.pending_focus_generation = FocusGeneration) {
						KLPasswordCache.pending_hwnd := 0
						KLPasswordCache.pending_focus_generation := 0
				}
				try LoggerError("Keylogger", "Password detector scheduling failed: {1}.", err.Message)
		}
}

KL_CurrentPasswordContext() {
		TopHwnd := WIGetForegroundHwnd()
		Control := WIGetFocusedControlToken()
		if !TopHwnd || !Control
				return 0
		ProcName := ""
		try ProcName := WinGetProcessName("ahk_id " . TopHwnd)
		return Map(
				"Hwnd", TopHwnd,
				"Control", Control,
				"InputEpoch", KS_GetPhysicalInputEpoch(),
				"ProcName", ProcName)
}

KL_ClearPendingPasswordDetect(hwnd, FocusGeneration) {
		if (KLPasswordCache.pending_hwnd = hwnd
				and KLPasswordCache.pending_focus_generation = FocusGeneration) {
				KLPasswordCache.pending_hwnd := 0
				KLPasswordCache.pending_focus_generation := 0
		}
}

KL_ParsePasswordWorkerVerdict(Status, Result) {
		if (Status != "ok" || !(Result is Map))
				return KL_PwVerdict(false)
		Payload := Result.Get("Text", "")
		Separator := InStr(Payload, "`n")
		if !Separator
				return KL_PwVerdict(false)
		SecureText := SubStr(Payload, 1, Separator - 1)
		ElementId := SubStr(Payload, Separator + 1)
		if ((SecureText != "0" && SecureText != "1")
				|| ElementId = "" || InStr(ElementId, "`n") || InStr(ElementId, "`r"))
				return KL_PwVerdict(false)
		return KL_PwVerdict(true, SecureText = "1", ElementId)
}

KL_OnPasswordWorkerTerminal(hwnd, FocusGeneration, CurrentHwndFn, ContextFn,
		Status, Context, Result) {
		try {
				if A_IsSuspended
						return false
				Verdict := KL_ParsePasswordWorkerVerdict(Status, Result)
				if !Verdict.Get("known", false) {
						if (Status = "timeout" || Status = "failed")
								try LoggerDebug("Keylogger",
										"Password UIA worker returned {1}; the verdict remains fail-closed.",
										Status)
						return false
				}
				LiveContext := ContextFn.Call()
				CurrentFocus := KL_PasswordFocusSnapshot()
				if !(LiveContext is Map) || !(Context is Map) || !(Result is Map)
						return false
				if (CurrentFocus.Generation != FocusGeneration
						|| CurrentHwndFn.Call() != hwnd
						|| !UIASW_ContextMatches(Context, Result, LiveContext))
						return false
				KL_CommitPwCache(hwnd, A_TickCount,
						Verdict.Get("secure", true), FocusGeneration,
						Verdict.Get("element_id", ""))
				return true
		} finally {
				KL_ClearPendingPasswordDetect(hwnd, FocusGeneration)
		}
}

; Runs on a one-shot timer outside the keystroke callback. It performs no UIA
; work in the resident process: the persistent disposable worker owns the COM
; provider and its 60 ms kill deadline. A provider access violation can retire
; that child, never the driver that records and dispatches input.
KL_AsyncPasswordDetect(hwnd, FocusGeneration := unset,
		CurrentHwndFn := KL_FocusedHostHwnd,
		ContextFn := KL_CurrentPasswordContext,
		RequestFn := UIASW_RequestPassword,
		StartFn := UIASW_Start) {
		if !IsSet(FocusGeneration)
				FocusGeneration := KLPasswordCache.focus_generation
		; Timer callbacks fire even while the script is suspended. Skip detection
		; while suspended so UIA / Win32 round-trips do not run when the keylogger
		; is intentionally paused.
		if A_IsSuspended {
				; Pause aborts the off-thread detection, but the scheduler guard MUST be released
				; or KL_SchedulePasswordDetect dedupes every future re-schedule for this hwnd
				; forever — latching the conservative password verdict and silently dropping all
				; typing metrics in the field after resume (async-password-detect-suspend-latch).
				KL_ClearPendingPasswordDetect(hwnd, FocusGeneration)
				return false
		}
		Accepted := false
		try {
				CurrentFocus := KL_PasswordFocusSnapshot()
				if (CurrentFocus.Generation != FocusGeneration
						|| CurrentHwndFn.Call() != hwnd)
						return false
				Context := ContextFn.Call()
				if !(Context is Map) || Context.Get("Control", 0) != hwnd
						return false
				Terminal := KL_OnPasswordWorkerTerminal.Bind(hwnd, FocusGeneration,
						CurrentHwndFn, ContextFn)
				Accepted := !!RequestFn.Call(Context, Terminal)
				if !Accepted {
						; A cold or retired worker makes this request fail closed. Warm its
						; replacement now; the next keystroke/focus check retries.
						try StartFn.Call()
						return false
				}
				return true
		} catch as err {
				try LoggerError("Keylogger", "Password worker dispatch failed: {1}.", err.Message)
				return false
		} finally {
				; Accepted ownership releases only from its exact terminal. Dispatch
				; refusal/error must reopen the slot so a later key can retry.
				if !Accepted
						KL_ClearPendingPasswordDetect(hwnd, FocusGeneration)
		}
}

KL_IsFocusedFieldPassword() {
		hwnd := KL_FocusedHostHwnd()
		if !hwnd
				return true

		Focus := KL_PasswordFocusSnapshot()
		CachedSecure := true
		if KL_TryGetPwCachedVerdict(hwnd, Focus.Generation, Focus.ElementId,
				&CachedSecure)
				return CachedSecure

		; Brand-new focus: run only the cheap Win32 classification on this thread,
		; never UIA. When Win32 cannot conclude (a non-Edit / unknown control such as
		; a browser, WPF or Electron field) fail safe — treat it as a password so the
		; event is suppressed, and confirm via UIA off-thread, which relaxes the
		; verdict to "not password" if appropriate. A password is therefore never
		; logged while its classification is still uncertain.
		Conclusive := false
		Verdict := KL_DetectPasswordCheap(hwnd, &Conclusive)
		ElementId := "hwnd:" . hwnd
		if !Conclusive {
				Verdict := true
				ElementId := ""
				KL_SchedulePasswordDetect(hwnd, Focus.Generation)
		}
		; Same publish-after-fill commit as the async path — writer and reader are
		; the same thread here, so the ordering is not strictly required, but routing
		; every write through the helper keeps a single source of truth for the
		; cache-write order and prevents a future edit from reintroducing the torn write.
		KL_CommitPwCache(hwnd, A_TickCount, Verdict, Focus.Generation, ElementId)
		return Verdict
}

; Typed detector result. ``known=false`` means no trustworthy answer was
; obtained and the caller MUST preserve its conservative cache entry.
KL_PwVerdict(Known, Secure := true, ElementId := "") {
		return Map(
				"known", Known ? true : false,
				"secure", Secure ? true : false,
				"element_id", ElementId)
}
