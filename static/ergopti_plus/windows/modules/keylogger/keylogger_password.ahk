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
    KLPasswordCache.last_val  := val
    KLPasswordCache.last_at   := at
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
; detection (including the 5-15 ms UIA round-trip) and commits the authoritative
; verdict to the cache.
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
    Result := KL_DetectPasswordFor(hwnd)
    ; Commit through the publish-after-fill helper: last_hwnd is written LAST so
    ; the keystroke reader (a different pseudo-thread) can never see this hwnd
    ; matched while last_val still holds the previous control's verdict.
    KL_CommitPwCache(hwnd, A_TickCount, Result)
    if (KLPasswordCache.pending_hwnd = hwnd)
        KLPasswordCache.pending_hwnd := 0
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

KL_DetectPasswordFor(hwnd) {
    ; Layer 1 — ES_PASSWORD style on a Win32 Edit.
    try {
        cls := WinGetClass("ahk_id " . hwnd)
        if (cls = "Edit") {
            style := WinGetStyle("ahk_id " . hwnd)
            if (style & 0x20)   ; ES_PASSWORD
                return true
        }
        ; Layer 2 — known password class names.
        if KL_PASSWORD_CLASSES.Has(cls)
            return true
        ; RichEdit50W is too generic to flag unconditionally — it only
        ; matters when hosted in a security dialog. Fall through to UIA.
    }

    ; Layer 3 — UIA.IsPasswordPattern. The vendor/UIA.ahk lib initialises
    ; the global ``UIA`` object on first use. Any failure (UIA not loaded,
    ; element not reachable) falls back to "not a password" so we keep
    ; logging by default — better-safe-but-noisy beats silent loss.
    if !IsSet(UIA)
        return false
    try {
        el := UIA.ElementFromHandle(hwnd)
        if !IsObject(el)
            return false
        ; IsPassword is exposed both as a direct property on the element
        ; (UIA-v2) and via the Pattern. Prefer the direct property; fall
        ; back to the pattern read.
        if el.HasOwnProp("IsPassword")
            return el.IsPassword ? true : false
        try
            return el.GetCurrentPropertyValue(UIA.Property.IsPassword) ? true : false
    }
    return false
}
