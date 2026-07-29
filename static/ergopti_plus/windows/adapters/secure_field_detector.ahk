; adapters/secure_field_detector.ahk

; ==============================================================================
; MODULE: SecureFieldDetector Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the SecureFieldDetector port contract. Detects
; whether the currently focused control is a password/secure input field by
; inspecting the ES_PASSWORD window style (0x20), and whether the active
; application belongs to a hardcoded list of known password-manager processes.
;
; NAMING CONVENTION:
; Port method → AHK name mapping:
;   isSecureField() → SFD_IsSecureField()
;   isSecureApp()   → SFD_IsSecureApp(AppId)
;   refresh()       → SFD_Refresh()
;
; FAIL-SAFE:
; All AHK control-inspection calls are wrapped in try/catch. A detector failure
; is treated as secure while privacy protection is enabled: sending unknown
; focused-field content to an LLM is irreversible, whereas one delayed
; prediction is recoverable. UIA confirmation runs from a deferred timer and
; is cached by focus HWND, never on the character hook.
; ==============================================================================



; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; Known password-manager process names — expansion welcome, never shrink.
global SFD_SECURE_APPS := Map(
	"1Password.exe",        true,
	"KeePass.exe",          true,
	"KeePassXC.exe",        true,
	"Bitwarden.exe",        true,
	"LastPass.exe",         true,
	"Dashlane.exe",         true,
	"RoboForm.exe",         true,
	"Authy.exe",            true,
	"keepass2.exe",         true,
	"credential_guard",     true
)

; One focus-scoped triage cache. ``pending_hwnd`` prevents repeated calls while
; typing in an unknown browser/Electron control from queuing UIA work per key.
global SFD_FIELD_CACHE := Map(
	"hwnd", 0,
	"secure", true,
	"at", 0,
	"pending_hwnd", 0
)
global SFD_FIELD_CACHE_TTL_MS := 1000

; Physical idle required before the deferred UIA probe may start its
; cross-process COM round-trip. Deliberately this adapter's own constant rather
; than a reference to TOOLTIP_UIA_IDLE_REQUIRED_MS or
; UIA_SELECTION_IDLE_REQUIRED_MS: each probe site answers a different question
; on a different cadence, and the two existing ones already differ (200 vs 250).
global SFD_UIA_IDLE_REQUIRED_MS := 250

; How long one unanswered probe silences further probes against that process.
; A UIA-hostile app otherwise re-pays a full timeout on every TTL expiry, i.e.
; roughly once a second, on the thread that also dispatches keystrokes.
global SFD_UIA_HOSTILE_TTL_MS := 30000

; Process name => A_TickCount deadline until which probes against it are skipped.
; Entries expire, so the map cannot grow without bound across a long session.
global SFD_UIA_HOSTILE_CACHE := Map()



; ======================================
; ======================================
; ======= 2/ Adapter Functions =======
; ======================================
; ======================================

; Returns true if the focused control is secure OR cannot yet be classified.
; The cheap native path is synchronous; an inconclusive browser/Electron/WPF
; control is denied once and confirmed with UIA on a deferred callback.
SFD_IsSecureField() {
	global SFD_FIELD_CACHE, SFD_FIELD_CACHE_TTL_MS
	Hwnd := SFD_FocusedHwnd()
	if !Hwnd
		return true
	if (SFD_FIELD_CACHE["hwnd"] = Hwnd) {
		if (((A_TickCount - SFD_FIELD_CACHE["at"]) & 0xFFFFFFFF) < SFD_FIELD_CACHE_TTL_MS)
			return SFD_FIELD_CACHE["secure"]
		; An EXPIRED verdict is an unknown, and an unknown fails closed here for
		; exactly the same reason an inconclusive native probe does below. The
		; cache key is the focus HWND, but Chromium and Electron host every field
		; of a page behind one Chrome_RenderWidgetHostHWND — the very control
		; class this detector exists to protect — so the key does not identify
		; the control the verdict describes. Serving the expired value let a
		; password box inherit the "not secure" answer of a sibling field on the
		; same handle, and go on inheriting it while the probe was in flight.
		SFD_ScheduleUiaProbe(Hwnd)
		return true
	}

	Conclusive := false
	Secure := SFD_DetectNative(Hwnd, &Conclusive)
	if !Conclusive {
		; Unknown is fail-closed until the asynchronous UIA probe establishes a
		; normal field. This protects browser password boxes and UAC-restricted UI.
		Secure := true
		SFD_ScheduleUiaProbe(Hwnd)
	}
	SFD_CommitFieldVerdict(Hwnd, Secure)
	return Secure
}

SFD_FocusedHwnd() {
	try {
		Hwnd := ControlGetHwnd(ControlGetFocus("A"), "A")
		if Hwnd
			return Hwnd
	}
	try return WinGetID("A")
	return 0
}

