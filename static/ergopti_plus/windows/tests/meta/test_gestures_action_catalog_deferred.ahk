; tests/meta/test_gestures_action_catalog_deferred.ahk

; ==============================================================================
; MODULE: Gestures Action-Catalog Deferred-Init Regression Test
; DESCRIPTION:
; Guards that the gesture action-catalog (ParseTomlFile + GESTURE_ACTION_NAMES /
; GESTURE_AX_NAMES building) is deferred off the boot critical path via a
; zero-delay SetTimer, not executed inline during auto-execute.
;
; WHY THIS MATTERS (the regression this encodes):
;   Building GESTURE_ACTION_NAMES requires ParseTomlFile(actions.toml) plus
;   iterating hundreds of entries with placeholder expansions. Measured boot
;   cost: ~100 ms of the 183 ms gestures module init time.  These lists are
;   only used by the gesture-picker menu (built in the deferred initMenu phase
;   ~250 ms after boot), so there is no functional reason to block the critical
;   path on them. Reverting to inline execution restores the 100 ms regression.
;
; SCOPE: source introspection of modules/gestures.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckGesturesActionCatalogDeferred() {
	; Move-resilient: scan the modules tree via the framework helper instead of a
	; pinned gestures path. Every token below is _Gesture*-prefixed and unique to
	; gestures.ahk within modules/, so the scope stays meaningful.
	Body := _DriverDirConcat("modules")
	Assert(Body != "", "modules\gestures.ahk must be readable for the gestures-deferred meta-test")

	; The deferred loader function must exist.
	Assert(InStr(Body, "_GestureLoadActionCatalog("),
		"gestures.ahk must define _GestureLoadActionCatalog() to build the action catalog off the boot path")

	; It must be armed as a run-once SetTimer with a negative NON-ZERO period
	; (fires once after auto-execute finishes).
	Assert(InStr(Body, "SetTimer(_GestureLoadActionCatalog, -1)"),
		"gestures.ahk must call SetTimer(_GestureLoadActionCatalog, -1) to defer catalog init (perf-gestures-deferred)")

	; Regression for gesture-action-catalog-never-loads: AHK v2 treats -0 as 0,
	; and SetTimer(fn, 0) DISABLES the timer — the callback never fires, so
	; GESTURE_ACTION_NAMES stayed empty and the action picker was blank. The
	; defer period must never be -0 (or 0).
	Assert(!InStr(Body, "SetTimer(_GestureLoadActionCatalog, -0)")
		and !InStr(Body, "SetTimer(_GestureLoadActionCatalog, 0)"),
		"gestures.ahk must NOT defer the catalog with a zero period — SetTimer(fn, -0)/(fn, 0) "
		. "disables the timer so the catalog never loads (gesture-action-catalog-never-loads)")

	; The inline ParseTomlFile call for the shared TOML must be gone from the
	; auto-execute body — it must live inside _GestureLoadActionCatalog, not at
	; file scope where it blocks every boot.
	; Strategy: verify there is NO top-level ParseTomlFile call that references
	; the shared actions.toml path outside of a function body. We do this by
	; checking that the pattern "_GestureSharedToml := " (the old file-scope var)
	; is absent from the top-level code.
	Assert(!InStr(Body, "_GestureSharedToml := "),
		"gestures.ahk must not have a top-level '_GestureSharedToml :=' assignment — "
		. "ParseTomlFile must only run inside _GestureLoadActionCatalog (perf-gestures-deferred)")
	Assert(!InStr(Body, "_GestureTomlData := ParseTomlFile("),
		"gestures.ahk must not have a top-level '_GestureTomlData := ParseTomlFile(...)' call — "
		. "the TOML parse must only run inside _GestureLoadActionCatalog (perf-gestures-deferred)")
}

Test("meta perf: gestures action catalog deferred via SetTimer (perf-gestures-deferred)",
	_MetaCheckGesturesActionCatalogDeferred)
