; modules/keylogger/keylogger_mouse.ahk

; ==============================================================================
; MODULE: Keylogger Mouse Events
; DESCRIPTION:
; Captures rich mouse interaction events and feeds them into the keylogger
; pipeline alongside keystroke data. Tracks clicks (L/M/R with coords and
; target app), scroll events (velocity and direction), drag operations
; (distance and duration), and mouse idle/parking positions.
;
; FEATURES & RATIONALE:
; 1. Click logging — every LButton / MButton / RButton press records the
;    screen coordinates, the target process name, and whether it was a
;    single or double click. This surfaces per-app mouse usage patterns
;    and distinguishes navigation clicks from content clicks.
; 2. Scroll logging — wheel events are debounced and coalesced into bursts.
;    Each burst record carries total ticks, direction (up/down/h), and a
;    velocity estimate (ticks/s) so the dashboard can distinguish rapid
;    skimming from deliberate reading.
; 3. Drag detection — if the mouse button is held while moving more than
;    DRAG_MIN_PX pixels the release is tagged as a drag rather than a click.
;    Drag records include start/end coords, pixel distance, and duration_ms.
; 4. Mouse idle park — a SetTimer polls the cursor position every
;    PARK_CHECK_MS. When the cursor has not moved more than PARK_JITTER_PX
;    for PARK_IDLE_MS it emits a mouse_idle_park event with the dwell
;    position and the app under the cursor. This quantifies « dead mouse »
;    time and complements the keyboard idle machine.
; 5. Distance accumulation — every poll tick updates KL_BumpMouseDistance
;    so the existing ``mouse_distance_px`` column in typing flush entries
;    keeps working unmodified.
; 6. Privacy filter — every event passes through MF_ShouldFilter() before
;    any allocation. Password fields and disabled apps are silently dropped.
;
; HOOK OWNERSHIP:
; Mouse button events are no longer registered directly with Hotkey() here.
; Instead KL_Mouse_Start() subscribes each handler to HookDispatcher so the
; process has only one set of mouse hotkeys, shared by all features. The park
; timer and scroll-flush timer are still owned by this module because they are
; purely internal concerns (no other module needs to listen to the poll tick).
;
; LIFECYCLE:
; - KL_Mouse_Start() is called after KL_Hook_Start() / KL_Watchers_Start().
; - KL_Mouse_Stop() unregisters subscribers and releases all timers.
; ==============================================================================

#Requires Autohotkey v2.0+





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

class KLMouseConst {
		; Minimum displacement (px) between button-down and button-up to
		; classify the gesture as a drag rather than a plain click.
		static DRAG_MIN_PX         := 8

		; Scroll bursts: two wheel ticks are merged into the same event when
		; the gap between them is under this threshold.
		static SCROLL_BURST_GAP_MS := 400

		; How often the background timer polls the cursor position (ms).
		; 250 ms (~4 Hz) keeps background CPU minimal and eases the load on the
		; single AHK execution context shared with the input thread; distance and
		; park detection stay accurate enough for metrics at this cadence.
		static PARK_CHECK_MS       := 250

		; Cursor must remain within this radius (px) to be considered parked.
		static PARK_JITTER_PX      := 8

		; Duration the cursor must sit still before a mouse_idle_park fires.
		static PARK_IDLE_MS        := 3000

		; Minimum distance (px) between two park events to avoid spamming the
		; log when the user nudges the mouse and immediately stops again.
		static PARK_MIN_MOVE_PX    := 32
}





; ===============================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===============================

class KLMouse {
		; ── button-down snapshot ──────────────────────────────────────────────
		static lbtn_down_x      := 0
		static lbtn_down_y      := 0
		static lbtn_down_tick   := 0
		static lbtn_held        := false

		static rbtn_down_x      := 0
		static rbtn_down_y      := 0
		static rbtn_down_tick   := 0
		static rbtn_held        := false

		static mbtn_down_x      := 0
		static mbtn_down_y      := 0
		static mbtn_down_tick   := 0
		static mbtn_held        := false

