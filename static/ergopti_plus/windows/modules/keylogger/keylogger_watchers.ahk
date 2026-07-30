; modules/keylogger/keylogger_watchers.ahk

; ==============================================================================
; MODULE: Keylogger Watchers (session, idle, system events)
; DESCRIPTION:
; Producers for the event types HS emits but the AHK port had been silent
; on. The on-disk schema (events_session, events_system) and the SQL
; builders (KL_BuildInsertSession, KL_BuildInsertSystem) were already in
; place — only the actual generators were missing. This module wires
; them.
;
; FEATURES & RATIONALE:
; 1. Session + idle state machine — HS init.lua emits four event types
;    with strict pairing (session_start ↔ session_end, idle_start ↔
;    idle_end). The pairing constraint demands we own a small state
;    machine: a misfire is worse than no event because a dangling
;    session_start poisons every "active time" aggregate downstream.
;    The state lives in KLWatch; the InputHook calls KL_Watchers_OnKeystroke
;    on every keystroke and a SetTimer drives the « close out idle/session
;    after a quiet period » direction.
;
; 2. Shortcut detection — KL_Hook_DetectShortcut inspects modifier state
;    when a non-modifier VK is pressed. AltGr is filtered out via the
;    « RAlt held + Ctrl held but LAlt NOT held » heuristic: Windows
;    synthesises an LCtrl press for RAlt-as-AltGr, so the LAlt slot lets
;    us distinguish AltGr from a real Ctrl+Alt+key shortcut without an
;    LL keyboard hook. False positives from this heuristic are limited
;    to Ctrl+RAlt+key combinations explicitly typed with right-side
;    modifiers — vanishingly rare on European layouts where RAlt is the
;    AltGr key.
;
; 3. System events (lock / unlock / sleep / wake) — Win32 messages
;    surfaced via OnMessage on the script's main window:
;      - WM_WTSSESSION_CHANGE for lock/unlock (requires a one-time
;        WTSRegisterSessionNotification with NOTIFY_FOR_THIS_SESSION),
;      - WM_POWERBROADCAST for sleep/wake (broadcast by Windows to every
;        top-level window without registration).
;
; SCOPE / LIMITATIONS:
; - wifi_change / audio_change / power_change are NOT emitted yet —
;   each requires a dedicated API path (WlanRegisterNotification,
;   IMMNotificationClient, GetSystemPowerStatus polling). They are
;   listed in KEYLOGGER_SPEC §3 but their UI consumers tolerate empty
;   tables, so we ship without them and revisit when needed.
; - space_change is macOS-only (Mission Control); intentionally not
;   ported.
; - system_load (periodic CPU/RAM snapshots) is also deferred.
; ==============================================================================

#Requires Autohotkey v2.0+





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

class KLWatchConst {
		; Mirrors hammerspoon/modules/keylogger/init.lua HS constants. Keeping
		; the same values guarantees that a keystroke pause classified as
		; « micro-idle » on macOS is classified the same way on Windows when
		; both devices share a metrics folder.
		static MICRO_IDLE_TIMEOUT_MS    := 30000
		static SESSION_TIMEOUT_MS       := 300000
		static IDLE_CHECK_INTERVAL_MS   := 10000   ; HS IDLE_CHECK_INTERVAL_SEC * 1000

		; WM_* / WTS_* / PBT_* numeric codes — these are Windows ABI
		; constants, not magic numbers. Cited inline so a reviewer can
		; cross-check against the Win32 docs without leaving the file.
		static WM_WTSSESSION_CHANGE     := 0x02B1
		static WM_POWERBROADCAST        := 0x0218
		static NOTIFY_FOR_THIS_SESSION  := 0x0
		static WTS_SESSION_LOCK         := 0x7
		static WTS_SESSION_UNLOCK       := 0x8
		static PBT_APMSUSPEND           := 0x0004
		static PBT_APMRESUMESUSPEND     := 0x0007
		static PBT_APMRESUMEAUTOMATIC   := 0x0012
}

