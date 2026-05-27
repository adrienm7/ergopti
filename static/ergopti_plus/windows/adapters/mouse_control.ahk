; adapters/mouse_control.ahk

; ==============================================================================
; MODULE: MouseControl Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the MouseControl port contract defined in
; static/ergopti_plus/_shared/ports/MouseControl.spec.js. Wraps AHK v2's
; MouseMove, MouseGetPos, MonitorGetCount, and MonitorGet built-ins behind
; four canonical functions so domain modules can read and write the cursor
; position and query monitor geometry without coupling to AHK-specific APIs.
;
; NAMING CONVENTION:
; Port method          → AHK function name
;   setPos(x, y)       → MCSetPos(X, Y)
;   getPos()           → MCGetPos()
;   getMonitorCount()  → MCGetMonitorCount()
;   getMonitorBounds() → MCGetMonitorBounds(N)
;
; RETURN SHAPES:
; MCGetPos()           returns a Map: { "x", "y" }
; MCGetMonitorBounds() returns a Map: { "left", "top", "right", "bottom" }
;
; COORDINATE SYSTEM:
; All coordinates are absolute virtual-desktop pixels. SetPhysicalCursorPos
; via DllCall is used for setPos to bypass CoordMode and avoid relative offsets.
;
; FAIL-SAFE:
; All OS calls are wrapped in try/catch. If the cursor or monitor cannot be
; queried, functions return typed zero-value objects rather than throwing.
; ==============================================================================




; ==========================================
; ==========================================
; ======= 1/ Internal Helpers ==============
; ==========================================
; ==========================================

; Returns a zero-coordinate position Map.
_MCZeroPos() {
	return Map("x", 0, "y", 0)
}

; Returns a zero-value monitor bounds Map.
_MCZeroBounds() {
	return Map("left", 0, "top", 0, "right", 0, "bottom", 0)
}




; ========================================
; ========================================
; ======= 2/ Adapter Methods =============
; ========================================
; ========================================

; Moves the mouse cursor to an absolute virtual-desktop position.
; Uses DllCall("SetCursorPos") to bypass AHK CoordMode for deterministic
; behaviour regardless of any active CoordMode setting in the calling script.
; @param X {Integer} Horizontal pixel coordinate.
; @param Y {Integer} Vertical pixel coordinate.
MCSetPos(X, Y) {
	try {
		DllCall("SetCursorPos", "Int", X, "Int", Y)
	}
}

; Returns the current absolute cursor position.
; @return {Map} { "x": Integer, "y": Integer } (both 0 on error).
MCGetPos() {
	local Info := _MCZeroPos()
	try {
		local CX := 0, CY := 0
		MouseGetPos(&CX, &CY)
		Info["x"] := CX
		Info["y"] := CY
	}
	return Info
}

; Returns the total number of monitors attached to the system.
; @return {Integer} Monitor count (>= 1 normally, 0 on error).
MCGetMonitorCount() {
	try {
		return MonitorGetCount()
	} catch {
		return 0
	}
}

; Returns the bounding rectangle of monitor N (1-indexed).
; @param N {Integer} Monitor index starting at 1.
; @return {Map} { "left", "top", "right", "bottom" } (all 0 on error or out-of-range).
MCGetMonitorBounds(N) {
	local Bounds := _MCZeroBounds()
	try {
		local L := 0, T := 0, R := 0, B := 0
		MonitorGet(N, &L, &T, &R, &B)
		Bounds["left"]   := L
		Bounds["top"]    := T
		Bounds["right"]  := R
		Bounds["bottom"] := B
	}
	return Bounds
}