		; ── scroll burst accumulator ──────────────────────────────────────────
		static scroll_ticks     := 0         ; accumulated delta (negative = down)
		static scroll_h_ticks   := 0         ; horizontal delta
		static scroll_start     := 0         ; A_TickCount of first tick in burst
		static scroll_last      := 0         ; A_TickCount of last tick seen
		static scroll_flush_fn  := unset     ; bound ref for SetTimer

		; ── park / idle tracker ───────────────────────────────────────────────
		static park_last_x      := -1        ; position at last poll
		static park_last_y      := -1
		static park_still_since := 0         ; tick when stillness began
		static park_fired_x     := -9999     ; position of last fired park event
		static park_fired_y     := -9999
		static park_fired_at    := 0         ; tick of last park fire
		static park_timer_fn    := unset

		; ── distance accumulator ──────────────────────────────────────────────
		static prev_x           := -1
		static prev_y           := -1

		; ── hotkey callback references (set by Start, used by Stop) ──────────
		static hk_ldown         := unset
		static hk_lup           := unset
		static hk_rdown         := unset
		static hk_rup           := unset
		static hk_mdown         := unset
		static hk_mup           := unset
		static hk_wup           := unset
		static hk_wdn           := unset
		static hk_wright         := unset
		static hk_wleft          := unset
}





; =================================
; =================================
; ======= 3/ Click handlers =======
; =================================
; =================================

KL_Mouse_OnLDown(*) {
		try {
				CoordMode("Mouse", "Screen")
				MouseGetPos(&mx, &my)
				KLMouse.lbtn_down_x    := mx
				KLMouse.lbtn_down_y    := my
				KLMouse.lbtn_down_tick := A_TickCount
				KLMouse.lbtn_held      := true
		}
}

KL_Mouse_OnLUp(*) {
		if A_IsSuspended {
				KLMouse.lbtn_held := false
				return
		}
		if !KLMouse.lbtn_held
				return
		KLMouse.lbtn_held := false
		try {
				CoordMode("Mouse", "Screen")
				MouseGetPos(&mx, &my)
				dx       := mx - KLMouse.lbtn_down_x
				dy       := my - KLMouse.lbtn_down_y
				dist     := Sqrt(dx*dx + dy*dy)
				duration := (A_TickCount - KLMouse.lbtn_down_tick) & 0xFFFFFFFF
				filtered := false
				try filtered := MF_ShouldFilter()
				if filtered
						return
				if !Keylogger.initialized
						return
				; Bump the click counter only AFTER the privacy filter + init checks, so clicks in
				; a password field / disabled app / private window do not accrue into the counts
				; that later ride into a typing row (mouse-counter-privacy-filter).
				KL_BumpMouseClick()
				; Use an async one-shot timer so context refresh doesn't block the hook thread
				try SetTimer(KL_Hook_RefreshContext.Bind(), -1)
				if (dist >= KLMouseConst.DRAG_MIN_PX) {
						KL_Mouse_LogDrag("left",
								KLMouse.lbtn_down_x, KLMouse.lbtn_down_y,
								mx, my, Round(dist), duration)
				} else {
						KL_Mouse_LogClick("left", KLMouse.lbtn_down_x, KLMouse.lbtn_down_y)
				}
		}
}

KL_Mouse_OnRDown(*) {
		try {
				CoordMode("Mouse", "Screen")
				MouseGetPos(&mx, &my)
				KLMouse.rbtn_down_x    := mx
				KLMouse.rbtn_down_y    := my
				KLMouse.rbtn_down_tick := A_TickCount
				KLMouse.rbtn_held      := true
		}
}