; Modifier-only virtual keycodes. A keystroke whose VK is in this map
; never produces a shortcut event on its own — chord detection waits for
; the « payload » key (a letter, digit, function key, …) to fire.
global KLHOOK_MODIFIER_VKS := Map(
		0x10, true,  ; VK_SHIFT
		0x11, true,  ; VK_CONTROL
		0x12, true,  ; VK_MENU (Alt)
		0xA0, true, 0xA1, true,  ; VK_L/RSHIFT
		0xA2, true, 0xA3, true,  ; VK_L/RCONTROL
		0xA4, true, 0xA5, true,  ; VK_L/RMENU
		0x5B, true, 0x5C, true,  ; VK_L/RWIN
		0x14, true,              ; VK_CAPITAL
		0x90, true               ; VK_NUMLOCK
)





; ===============================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===============================

class KLWatch {
		; Session machine. ``is_session_active`` flips to true the first time
		; a keystroke arrives after a > SESSION_TIMEOUT_MS gap; flips back to
		; false when the idle tick observes such a gap.
		static is_session_active   := false
		static session_started_at  := 0

		; Idle machine. ``is_idle`` is independent of the session — a single
		; session can contain many micro-idles without ending it.
		static is_idle             := false
		static idle_started_at     := 0

		; Lifecycle handles.
		static idle_check_timer    := unset
		static wts_registered      := false
		static session_msg_handler := unset
		static power_msg_handler   := unset
}





; ==========================================
; ==========================================
; ======= 3/ Session / idle producer =======
; ==========================================
; ==========================================

; Called by the InputHook on every captured keystroke (printable or
; special). Reads ``KLHook.last_tick`` BEFORE it is updated to the new
; ``A_TickCount`` so the gap from the previous keystroke is observable
; here. Order in the InputHook:
;
;   1. KL_Watchers_OnKeystroke()  ← reads stale last_tick, may emit events
;   2. KLHook.last_tick := now    ← input hook updates the watermark
;
; Emits idle_end (when the gap closed a micro-idle), retro-active
; session_end (when the gap exceeded SESSION_TIMEOUT_MS without the
; idle tick noticing — happens when the script was paused), and
; session_start (first keystroke since boot or after a session_end).
KL_Watchers_OnKeystroke() {
		if !Keylogger.initialized
				return
		now  := A_TickCount
		last := KLHook.last_tick

		if (last > 0) {
				; Mask to 32-bit unsigned so the subtraction stays non-negative across
				; the A_TickCount rollover at ~49.7 days uptime.
				gap := (now - last) & 0xFFFFFFFF
				; App time represents foreground screen time, not typing density. A
				; short reading/thinking pause must stay attributed to the focused app;
				; only a full session break is excluded to prevent overnight inflation.
				; The advance can never overshoot now: app_entered_at <= last, so
				; app_entered_at + gap <= now.
				if (gap >= KLWatchConst.SESSION_TIMEOUT_MS) {
						; Clamped, because the suspend branch of KL_Hook_RefreshContext may
						; already have compensated this very span: after a pause both
						; advances describe the same missing wall-clock time, and applied
						; together they push the watermark past the present, making the next
						; app_switch report a negative duration.
						KL_Hook_AdvanceContextWatermarks(gap)
				}
				if KLWatch.is_idle {
						KLWatch.is_idle := false
						try KL_LogSession("idle_end", gap)
				}
				if (KLWatch.is_session_active and gap >= KLWatchConst.SESSION_TIMEOUT_MS) {
						; The idle tick missed this gap — likely the script was
						; suspended (laptop lid, sleep, debugger pause). Close the
						; session retroactively up to the last observed keystroke.
						try KL_LogSession("session_end", (last - KLWatch.session_started_at) & 0xFFFFFFFF)
						KLWatch.is_session_active := false
				}
		}
		if !KLWatch.is_session_active {
				KLWatch.is_session_active  := true
				KLWatch.session_started_at := now
				try KL_LogSession("session_start")
		}
}