SFD_DetectNative(Hwnd, &Conclusive) {
	Conclusive := false
	try {
		ClassName := WinGetClass("ahk_id " . Hwnd)
		if !RegExMatch(ClassName, "i)^(Edit|RichEdit)")
			return false
		; Read the style BEFORE claiming the verdict is conclusive. WinGetStyle
		; throws TargetError if the control is destroyed in the window between
		; the class read above and this line, and a Conclusive already set would
		; turn that OS failure into a confident "not a password field": the
		; caller would then skip its fail-closed branch, never schedule the UIA
		; probe, and cache the wrong answer for a full TTL. Every other unknown
		; in this adapter fails closed; this one used to fail open.
		Style := WinGetStyle("ahk_id " . Hwnd)
		Conclusive := true
		return (Style & 0x20) ? true : false
	} catch as e {
		; The verdict stays inconclusive so the caller falls back to fail-closed
		; plus a UIA probe, but the reason must not vanish (conventions 5.3).
		; DEBUG because a control disappearing mid-classification is an expected,
		; benign outcome — it is only the silent version that was a defect.
		Conclusive := false
		try LoggerDebug("SecureField", "Native field classification failed for hwnd {1}: {2}.", Hwnd, e.Message)
	}
	return false
}

SFD_CommitFieldVerdict(Hwnd, Secure) {
	global SFD_FIELD_CACHE
	; Publish the key last so concurrent reader callbacks cannot pair a new HWND
	; with the previous control's verdict.
	SFD_FIELD_CACHE["secure"] := !!Secure
	SFD_FIELD_CACHE["at"] := A_TickCount
	SFD_FIELD_CACHE["hwnd"] := Hwnd
}

SFD_ScheduleUiaProbe(Hwnd) {
	global SFD_FIELD_CACHE
	if (SFD_FIELD_CACHE["pending_hwnd"] = Hwnd)
		return
	SFD_FIELD_CACHE["pending_hwnd"] := Hwnd
	try SetTimer(SFD_ProbeFocusedUia.Bind(Hwnd), -1)
	catch {
		if (SFD_FIELD_CACHE["pending_hwnd"] = Hwnd)
			SFD_FIELD_CACHE["pending_hwnd"] := 0
	}
}

; Releases the one-probe-in-flight slot. A released slot lets the next
; SFD_IsSecureField call re-arm the probe, which is what makes a deferral
; (suspended, mid-burst, hostile process) transient rather than permanent.
_SFD_ClearPendingProbe(Hwnd) {
	global SFD_FIELD_CACHE
	if (SFD_FIELD_CACHE["pending_hwnd"] = Hwnd)
		SFD_FIELD_CACHE["pending_hwnd"] := 0
}

; Has this process recently failed to answer a UIA probe? Mirrors the tooltip's
; own hostile cache: one timeout must buy a quiet window instead of being
; re-paid on every field-cache expiry, i.e. roughly once per second.
_SFD_UiaProcessIsHostile(ProcName) {
	global SFD_UIA_HOSTILE_CACHE
	if (ProcName == "" or !SFD_UIA_HOSTILE_CACHE.Has(ProcName))
		return false
	if (A_TickCount < SFD_UIA_HOSTILE_CACHE[ProcName])
		return true
	SFD_UIA_HOSTILE_CACHE.Delete(ProcName)
	return false
}

; Record that ProcName did not answer usefully, silencing probes against it for
; SFD_UIA_HOSTILE_TTL_MS.
_SFD_MarkUiaHostile(ProcName) {
	global SFD_UIA_HOSTILE_CACHE, SFD_UIA_HOSTILE_TTL_MS
	if (ProcName == "")
		return
	SFD_UIA_HOSTILE_CACHE[ProcName] := A_TickCount + SFD_UIA_HOSTILE_TTL_MS
}

; Bound UIA's own waits before this adapter makes its first COM round-trip.
; The library ships Windows' defaults — 2000 ms TransactionTimeout and 20000 ms
; ConnectionTimeout — and the driver's worst measured stall (2560 ms) is exactly
; that 2000 ms plus overhead. The clamp is process-wide (the properties live on
; the UIA singleton) and idempotent, but it is applied lazily by whichever probe
; site touches UIA first; this adapter usually wins that race, because it fires
; right after a typing burst while the tooltip's own clamp sits behind an idle
; gate. Kept adapter-local on purpose: an adapter must not reach into ui/ for a
; helper. Both are one-shot and set the same shared constants, so whichever runs
; first wins and the other is a no-op.
_SFD_ClampUiaTimeouts() {
	global UIA_TRANSACTION_TIMEOUT_MS, UIA_CONNECTION_TIMEOUT_MS
	static Clamped := false
	; One diagnostic per process: this probe runs on focus changes, so an
	; unthrottled warning would become a flood of its own.
	static Warned := false
	if Clamped
		return
	if !IsSet(UIA)
		return
	if (!IsSet(UIA_TRANSACTION_TIMEOUT_MS) or !IsSet(UIA_CONNECTION_TIMEOUT_MS)) {
		if !Warned {
			Warned := true
			try LoggerWarn("SecureField", "UIA timeout constants are unavailable — the probe would run on Windows' 2000 ms default; skipping the probe's clamp.")
		}
		return
	}
	; Both properties are IUIAutomation2 vtable slots; an older interface must not
	; throw into this callback, which shares the keystroke-dispatch thread.
	Supported := false
	try Supported := UIA.IsIUIAutomation2Available ? true : false
	if !Supported {
		Clamped := true
		if !Warned {
			Warned := true
			try LoggerWarn("SecureField", "IUIAutomation2 is unavailable — the password probe runs against Windows' 2000 ms transaction default and cannot be bounded here.")
		}
		return
	}
	; Latch only once the writes have LANDED. Setting the flag first left the
	; driver believing it was clamped after a failed write, for the whole session,
	; with two bare `try`s swallowing the reason (conventions 5.3).
	Ok := true
	try UIA.TransactionTimeout := UIA_TRANSACTION_TIMEOUT_MS
	catch
		Ok := false
	try UIA.ConnectionTimeout := UIA_CONNECTION_TIMEOUT_MS
	catch
		Ok := false
	if Ok {
		Clamped := true
		return
	}
	if !Warned {
		Warned := true
		try LoggerWarn("SecureField", "Could not apply the UIA timeout clamp — the password probe is NOT bounded; retrying on the next probe.")
	}
}