KL_Mouse_OnRUp(*) {
		if A_IsSuspended {
				KLMouse.rbtn_held := false
				return
		}
		if !KLMouse.rbtn_held
				return
		KLMouse.rbtn_held := false
		try {
				CoordMode("Mouse", "Screen")
				MouseGetPos(&mx, &my)
				dx       := mx - KLMouse.rbtn_down_x
				dy       := my - KLMouse.rbtn_down_y
				dist     := Sqrt(dx*dx + dy*dy)
				duration := (A_TickCount - KLMouse.rbtn_down_tick) & 0xFFFFFFFF
				filtered := false
				try filtered := MF_ShouldFilter()
				if filtered
						return
				if !Keylogger.initialized
						return
				; Bump the click counter only AFTER the privacy filter + init checks, so clicks in
				; a password field / disabled app / private window do not accrue into the counts
				; that later ride into a typing row (mouse-counter-privacy-filter).
				KL_BumpMouseClick()
				; Use an async one-shot timer so context refresh doesn't block the hook thread
				try SetTimer(KL_Hook_RefreshContext.Bind(), -1)
				if (dist >= KLMouseConst.DRAG_MIN_PX) {
						KL_Mouse_LogDrag("right",
								KLMouse.rbtn_down_x, KLMouse.rbtn_down_y,
								mx, my, Round(dist), duration)
				} else {
						KL_Mouse_LogClick("right", KLMouse.rbtn_down_x, KLMouse.rbtn_down_y)
				}
		}
}

KL_Mouse_OnMDown(*) {
		try {
				CoordMode("Mouse", "Screen")
				MouseGetPos(&mx, &my)
				KLMouse.mbtn_down_x    := mx
				KLMouse.mbtn_down_y    := my
				KLMouse.mbtn_down_tick := A_TickCount
				KLMouse.mbtn_held      := true
		}
}

KL_Mouse_OnMUp(*) {
		if A_IsSuspended {
				KLMouse.mbtn_held := false
				return
		}
		if !KLMouse.mbtn_held
				return
		KLMouse.mbtn_held := false
		try {
				CoordMode("Mouse", "Screen")
				MouseGetPos(&mx, &my)
				filtered := false
				try filtered := MF_ShouldFilter()
				if filtered
						return
				if !Keylogger.initialized
						return
				; Bump the click counter only AFTER the privacy filter + init checks, so clicks in
				; a password field / disabled app / private window do not accrue into the counts
				; that later ride into a typing row (mouse-counter-privacy-filter).
				KL_BumpMouseClick()
				; Use an async one-shot timer so context refresh doesn't block the hook thread
				try SetTimer(KL_Hook_RefreshContext.Bind(), -1)
				KL_Mouse_LogClick("middle", KLMouse.mbtn_down_x, KLMouse.mbtn_down_y)
		}
}





; ==================================
; ==================================
; ======= 4/ Scroll handlers =======
; ==================================
; ==================================

KL_Mouse_OnWheelUp(*) {
		KL_Mouse_AccumScroll(1)
}

KL_Mouse_OnWheelDown(*) {
		KL_Mouse_AccumScroll(-1)
}

KL_Mouse_OnWheelRight(*) {
		KL_Mouse_AccumScrollH(1)
}

KL_Mouse_OnWheelLeft(*) {
		KL_Mouse_AccumScrollH(-1)
}

KL_Mouse_AccumScroll(delta) {
		if A_IsSuspended
				return
		; Scrolls in a filtered window (password field / disabled app / private) must not
		; accrue into session_scrolls — gate accumulation behind the privacy filter, cached
		; (~50 ms TTL) so the hot-path cost stays negligible (mouse-counter-privacy-filter).
		filtered := false
		try filtered := MF_ShouldFilter()
		if filtered
				return
		now := A_TickCount
		if (KLMouse.scroll_last > 0
			and TickElapsed(KLMouse.scroll_last, now) > KLMouseConst.SCROLL_BURST_GAP_MS) {
				; Gap exceeded — flush the previous burst before starting a new one
				KL_Mouse_FlushScroll()
		}
		if (KLMouse.scroll_start = 0)
				KLMouse.scroll_start := now
		KLMouse.scroll_ticks += delta
		KLMouse.scroll_last  := now
		KL_BumpMouseScroll()
		; Arm a one-shot timer to flush after the burst ends
		try SetTimer(KLMouse.scroll_flush_fn, -KLMouseConst.SCROLL_BURST_GAP_MS)
}