; Periodic check (~10 s) for « user has been silent for a while ». The
; only producer for idle_start and the in-time path for session_end —
; the keystroke producer above only handles retroactive session_end.
KL_Watchers_IdleTick() {
		if A_IsSuspended
				return
		if !Keylogger.initialized
				return
		if !KLHook.HasOwnProp("last_tick") || KLHook.last_tick = 0
				return
		now := A_TickCount
		gap := (now - KLHook.last_tick) & 0xFFFFFFFF

		if (!KLWatch.is_idle and KLWatch.is_session_active
						and gap >= KLWatchConst.MICRO_IDLE_TIMEOUT_MS) {
				KLWatch.is_idle         := true
				KLWatch.idle_started_at := KLHook.last_tick
				try KL_LogSession("idle_start")
		}

		if (KLWatch.is_session_active and gap >= KLWatchConst.SESSION_TIMEOUT_MS) {
				; Emit idle_end before session_end so the event log is properly paired —
				; a dangling idle_start without an idle_end corrupts idle-time aggregates
				if KLWatch.is_idle {
						try KL_LogSession("idle_end", (A_TickCount - KLWatch.idle_started_at) & 0xFFFFFFFF)
				}
				KLWatch.is_idle := false
				try KL_LogSession("session_end", (KLHook.last_tick - KLWatch.session_started_at) & 0xFFFFFFFF)
				KLWatch.is_session_active := false
		}
}





; =====================================
; =====================================
; ======= 4/ Shortcut detection =======
; =====================================
; =====================================

; Build a HS-style shortcut label for a non-modifier keypress. Returns
; "" when the chord is not a shortcut (no useful modifier held, or the
; combo looks like AltGr typing a layered character).
KL_Watchers_DetectShortcut(vk) {
		if KLHOOK_MODIFIER_VKS.Has(vk)
				return ""
		Ctrl  := GetKeyState("LControl", "P") or GetKeyState("RControl", "P")
		LAlt  := GetKeyState("LAlt", "P")
		RAlt  := GetKeyState("RAlt", "P")
		Win   := GetKeyState("LWin", "P") or GetKeyState("RWin", "P")
		Shift := GetKeyState("LShift", "P") or GetKeyState("RShift", "P")

		; AltGr is RAlt + a synthetic LCtrl injected by Windows. When LAlt
		; is NOT pressed, this Ctrl+Alt combo is the AltGr layer and the
		; user is just typing a character — drop the « shortcut » framing.
		if (RAlt and Ctrl and !LAlt)
				return ""
		; Plain Shift+letter is capitalisation, never a shortcut.
		if (!Ctrl and !LAlt and !Win)
				return ""

		parts := []
		if Ctrl
				parts.Push("Ctrl")
		if LAlt
				parts.Push("Alt")
		if Win
				parts.Push("Win")
		if Shift
				parts.Push("Shift")

		KeyName := ""
		try KeyName := GetKeyName(Format("vk{:X}", vk))
		if (KeyName = "")
				KeyName := Format("VK{:X}", vk)
		if (StrLen(KeyName) = 1)
				KeyName := StrUpper(KeyName)
		parts.Push(KeyName)

		out := ""
		for i, p in parts
				out .= (i = 1 ? "" : "+") . p
		return out
}





; ================================
; ================================
; ======= 5/ System events =======
; ================================
; ================================

; WM_WTSSESSION_CHANGE handler — wParam carries the session change code
; (WTS_SESSION_LOCK / UNLOCK among others). lParam is the session id,
; ignored here because we only registered for THIS session.
KL_Watchers_OnSessionChange(wParam, lParam, msg, hwnd) {
		if A_IsSuspended
				return
		if (wParam = KLWatchConst.WTS_SESSION_LOCK) {
				try KL_LogSystemEvent("lock")
		} else if (wParam = KLWatchConst.WTS_SESSION_UNLOCK) {
				try KL_LogSystemEvent("unlock")
		}
}

