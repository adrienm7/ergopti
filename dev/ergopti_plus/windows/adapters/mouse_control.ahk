; adapters/mouse_control.ahk

; ==============================================================================
; MODULE: MouseControl Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the MouseControl port contract defined in
; static/ergopti_plus/_shared/core/ports/MouseControl.spec.js. Wraps AHK v2's
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
; All coordinates are physical (DPI-unscaled) virtual-desktop pixels.
; SetPhysicalCursorPos / GetPhysicalCursorPos are used so coordinates remain
; consistent on high-DPI monitors without relying on the process DPI-awareness
; mode or AHK's CoordMode setting.
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

; Moves the mouse cursor to an absolute physical-pixel position.
; Uses SetPhysicalCursorPos so the coordinates are DPI-unscaled and correct
; on high-DPI monitors, independent of the process DPI-awareness mode or
; any active AHK CoordMode setting.
; @param X {Integer} Horizontal physical pixel coordinate.
; @param Y {Integer} Vertical physical pixel coordinate.
MCSetPos(X, Y) {
	try {
		DllCall("SetPhysicalCursorPos", "Int", X, "Int", Y)
	} catch as Err {
		; Port contract (MouseControl.spec.js) mandates error_behavior "silent_noop"
		; for setPos — callers never see a return value — so the failure must stay
		; silent to the caller while still being diagnosable in the log.
		try LoggerWarn("MouseControl", "MCSetPos failed for ({1}, {2}): {3}.", X, Y, Err.Message)
	}
}

; Returns the current cursor position in physical pixels.
; Uses GetPhysicalCursorPos so coordinates match what SetPhysicalCursorPos
; writes, ensuring a set/get round-trip is lossless on high-DPI displays.
; @return {Map} { "x": Integer, "y": Integer } (both 0 on error).
MCGetPos() {
	local Info := _MCZeroPos()
	try {
		local POINT := Buffer(8, 0)   ; POINT struct = two 32-bit ints
		DllCall("GetPhysicalCursorPos", "Ptr", POINT)
		Info["x"] := NumGet(POINT, 0, "Int")
		Info["y"] := NumGet(POINT, 4, "Int")
	} catch as Err {
		try LoggerWarn("MouseControl", "MCGetPos failed: {1}.", Err.Message)
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

; Port dispatch map (ADAPTER_MOUSE_CONTROL) — the single-source-of-truth contract
; surface, verified against _shared/core/ports/contracts.json by
; tools/test/test-port-compliance.cjs.
global ADAPTER_MOUSE_CONTROL := Map(
    "getMonitorBounds", MCGetMonitorBounds,
    "getMonitorCount", MCGetMonitorCount,
    "getPos", MCGetPos,
    "setPos", MCSetPos
)