KL_Mouse_AccumScrollH(delta) {
		if A_IsSuspended
				return
		; Same privacy gate as KL_Mouse_AccumScroll — a filtered window must not accrue into
		; session_scrolls via the horizontal wheel either (mouse-counter-privacy-filter).
		filtered := false
		try filtered := MF_ShouldFilter()
		if filtered
				return
		now := A_TickCount
		if (KLMouse.scroll_last > 0
			and TickElapsed(KLMouse.scroll_last, now) > KLMouseConst.SCROLL_BURST_GAP_MS) {
				KL_Mouse_FlushScroll()
		}
		if (KLMouse.scroll_start = 0)
				KLMouse.scroll_start := now
		KLMouse.scroll_h_ticks += delta
		KLMouse.scroll_last    := now
		KL_BumpMouseScroll()
		try SetTimer(KLMouse.scroll_flush_fn, -KLMouseConst.SCROLL_BURST_GAP_MS)
}

KL_Mouse_FlushScroll() {
		if A_IsSuspended {
				; Mirror KL_Mouse_ParkTick's suspend-path reset (line ~425): without
				; clearing the accumulator here, scroll_start/scroll_last stay stale
				; across the whole suspend window, so the next post-resume flush
				; computes a duration/velocity spanning the entire pause instead of
				; just the burst that actually occurred (keylogger-mouse-scroll-suspend-reset).
				KLMouse.scroll_ticks   := 0
				KLMouse.scroll_h_ticks := 0
				KLMouse.scroll_start   := 0
				KLMouse.scroll_last    := 0
				return
		}
		if (KLMouse.scroll_ticks = 0 and KLMouse.scroll_h_ticks = 0)
				return

		; Snapshot and reset atomically before calling MF_ShouldFilter, which can
		; yield the thread. Scrolls arriving during MF_ShouldFilter would otherwise
		; be captured in the locals but then cleared, losing them silently.
		previous_critical := Critical("On")
		try {
				ticks   := KLMouse.scroll_ticks
				h_ticks := KLMouse.scroll_h_ticks
				start   := KLMouse.scroll_start
				KLMouse.scroll_ticks   := 0
				KLMouse.scroll_h_ticks := 0
				KLMouse.scroll_start   := 0
				KLMouse.scroll_last    := 0
		} finally {
				; This timer can run inside a keyboard-owned transaction. Restore its
				; prior setting rather than disabling the caller's serialization.
				Critical(previous_critical)
		}

		filtered := false
		try filtered := MF_ShouldFilter()
		if filtered
				return
		if !Keylogger.initialized
				return
		; Use an async one-shot timer so context refresh doesn't block the hook thread
		try SetTimer(KL_Hook_RefreshContext.Bind(), -1)
		duration_ms := (A_TickCount - start) & 0xFFFFFFFF
		dir := (h_ticks != 0) ? "horizontal" : ((ticks > 0) ? "up" : "down")
		total := (h_ticks != 0) ? Abs(h_ticks) : Abs(ticks)
		velocity := (duration_ms > 0) ? Round(total / (duration_ms / 1000.0), 2) : 0
		CoordMode("Mouse", "Screen")
		MouseGetPos(&mx, &my)
		KL_AppendLog(Map(
				"type",        "mouse_scroll",
				"app",         Keylogger.session_app,
				"direction",   dir,
				"ticks",       total,
				"velocity",    velocity,
				"duration_ms", duration_ms,
				"x",           mx,
				"y",           my
		))
}





; ===================================
; ===================================
; ======= 5/ Park / idle poll =======
; ===================================
; ===================================