; WM_POWERBROADCAST handler — emits sleep on PBT_APMSUSPEND and wake on
; either resume code. PBT_APMRESUMEAUTOMATIC fires when the system
; wakes for a scheduled task; PBT_APMRESUMESUSPEND fires when the user
; explicitly wakes the machine. Both translate to "wake" for our
; metrics purposes.
KL_Watchers_OnPowerBroadcast(wParam, lParam, msg, hwnd) {
		if A_IsSuspended
				return
		if (wParam = KLWatchConst.PBT_APMSUSPEND) {
				try KL_LogSystemEvent("sleep")
		} else if (wParam = KLWatchConst.PBT_APMRESUMESUSPEND
						or wParam = KLWatchConst.PBT_APMRESUMEAUTOMATIC) {
				try KL_LogSystemEvent("wake")
		}
}





; ============================
; ============================
; ======= 6/ Lifecycle =======
; ============================
; ============================

KL_Watchers_Start() {
		; Idempotent — successive calls are no-ops once the timer is armed.
		if KLWatch.HasOwnProp("idle_check_timer") && IsObject(KLWatch.idle_check_timer)
				return

		KLWatch.idle_check_timer := KL_Watchers_IdleTick.Bind()
		SetTimer(KLWatch.idle_check_timer, KLWatchConst.IDLE_CHECK_INTERVAL_MS)

		; Register WTS notifications on the script's main window. The HWND
		; comes from A_ScriptHwnd, which AHK v2 always exposes for the
		; default script window (hidden by default but guaranteed to exist).
		if !KLWatch.wts_registered {
				try {
						DllCall("Wtsapi32\WTSRegisterSessionNotification",
								"Ptr",  A_ScriptHwnd,
								"UInt", KLWatchConst.NOTIFY_FOR_THIS_SESSION)
						KLWatch.wts_registered := true
				}
		}

		; OnMessage pins the callback for the lifetime of the script. We
		; keep the bound function reference around so KL_Watchers_Stop can
		; pass MaxThreads=0 to detach it cleanly.
		KLWatch.session_msg_handler := KL_Watchers_OnSessionChange
		KLWatch.power_msg_handler   := KL_Watchers_OnPowerBroadcast
		OnMessage(KLWatchConst.WM_WTSSESSION_CHANGE, KLWatch.session_msg_handler)
		OnMessage(KLWatchConst.WM_POWERBROADCAST,   KLWatch.power_msg_handler)
}

KL_Watchers_Stop() {
		if KLWatch.HasOwnProp("idle_check_timer") && IsObject(KLWatch.idle_check_timer) {
				try SetTimer(KLWatch.idle_check_timer, 0)
				KLWatch.idle_check_timer := unset
		}
		if KLWatch.wts_registered {
				try DllCall("Wtsapi32\WTSUnRegisterSessionNotification", "Ptr", A_ScriptHwnd)
				KLWatch.wts_registered := false
		}
		if KLWatch.HasOwnProp("session_msg_handler") && IsObject(KLWatch.session_msg_handler) {
				try OnMessage(KLWatchConst.WM_WTSSESSION_CHANGE, KLWatch.session_msg_handler, 0)
				KLWatch.session_msg_handler := unset
		}
		if KLWatch.HasOwnProp("power_msg_handler") && IsObject(KLWatch.power_msg_handler) {
				try OnMessage(KLWatchConst.WM_POWERBROADCAST, KLWatch.power_msg_handler, 0)
				KLWatch.power_msg_handler := unset
		}
		; Drain any open session/idle state so the JSONL never ends with a
		; dangling session_start. Pair every open lifecycle event with its
		; closing counterpart.
		if KLWatch.is_idle {
				KLWatch.is_idle := false
				try KL_LogSession("idle_end", (A_TickCount - KLWatch.idle_started_at) & 0xFFFFFFFF)
		}
		if KLWatch.is_session_active {
				try KL_LogSession("session_end", (A_TickCount - KLWatch.session_started_at) & 0xFFFFFFFF)
				KLWatch.is_session_active := false
		}
}