SFD_ProbeFocusedUia(Hwnd) {
	global SFD_UIA_IDLE_REQUIRED_MS
	if A_IsSuspended {
		_SFD_ClearPendingProbe(Hwnd)
		return
	}

	; This callback runs on the main message thread — the thread that dispatches
	; hotkey subroutines and InputHook OnChar — and UIA.GetFocusedElement below is
	; a cross-process COM round-trip. It therefore carries the same three guards
	; the driver's two other probe sites already have. Every deferral leaves the
	; verdict untouched, so an expired entry keeps failing closed: skipping the
	; probe can only cost a prediction, never leak one.
	;
	; (a) Never start the round-trip while the user is physically typing. A
	;     keystroke arriving 1 ms after it starts queues behind it.
	if (A_TimeIdlePhysical < SFD_UIA_IDLE_REQUIRED_MS) {
		_SFD_ClearPendingProbe(Hwnd)
		return
	}

	; (b) Skip a process already known not to answer.
	ProcName := ""
	try ProcName := WinGetProcessName("A")
	if _SFD_UiaProcessIsHostile(ProcName) {
		_SFD_ClearPendingProbe(Hwnd)
		return
	}

	; (c) Bound the call itself, before making it.
	_SFD_ClampUiaTimeouts()

	; UIA may take milliseconds or fail for an elevated/closing target. Both cases
	; remain secure; this callback is deliberately outside the prediction/hook path.
	Secure := true
	try {
		if !IsSet(UIA)
			throw Error("UIA unavailable")
		Element := UIA.GetFocusedElement()
		if !IsObject(Element)
			throw Error("No focused UIA element")
		Secure := Element.GetCurrentPropertyValue(UIA.Property.IsPassword) ? true : false
	} catch as e {
		; Fail-secure is the right BEHAVIOUR here and does not change, but the
		; reason must not vanish: a catch-less try made "UIA is unavailable on
		; this machine" indistinguishable from "this one target refused", so a
		; permanently degraded detector looked exactly like a healthy one that
		; keeps meeting elevated windows (conventions 5.3). DEBUG because an
		; elevated or closing target is an expected, frequent outcome.
		_SFD_MarkUiaHostile(ProcName)
		try LoggerDebug("SecureField", "UIA password probe failed: {1}.", e.Message)
	}

	; The probe read whatever was focused NOW, not the control captured when the
	; timer was armed. Committing this answer under the scheduled Hwnd would bind
	; one field's IsPassword to another field's key, so discard it when the focus
	; has moved since — including during the COM call itself. The stale entry then
	; simply expires and fails closed.
	Current := SFD_FocusedHwnd()
	if (Current != Hwnd) {
		try LoggerDebug("SecureField", "UIA password probe discarded — focus moved from {1} to {2} while probing.", Hwnd, Current)
		_SFD_ClearPendingProbe(Hwnd)
		return
	}

	SFD_CommitFieldVerdict(Hwnd, Secure)
	_SFD_ClearPendingProbe(Hwnd)
}

; Returns true if AppId matches any entry in the SFD_SECURE_APPS constant Map.
; An empty or missing AppId is treated as non-secure to avoid false positives.
; @param AppId {String} Process name of the active application (e.g. KeePass.exe).
; @return {Boolean} True on success, false on error.
SFD_IsSecureApp(AppId) {
	if AppId = ""
		return false
	try {
		return SFD_SECURE_APPS.Has(AppId) ? true : false
	} catch {
		return false
	}
}

; No-op on AHK — context is read live at call time, no cached state to refresh.
; Exists solely to satisfy the port contract interface.
SFD_Refresh() {
	; Live queries require no pre-fetch on Windows — nothing to do here
	return
}
; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_SECURE_FIELD_DETECTOR := Map(
    "isSecureField", SFD_IsSecureField,
    "isSecureApp",   SFD_IsSecureApp,
    "refresh",       SFD_Refresh,
)
