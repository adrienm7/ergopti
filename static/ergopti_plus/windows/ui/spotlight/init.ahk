; ui/spotlight/init.ahk
; Requires: GraphicsRenderer

; ==============================================================================
; MODULE: Spotlight Overlay
; DESCRIPTION:
; GDI+ layered-window overlay that highlights the mouse cursor position:
; a filled yellow circle on the cursor's monitor and a red cross on every
; other monitor. Dismissed after a configured timeout or as soon as the mouse
; moves more than 5 pixels from the trigger point.
;
; FEATURES & RATIONALE:
; 1. GDI+ via DllCall: AHK v2 ships no graphics library; the GDI+ COM layer is
;    loaded per-call and shut down immediately after the windows are destroyed
;    so no global state leaks between invocations.
; 2. Per-pixel alpha: UpdateLayeredWindow with AC_SRC_ALPHA renders the
;    semi-transparent fill and stroke without a rectangular bounding box.
; 3. Extracted here from modules/shortcuts/win.ahk so the rendering logic is
;    testable and shareable without loading any hotkey-registration code.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ownership.ahk





; =====================================
; =====================================
; ======= 1/ Spotlight renderer =======
; =====================================
; =====================================

global _Spotlight_State := _SpotlightNewState()

; Draws a filled yellow circle around (X, Y) and a red cross on every other
; monitor, matching the Hammerspoon spotlight visual exactly.
; Dismissed after DurationMs ms or as soon as the mouse moves more than 5 px.
SpotlightMouseAt(X, Y, DurationMs) {
	global _Spotlight_State
	Claim := _SpotlightClaimStart(_Spotlight_State)
	if !Claim["ok"]
		return false

	static RING_RADIUS    := 60     ; Matches Hammerspoon SPOTLIGHT_RADIUS_PX
	static RING_STROKE    := 6      ; Matches SPOTLIGHT_STROKE_PX
	static FILL_ALPHA     := 102    ; 0.40 x 255 -- matches SPOTLIGHT_FILL_ALPHA
	static STROKE_ALPHA   := 230    ; 0.90 x 255 -- matches OVERLAY_STROKE_ALPHA
	static PAD            := 12     ; Matches SPOTLIGHT_PADDING_PX
	static CROSS_HALF     := 60     ; Matches CROSS_ARM_HALF_PX
	static CROSS_WIDTH    := 14     ; Matches CROSS_ARM_WIDTH_PX

	; ARGB values (pre-multiplied alpha not needed for UpdateLayeredWindow with AC_SRC_ALPHA)
	static YELLOW_FILL    := 0x66FFDA00   ; alpha=0x66(102), R=255, G=218, B=0
	static YELLOW_STROKE  := 0xE6FFDA00   ; alpha=0xE6(230)
	static RED_FILL       := 0x66E61A0D   ; alpha=0x66, R=230, G=26, B=13
	static RED_STROKE     := 0xE6E61A0D   ; alpha=0xE6

	; --- Helper: create a layered window, paint via GDI+ callback, return hwnd ---
	; Delegates window lifecycle and bitmap upload to the GraphicsRenderer adapter.
	; DrawCallback receives (pGfx, WinW, WinH) where pGfx is a GDI+ Graphics ptr.
	CreateOverlayWindow(WinX, WinY, WinW, WinH, DrawCallback) {
		Opts := Map("x", WinX, "y", WinY, "w", WinW, "h", WinH,
			"clickThrough", true, "alwaysOnTop", true)
		return _SpotlightCreateOverlayWindow(Opts, DrawCallback)
	}

	Receipt := _SpotlightSessionNewReceipt()
	try {
		if Claim["previous"]
			_SpotlightSessionSettle(Claim["previous"])
		if !_SpotlightSessionDrainDebt()
			throw Error("Previous Spotlight session cleanup is still pending")
		_SpotlightSessionAcquireGdi(Receipt)

		; --- Draw the yellow filled circle on the cursor's screen ---
		Size   := (RING_RADIUS + PAD) * 2
		WinX   := X - RING_RADIUS - PAD
		WinY   := Y - RING_RADIUS - PAD

		CircleDraw(pGfx, W, H) {
			_SpotlightDrawCircleResources(pGfx, PAD, RING_RADIUS, RING_STROKE,
				YELLOW_FILL, YELLOW_STROKE)
		}

		CircleCreate := CreateOverlayWindow.Bind(WinX, WinY, Size, Size,
			CircleDraw)
		_SpotlightSessionAcquireWindow(Receipt, CircleCreate)

		; --- Draw a red cross centered on every OTHER monitor ---
		CrossSize := (CROSS_HALF + PAD) * 2

		MonCount := MonitorGetCount()
		loop MonCount {
			MonitorGet(A_Index, &ML, &MT, &MR, &MB)
			; Skip the monitor that holds the cursor
			if (X >= ML and X < MR and Y >= MT and Y < MB)
				continue

			CX := ML + (MR - ML) // 2
			CY := MT + (MB - MT) // 2

			CWinX := CX - CROSS_HALF - PAD
			CWinY := CY - CROSS_HALF - PAD

			CrossDraw(pGfx, W, H) {
				_SpotlightDrawCrossResources(pGfx, PAD, CROSS_HALF, CROSS_WIDTH,
					RING_STROKE, RED_FILL, RED_STROKE)
			}

			CrossCreate := CreateOverlayWindow.Bind(CWinX, CWinY, CrossSize,
				CrossSize, CrossDraw)
			_SpotlightSessionAcquireWindow(Receipt, CrossCreate)
		}

		; --- Poll for mouse move or timeout, then destroy all windows ---
		if A_IsSuspended
			throw Error("Spotlight cannot publish while the driver is suspended")
		Data := Map("StartX", X, "StartY", Y, "StartedTick", A_TickCount,
			"DurationMs", DurationMs)
		if !_SpotlightPublishStart(_Spotlight_State, Claim["generation"],
				Receipt, Data)
			throw Error("Spotlight start ownership was cancelled before publication")
		return true
	} catch as Err {
		_SpotlightSessionSettle(Receipt)
		_SpotlightAbandonStart(_Spotlight_State, Claim["generation"])
		throw Err
	}
}

_SpotlightTick() {
	global _Spotlight_State
	Snapshot := _SpotlightActiveSnapshot(_Spotlight_State)
	if !(Snapshot is Map) {
		_SpotlightSessionTimerNative.Stop()
		return
	}
	if A_IsSuspended {
		_SpotlightDismiss(Snapshot["Generation"])
		return
	}
	MouseGetPos(&NowX, &NowY)
	if (TickExpired(Snapshot["StartedTick"], Snapshot["DurationMs"])
		or Abs(NowX - Snapshot["StartX"]) > 5
		or Abs(NowY - Snapshot["StartY"]) > 5) {
		_SpotlightDismiss(Snapshot["Generation"])
	}
}

_SpotlightDismiss(ExpectedGeneration := 0) {
	global _Spotlight_State
	Claim := _SpotlightClaimDismiss(_Spotlight_State, ExpectedGeneration)
	if !Claim["ok"]
		return false
	if Claim.Get("pending", false)
		return true
	Released := _SpotlightSessionSettle(Claim["receipt"])
	_SpotlightFinishDismiss(_Spotlight_State, Claim["generation"])
	return Released
}