KL_Mouse_ParkTick() {
	CoordMode("Mouse", "Screen")
	MouseGetPos(&mx, &my)

	filtered := false
	if (!A_IsSuspended and Keylogger.initialized) {
		try filtered := MF_ShouldFilter()
	}

	if (A_IsSuspended or filtered or !Keylogger.initialized) {
		KLMouse.prev_x := mx
		KLMouse.prev_y := my
		KLMouse.park_last_x := -1
		return
	}

	; Distance accumulation — feeds the typing flush's mouse_distance_px
	if (KLMouse.prev_x >= 0) {
		dx := mx - KLMouse.prev_x
		dy := my - KLMouse.prev_y
		d  := Sqrt(dx*dx + dy*dy)
		if (d > 0)
			KL_BumpMouseDistance(Round(d))
	}
	KLMouse.prev_x := mx
	KLMouse.prev_y := my

	; Park detection
	if (KLMouse.park_last_x < 0) {
		KLMouse.park_last_x      := mx
		KLMouse.park_last_y      := my
		KLMouse.park_still_since := A_TickCount
		return
	}
	dx   := mx - KLMouse.park_last_x
	dy   := my - KLMouse.park_last_y
	moved := Sqrt(dx*dx + dy*dy)

	if (moved > KLMouseConst.PARK_JITTER_PX) {
		; Cursor moved — reset stillness clock
		KLMouse.park_last_x      := mx
		KLMouse.park_last_y      := my
		KLMouse.park_still_since := A_TickCount
		return
	}

	still_ms := (A_TickCount - KLMouse.park_still_since) & 0xFFFFFFFF
	if (still_ms < KLMouseConst.PARK_IDLE_MS)
		return

	; Check distance from the last park fire to avoid adjacent duplicates
	fdx := mx - KLMouse.park_fired_x
	fdy := my - KLMouse.park_fired_y
	fire_dist := Sqrt(fdx*fdx + fdy*fdy)
	if (fire_dist < KLMouseConst.PARK_MIN_MOVE_PX
			and (A_TickCount - (KLMouse.park_fired_at) & 0xFFFFFFFF) < 30000)
		return

	; Emit park event
	app := Keylogger.session_app
	KL_AppendLog(Map(
		"type",     "mouse_idle_park",
		"app",      app,
		"x",        mx,
		"y",        my,
		"still_ms", still_ms
	))
	KLMouse.park_fired_x  := mx
	KLMouse.park_fired_y  := my
	KLMouse.park_fired_at := A_TickCount

	; Reset so we don't keep firing every PARK_CHECK_MS while still idle
	KLMouse.park_still_since := A_TickCount
}





; ==============================
; ==============================
; ======= 6/ Log helpers =======
; ==============================
; ==============================

KL_Mouse_LogClick(button, x, y) {
		KL_AppendLog(Map(
				"type",   "mouse_click",
				"app",    Keylogger.session_app,
				"button", button,
				"x",      x,
				"y",      y
		))
}

KL_Mouse_LogDrag(button, x1, y1, x2, y2, dist_px, duration_ms) {
		KL_AppendLog(Map(
				"type",        "mouse_drag",
				"app",         Keylogger.session_app,
				"button",      button,
				"x1",          x1,
				"y1",          y1,
				"x2",          x2,
				"y2",          y2,
				"dist_px",     dist_px,
				"duration_ms", duration_ms
		))
}





; ============================
; ============================
; ======= 7/ Lifecycle =======
; ============================
; ============================

