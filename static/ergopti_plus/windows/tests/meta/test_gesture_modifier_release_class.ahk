; tests/meta/test_gesture_modifier_release_class.ahk

; ==============================================================================
; MODULE: Gesture Modifier Release Class Guard
; DESCRIPTION:
; Prevents any gesture path from restoring the old raw all-modifier Up burst.
; ==============================================================================

#Requires AutoHotkey v2.0

_GMRC_Count(Haystack, Needle) {
		Count := 0
		Position := 1
		while (Position := InStr(Haystack, Needle, true, Position)) {
			Count += 1
			Position += StrLen(Needle)
		}
		return Count
}

_GMRC_AllSitesUseOwner() {
		Src := _DriverDirConcat("modules\gestures")
		AssertTrue(Src != "", "gesture source must be discoverable")
		AssertTrue(_GMRC_Count(Src, "GestureReleaseOwnedCarrierModifiers(") >= 5,
				"the helper definition and all four gesture cleanup sites must be present")
		AssertTrue(InStr(Src, "{LAlt up}", false) == 0,
				"Alt is not part of the gesture carrier and must never be force-released")
		AssertTrue(InStr(Src, "{RAlt up}", false) == 0,
				"AltGr/user RAlt ownership must remain untouched")
}
Test("gestures: every modifier cleanup site uses the ownership helper", _GMRC_AllSitesUseOwner)
