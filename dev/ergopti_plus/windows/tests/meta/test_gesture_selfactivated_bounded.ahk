; tests/meta/test_gesture_selfactivated_bounded.ahk

; ==============================================================================
; MODULE: Gesture Self-Activated Map Bounded Meta Test
; DESCRIPTION:
; Regression guard for AHK-24: _GestureSelfActivated Map (modules/gestures/
; actions.ahk) grew unbounded across a long session. GestureActivateWindow
; inserts _GestureSelfActivated[HWnd] := A_TickCount before every activation,
; and the ONLY removal was .Delete(HWnd) inside _GestureOnForeground on a
; matching EVENT_SYSTEM_FOREGROUND event. Three leak paths meant entries were
; never reclaimed:
;   (a) Activation throws (catch at window_cycle.ahk:226) — WinEvent never fires.
;   (b) Activating an already-foreground window emits no WinEvent.
;   (c) The WinEvent arrives after a suspend — _GestureOnForeground returns at
;       the A_IsSuspended early-return before the .Delete() block.
;
; This is the same unbounded-growth class fixed for the sibling _GestureWinOrder
; (explicitly capped via GESTURE_WIN_ORDER_MAX + guarded by
; test_winorder_unbounded_and_cross_thread.ahk) — _GestureSelfActivated was
; the overlooked sibling.
;
; The fix adds a TTL prune loop in GestureActivateWindow (before the new entry
; is inserted): entries whose age >= GESTURE_SELF_ACTIVATE_TTL_MS are collected
; and deleted, keeping the Map bounded to in-flight self-activations within one
; TTL window.
;
; This test asserts (source introspection):
;   (a) GestureActivateWindow body references GESTURE_SELF_ACTIVATE_TTL_MS —
;       the prune uses the same TTL constant as the consume block, so a future
;       TTL change updates both locations.
;   (b) GestureActivateWindow body calls _GestureSelfActivated.Delete() — the
;       prune actually removes stale entries.
;   (c) The .Delete() call appears BEFORE the new-entry assignment
;       (_GestureSelfActivated[HWnd] := A_TickCount), so every insert is
;       preceded by a prune of expired entries.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Test implementation ====================================
; ===================================================================
; ===================================================================

_TGSAB_CheckSelfActivatedBounded() {
	Body := _DriverFuncBody("GestureActivateWindow")
	Assert(Body != "", "GestureActivateWindow must exist in modules/gestures/window_cycle.ahk")

	; (a) TTL constant referenced — prune uses the canonical TTL
	Assert(InStr(Body, "GESTURE_SELF_ACTIVATE_TTL_MS"),
		"AHK-24: GestureActivateWindow must reference GESTURE_SELF_ACTIVATE_TTL_MS to prune stale _GestureSelfActivated entries — the Map grew unbounded because failed/no-op/suspended-race activations are never reclaimed by _GestureOnForeground")

	; (b) Must call .Delete() on _GestureSelfActivated to remove stale entries
	Assert(InStr(Body, "_GestureSelfActivated.Delete"),
		"AHK-24: GestureActivateWindow must call _GestureSelfActivated.Delete(...) to remove stale entries before inserting the new one — without this the Map is only pruned by _GestureOnForeground which misses the three leak paths (throw / no-foreground-event / suspended-race)")

	; (c) Delete must precede the new-entry assignment
	DeletePos := InStr(Body, "_GestureSelfActivated.Delete")
	AssignPos := InStr(Body, "_GestureSelfActivated[HWnd] := A_TickCount")
	Assert(DeletePos > 0 && AssignPos > 0 && DeletePos < AssignPos,
		"AHK-24: _GestureSelfActivated.Delete(...) must appear BEFORE the new-entry assignment '_GestureSelfActivated[HWnd] := A_TickCount' in GestureActivateWindow — the prune must happen before the insert so the new entry itself is never purged in the same pass")
}


Test("meta ahk-24: GestureActivateWindow prunes stale _GestureSelfActivated entries before inserting to bound Map growth",
	_TGSAB_CheckSelfActivatedBounded)
