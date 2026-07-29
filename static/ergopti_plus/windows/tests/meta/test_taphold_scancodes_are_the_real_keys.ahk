; tests/meta/test_taphold_scancodes_are_the_real_keys.ahk

; ==============================================================================
; MODULE: Tap-Hold Physical Scancode Regression Test
; DESCRIPTION:
; The Delete tap-hold bound *$SC053, which is NumpadDel/NumpadDot — NOT the
; nav-cluster Delete key, whose scancode is the EXTENDED one AHK reports for
; "Delete". Every hotkey in modules/tap_holds/delete.ahk therefore sat on a key
; the user was not pressing, so the configured Delete tap action, hold modifier
; and hold layer could never fire. The module docstring asserted the opposite
; ("this remaps the physical Delete/Suppr key (SC053)"), which is why several
; audits read past it.
;
; The driver already knew the right value: lib/script_altgr_hotkeys.ahk binds the
; extended Delete scancode in four places. This was the single forgotten sibling.
;
; FEATURES & RATIONALE:
; 1. Truth comes from AutoHotkey itself via GetKeySC/GetKeyName, never from a
;    scancode table re-typed in this file, so the expectation cannot drift from
;    the OS mapping the driver actually runs against.
; 2. Move-resilient: reads the whole driver through _DriverSourceNoComments()
;    rather than a hardcoded module path, so splitting or moving a tap-hold file
;    cannot turn this guard into a path error (and it does not raise the
;    location-pinned-source-read ratchet).
; ==============================================================================

#Requires AutoHotkey v2.0

; Keys whose tap-hold must bind the EXTENDED scancode. Each entry is the AHK key
; name; the expected scancode is resolved from AutoHotkey at run time.
global _THSC_EXTENDED_KEYS := ["Delete"]

; A tap-hold bound to the wrong physical key is silent: the hotkey registers
; fine, it simply never fires, so there is no error anywhere to notice.
_THSC_ExtendedKeysBindTheirRealScancode() {
	global _THSC_EXTENDED_KEYS
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable")

	for , KeyName in _THSC_EXTENDED_KEYS {
		Sc := GetKeySC(KeyName)
		Assert(Sc != 0, "AutoHotkey must resolve a scancode for '" . KeyName . "'")
		Expected := "SC" . Format("{:03X}", Sc)

		Assert(RegExMatch(Src, "im)^\s*[*~$]*\s*" . Expected . "\s*::"),
			"the driver must bind " . Expected . " (" . KeyName . ") as a hotkey — that is the "
			. "scancode AutoHotkey reports for " . KeyName . " on this machine")

		; The non-extended twin is a DIFFERENT physical key (SC053 = NumpadDel for
		; Delete). Binding it is the regression this test exists for.
		NonExtended := "SC0" . SubStr(Expected, 4)
		if (NonExtended != Expected) {
			Assert(!RegExMatch(Src, "im)^\s*[*~$]*\s*" . NonExtended . "\s*(&|::)"),
				"no hotkey may bind " . NonExtended . " (" . GetKeyName(NonExtended) . ") when it "
				. "is meant to remap " . KeyName . " — " . KeyName . " is " . Expected
				. ", so the non-extended twin binds a different physical key and the tap-hold "
				. "silently never fires")
		}
	}
}
Test("tap-holds: extended keys bind the scancode AHK reports for them", _THSC_ExtendedKeysBindTheirRealScancode)

; The Delete tap-hold's own dispatch must hang off the extended scancode.
_THSC_DeleteDispatchIsOnTheExtendedScancode() {
	Src := _DriverSourceNoComments()
	Expected := "SC" . Format("{:03X}", GetKeySC("Delete"))
	Assert(RegExMatch(Src, "im)^\s*[*~$]*\s*" . Expected . "\s*::\s*_DeleteDispatch\(\)"),
		"_DeleteDispatch must be bound to " . Expected . " — the Delete tap-hold's tap action "
		. "is unreachable from any other scancode")
}
Test("tap-holds: _DeleteDispatch is bound to the real Delete key", _THSC_DeleteDispatchIsOnTheExtendedScancode)
