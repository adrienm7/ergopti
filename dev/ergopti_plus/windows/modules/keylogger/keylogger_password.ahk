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
; The result is cached per-HWND for ``KLPW_CACHE_TTL_MS`` because UIA
; round-trips can take 5-15 ms; the focused control is unlikely to flip
; password-vs-not within a typing burst. 2000 ms avoids cache misses at
; high keystroke rate (8+ keys/s) while still detecting field transitions
; within 2 s — more than adequate for a privacy filter.

global KLPW_CACHE_TTL_MS := 2000

class KLPasswordCache {
		static last_hwnd := 0
		static last_at   := 0
		static last_val  := false
		; Monotonic publication epoch used by output-journal transactions. A
		; password verdict changing between their open-thread privacy check and
		; RAM commit invalidates telemetry fail-closed without blocking output.
		static generation := 0
		; HWND with an in-flight async UIA confirmation — guards the scheduler so a
		; burst of keystrokes on the same not-yet-classified control cannot pile up
		; one-shot timers.
		static pending_hwnd := 0
}

; Publishes a (hwnd, at, val) verdict to the password cache as a single logical
; commit. last_hwnd is the COMMIT FLAG and is therefore written LAST: the
; keystroke reader matches on last_hwnd, so by the time it observes the new
; hwnd, last_val and last_at already correspond to that hwnd. Without this
; ordering an interrupt between the writes (KL_AsyncPasswordDetect runs on a
; separate pseudo-thread from the reader) could expose last_hwnd matched but
; last_val still holding the previous control's verdict — a single-keystroke
; privacy leak (password char logged) or metric suppression at field
; transitions. The single source of truth for cache-write ordering: every
; writer goes through here, never touches the fields in another order.
KL_CommitPwCache(hwnd, at, val) {
		Changed := (KLPasswordCache.last_hwnd != hwnd
				|| KLPasswordCache.last_val != val)
		KLPasswordCache.last_val  := val
		KLPasswordCache.last_at   := at
		if Changed
				KLPasswordCache.generation += 1
		KLPasswordCache.last_hwnd := hwnd   ; commit flag — must be assigned LAST
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

; Schedule a single off-thread UIA confirmation for hwnd. Guarded by pending_hwnd
; so repeated keystrokes on the same control do not stack one-shot timers.
KL_SchedulePasswordDetect(hwnd) {
		if (KLPasswordCache.pending_hwnd = hwnd)
				return
		KLPasswordCache.pending_hwnd := hwnd
		try SetTimer(KL_AsyncPasswordDetect.Bind(hwnd), -1)
}

; Runs on a one-shot timer, off the keystroke thread: performs the full
; detection (including the 5-15 ms UIA round-trip) and commits only a
; conclusive verdict. An unavailable UIA provider is an unknown, never evidence
; that the field is safe to record.
KL_AsyncPasswordDetect(hwnd) {
		; Timer callbacks fire even while the script is suspended. Skip detection
		; while suspended so UIA / Win32 round-trips do not run when the keylogger
		; is intentionally paused.
		if A_IsSuspended {
				; Pause aborts the off-thread detection, but the scheduler guard MUST be released
				; or KL_SchedulePasswordDetect dedupes every future re-schedule for this hwnd
				; forever — latching the conservative password verdict and silently dropping all
				; typing metrics in the field after resume (async-password-detect-suspend-latch).
				if (KLPasswordCache.pending_hwnd = hwnd)
						KLPasswordCache.pending_hwnd := 0
				return
		}
		try {
				Verdict := KL_DetectPasswordFor(hwnd)
				if Verdict.Get("known", false) {
						; Commit through the publish-after-fill helper: last_hwnd is
						; written LAST so the keystroke reader (a different pseudo-thread)
						; can never observe fields from two cache entries at once.
						KL_CommitPwCache(hwnd, A_TickCount, Verdict.Get("secure", true))
				}
		} finally {
				; Release the dedupe latch on success, an inconclusive probe, and an
				; unexpected exception. Otherwise this HWND can never be retried.
				if (KLPasswordCache.pending_hwnd = hwnd)
						KLPasswordCache.pending_hwnd := 0
		}
}

KL_IsFocusedFieldPassword() {
		hwnd := 0
		try hwnd := ControlGetFocus("A")
		if !hwnd
				try hwnd := WinGetID("A")
		if !hwnd
				return false

		; Same HWND already classified — return the cached verdict immediately. If
		; it has gone stale, kick an async re-detect but still answer NOW so the
		; keystroke thread never blocks on a UIA round-trip for re-validation.
		if (KLPasswordCache.last_hwnd = hwnd) {
				if ((A_TickCount - (KLPasswordCache.last_at) & 0xFFFFFFFF) >= KLPW_CACHE_TTL_MS)
						KL_SchedulePasswordDetect(hwnd)
				return KLPasswordCache.last_val
		}

		; Brand-new focus: run only the cheap Win32 classification on this thread,
		; never UIA. When Win32 cannot conclude (a non-Edit / unknown control such as
		; a browser, WPF or Electron field) fail safe — treat it as a password so the
		; event is suppressed, and confirm via UIA off-thread, which relaxes the
		; verdict to "not password" if appropriate. A password is therefore never
		; logged while its classification is still uncertain.
		Conclusive := false
		Verdict := KL_DetectPasswordCheap(hwnd, &Conclusive)
		if !Conclusive {
				Verdict := true
				KL_SchedulePasswordDetect(hwnd)
		}
		; Same publish-after-fill commit as the async path — writer and reader are
		; the same thread here, so the ordering is not strictly required, but routing
		; every write through the helper keeps a single source of truth for the
		; cache-write order and prevents a future edit from reintroducing the torn write.
		KL_CommitPwCache(hwnd, A_TickCount, Verdict)
		return Verdict
}

; Typed detector result. ``known=false`` means no trustworthy answer was
; obtained and the caller MUST preserve its conservative cache entry.
KL_PwVerdict(Known, Secure := true) {
		return Map("known", Known ? true : false, "secure", Secure ? true : false)
}

; Native layers for the FULL detector. Unlike KL_PwClassStyleVerdict's cheap
; keystroke-path answer, absence of ES_PASSWORD is not a conclusive negative
; here: providers can expose the secure role only through UIA, so an ordinary
; native result must fall through to the canonical focused-element property.
KL_PwFullNativeVerdict(Cls, Style) {
		if (Cls = "Edit" && (Style & 0x20))
				return KL_PwVerdict(true, true)
		if KL_PASSWORD_CLASSES.Has(Cls)
				return KL_PwVerdict(true, true)
		return KL_PwVerdict(false)
}

KL_DetectPasswordFor(hwnd) {
		; Layer 1 — ES_PASSWORD style on a Win32 Edit.
		try {
				cls := WinGetClass("ahk_id " . hwnd)
				style := 0
				if (cls = "Edit")
						style := WinGetStyle("ahk_id " . hwnd)
				NativeVerdict := KL_PwFullNativeVerdict(cls, style)
				if NativeVerdict.Get("known", false)
						return NativeVerdict
				; RichEdit50W is too generic to flag unconditionally — it only
				; matters when hosted in a security dialog. Fall through to UIA.
		} catch as err {
				; A failed native read is inconclusive. UIA may still provide the
				; canonical focused-element property below.
				try LoggerDebug("Keylogger", "Native password probe failed: {1}.", err.Message)
		}

		; Layer 3 — UIA IsPassword, read from the FOCUSED element.
		;
		; It must be UIA.GetFocusedElement(), never UIA.ElementFromHandle(hwnd):
		; ElementFromHandle answers about the element BEHIND that window handle. For
		; every single-HWND UI framework — Chromium and Electron
		; (Chrome_RenderWidgetHostHWND), WPF/UWP (HwndWrapper[…]) — that is the
		; render widget or the window pane, never the web/XAML input the caret is
		; in, so its IsPassword is always 0. Layers 1-2 cannot classify those
		; frameworks either (the class allow-list is matched against a window
		; class), so the window-scoped probe committed a bogus "not a password" for
		; the whole window, and KL_IsFocusedFieldPassword's per-HWND cache then
		; latched it across every field in it — the site's password box included.
		; adapters/secure_field_detector.ahk asks the same question of the same API
		; the right way; this is the same guarantee for the consumer that persists
		; characters to disk.
		;
		; Any failure (UIA not loaded, no focused element, provider exception) is
		; explicitly unknown. The async caller then preserves the fail-closed cache
		; entry instead of turning infrastructure failure into "ordinary text".
		if !IsSet(UIA)
				return KL_PwVerdict(false)
		try {
				el := UIA.GetFocusedElement()
				if !IsObject(el)
						return KL_PwVerdict(false)
				return KL_PwVerdict(true,
						el.GetCurrentPropertyValue(UIA.Property.IsPassword) ? true : false)
		} catch as err {
				; A catch-less try made "UIA is unavailable on this machine" look
				; exactly like "this one target refused", so a permanently degraded
				; detector was indistinguishable from a healthy one (conventions 5.3).
				; DEBUG because an elevated or closing target is an expected outcome.
				try LoggerDebug("Keylogger", "UIA password probe failed: {1}.", err.Message)
		}
		return KL_PwVerdict(false)
}
