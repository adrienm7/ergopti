; tests/meta/test_gestures_action_catalog_deferred.ahk

; ==============================================================================
; MODULE: Gestures Action-Catalogue Boot-Cost Regression Test
; DESCRIPTION:
; Guards that the gesture action catalogue costs nothing at boot and is ready
; synchronously: it is the generated data function GestureActionCatalogueData()
; (_generated/action_catalogue.ahk), and no driver code parses actions.toml.
;
; WHY THIS MATTERS (the regressions this encodes):
;   perf-gestures-deferred: building the picker list used to run
;   ParseTomlFile(actions.toml) plus a walk of hundreds of entries — ~100 ms of
;   the 183 ms gestures init — so it was deferred with SetTimer(-1).
;   gesture-action-catalog-never-loads: that deferral once used SetTimer(fn, -0),
;   which AHK v2 treats as 0 and DISABLES, so the list stayed empty and the
;   picker was blank. The deferral also left parameter metadata empty until the
;   timer fired, so an early open_url binding was invoked without its binding id.
;   The generated catalogue removes the parse and the timer altogether; this test
;   pins both halves: the data is there without calling any loader, and no
;   runtime TOML read of the action registry can creep back.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckGesturesActionCatalogDeferred() {
	global GESTURE_ACTION_CATALOGUE
	; Behavioural half: populated at static-init, no loader, no timer.
	Assert(IsSet(GESTURE_ACTION_CATALOGUE) && IsObject(GESTURE_ACTION_CATALOGUE),
		"the generated action catalogue must be loaded at static-init (perf-gestures-deferred)")
	Assert(GESTURE_ACTION_CATALOGUE.SgItems.Length >= 100,
		"the catalogue carries only " . GESTURE_ACTION_CATALOGUE.SgItems.Length
		. " picker item(s) before any timer ran (gesture-action-catalog-never-loads)")
	AssertEqual("url", GestureActionParameterSpec("open_url"),
		"parameter metadata must be ready before the first dispatch, not after a deferred loader")

	; Source half: the registry is never parsed at runtime again. Comments are
	; stripped so this header, and the module docs that name the source file,
	; cannot satisfy or trip the scan.
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the catalogue boot-cost meta-test")
	Assert(InStr(Src, "GestureActionCatalogueData()"),
		"the driver must build its catalogue from the generated data function")
	Assert(!InStr(Src, "actions\actions.toml") && !InStr(Src, "actions/actions.toml"),
		"no driver code may read the shared actions.toml at runtime — run "
		. "npm run codegen:action-catalogue and consume _generated/action_catalogue.ahk (perf-gestures-deferred)")
	Assert(!InStr(Src, "_GestureLoadActionCatalog"),
		"the deferred TOML loader must not come back (gesture-action-catalog-never-loads)")
}

Test("meta perf: gestures action catalogue is generated data, ready without a timer (perf-gestures-deferred)",
	_MetaCheckGesturesActionCatalogDeferred)
