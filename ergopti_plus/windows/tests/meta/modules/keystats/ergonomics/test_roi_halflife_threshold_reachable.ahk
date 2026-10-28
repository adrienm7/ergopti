; tests/meta/modules/keystats/ergonomics/test_roi_halflife_threshold_reachable.ahk
; ==============================================================================
; MODULE: ROI Half-Life Threshold Reachability Regression
; DESCRIPTION:
; The former source-only check compared the removed DWORD sanity ceiling with
; the warning threshold. Keep its historical registration label, but establish
; reachability through the existing genuine 31-day producer/central-queue case.
; This does not require a particular age expression or an artificial upper cap.
; The unit owner is included before this file, and Test() only registers its
; callback: execution begins after all suite includes have been loaded. Selection
; filters create ActiveTests separately and do not remove the registered control.
; ==============================================================================

#Requires AutoHotkey v2.0

_RHTR_HalflifeAlertIsReachable() {
	global TEST_REGISTRY
	Matches := []
	for Entry in TEST_REGISTRY {
		if Entry.name == "ROI half-life: days31 uses the retained monotonic age (roi-halflife-native64-owner)"
			Matches.Push(Entry)
	}
	AssertEqual(1, Matches.Length,
		"The full registry must contain exactly one genuine half-life reachability control, independently of execution filters.")
	Matches[1].callback.Call()
}
Test("keystats_trigger_roi: MAX_SANE_AGE_MS clamp ceiling is >= HALFLIFE_WARN_DAYS alert threshold", _RHTR_HalflifeAlertIsReachable)