KL_Mouse_Start() {
		; Idempotent — do nothing if the park timer is already alive
		if KLMouse.HasOwnProp("park_timer_fn") && IsObject(KLMouse.park_timer_fn)
				return

		; Bind scroll-flush once so SetTimer can cancel by reference
		KLMouse.scroll_flush_fn := KL_Mouse_FlushScroll.Bind()

		; Park / distance poll — still owned here because no other module needs it
		KLMouse.park_timer_fn := KL_Mouse_ParkTick.Bind()
		SetTimer(KLMouse.park_timer_fn, KLMouseConst.PARK_CHECK_MS)

		; Register mouse event subscribers with HookDispatcher instead of calling
		; Hotkey() directly. HookDispatcher owns the single set of mouse hotkeys
		; for the whole process; all modules subscribe through it.
		KLMouse.hk_ldown   := KL_Mouse_OnLDown.Bind()
		KLMouse.hk_lup     := KL_Mouse_OnLUp.Bind()
		KLMouse.hk_rdown   := KL_Mouse_OnRDown.Bind()
		KLMouse.hk_rup     := KL_Mouse_OnRUp.Bind()
		KLMouse.hk_mdown   := KL_Mouse_OnMDown.Bind()
		KLMouse.hk_mup     := KL_Mouse_OnMUp.Bind()
		KLMouse.hk_wup     := KL_Mouse_OnWheelUp.Bind()
		KLMouse.hk_wdn     := KL_Mouse_OnWheelDown.Bind()
		KLMouse.hk_wright  := KL_Mouse_OnWheelRight.Bind()
		KLMouse.hk_wleft   := KL_Mouse_OnWheelLeft.Bind()

		HookDispatcher.Register(HookDispatcherConst.EVT_MS_LDOWN,  KLMouse.hk_ldown)
		HookDispatcher.Register(HookDispatcherConst.EVT_MS_LUP,    KLMouse.hk_lup)
		HookDispatcher.Register(HookDispatcherConst.EVT_MS_RDOWN,  KLMouse.hk_rdown)
		HookDispatcher.Register(HookDispatcherConst.EVT_MS_RUP,    KLMouse.hk_rup)
		HookDispatcher.Register(HookDispatcherConst.EVT_MS_MDOWN,  KLMouse.hk_mdown)
		HookDispatcher.Register(HookDispatcherConst.EVT_MS_MUP,    KLMouse.hk_mup)
		HookDispatcher.Register(HookDispatcherConst.EVT_MS_WUP,    KLMouse.hk_wup)
		HookDispatcher.Register(HookDispatcherConst.EVT_MS_WDN,    KLMouse.hk_wdn)
		HookDispatcher.Register(HookDispatcherConst.EVT_MS_WRIGHT, KLMouse.hk_wright)
		HookDispatcher.Register(HookDispatcherConst.EVT_MS_WLEFT,  KLMouse.hk_wleft)
}

KL_Mouse_Stop() {
		if KLMouse.HasOwnProp("park_timer_fn") && IsObject(KLMouse.park_timer_fn) {
				try SetTimer(KLMouse.park_timer_fn, 0)
				KLMouse.park_timer_fn := unset
		}
		if KLMouse.HasOwnProp("scroll_flush_fn") && IsObject(KLMouse.scroll_flush_fn) {
				try SetTimer(KLMouse.scroll_flush_fn, 0)
				KLMouse.scroll_flush_fn := unset   ; clear ref before drain so re-entry can't re-arm a stale timer
				try KL_Mouse_FlushScroll()         ; drain pending scroll burst
		}
		; Unregister subscribers from HookDispatcher — the shared Hotkeys
		; remain active for any other modules still listening.
		if KLMouse.HasOwnProp("hk_ldown") {
				try HookDispatcher.Unregister(HookDispatcherConst.EVT_MS_LDOWN,  KLMouse.hk_ldown)
				try HookDispatcher.Unregister(HookDispatcherConst.EVT_MS_LUP,    KLMouse.hk_lup)
				try HookDispatcher.Unregister(HookDispatcherConst.EVT_MS_RDOWN,  KLMouse.hk_rdown)
				try HookDispatcher.Unregister(HookDispatcherConst.EVT_MS_RUP,    KLMouse.hk_rup)
				try HookDispatcher.Unregister(HookDispatcherConst.EVT_MS_MDOWN,  KLMouse.hk_mdown)
				try HookDispatcher.Unregister(HookDispatcherConst.EVT_MS_MUP,    KLMouse.hk_mup)
				try HookDispatcher.Unregister(HookDispatcherConst.EVT_MS_WUP,    KLMouse.hk_wup)
				try HookDispatcher.Unregister(HookDispatcherConst.EVT_MS_WDN,    KLMouse.hk_wdn)
				try HookDispatcher.Unregister(HookDispatcherConst.EVT_MS_WRIGHT, KLMouse.hk_wright)
				try HookDispatcher.Unregister(HookDispatcherConst.EVT_MS_WLEFT,  KLMouse.hk_wleft)
		}
}
