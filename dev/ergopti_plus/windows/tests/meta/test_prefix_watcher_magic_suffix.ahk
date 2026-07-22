; tests/meta/test_prefix_watcher_magic_suffix.ahk

; ==============================================================================
; MODULE: Prefix Watcher IsMagic Trailing-Suffix Guard
; DESCRIPTION:
; Static source guard for the HasMagic trailing-suffix check fix in
; lib/hotstrings/hotstring_prefix_watcher.ahk.
;
; ROOT CAUSE ENCODED:
; The original check used InStr(Entry.Trigger, MK) > 0, which matched any
; trigger that contained the magic key character anywhere — including in the
; middle of the trigger. This caused false positives for triggers like "a★b"
; where the magic key was not a suffix. The fix changes this to a strict
; trailing-suffix test:
;   HasMagic := (MkLen > 0 and Len > MkLen and SubStr(Trigger, -MkLen) == MagicKey)
; which only matches when the magic key appears at the END of the trigger string.
; ==============================================================================

#Requires AutoHotkey v2.0

_TPWMS_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}





; ===============================================================
; ===============================================================
; ======= 1/ Trailing-suffix form used for magic-key test =======
; ===============================================================
; ===============================================================

_TPWMS_TrailingSuffixCheck() {
	; Move-resilient: scan the hotstrings lib dir via the framework helper instead
	; of a pinned hotstring_prefix_watcher.ahk path. The trailing-suffix form
	; SubStr(Trigger, -MkLen) == MagicKey is unique to the watcher within the dir.
	Src := _TPWMS_StripLineComments(_DriverDirConcat("lib/hotstrings"))
	Assert(Src != "", "lib/hotstrings/hotstring_prefix_watcher.ahk must be readable")

	; MkLen must be computed from StrLen(MagicKey) — needed by the suffix test
	Assert(InStr(Src, "MkLen := StrLen(MagicKey)") > 0,
		"hotstring_prefix_watcher.ahk must compute MkLen := StrLen(MagicKey) for the suffix length")

	; The trailing-suffix form SubStr(Trigger, -MkLen) == MagicKey must be present
	Assert(InStr(Src, "SubStr(Trigger, -MkLen) == MagicKey") > 0,
		"hotstring_prefix_watcher.ahk must check magic suffix with SubStr(Trigger, -MkLen) == MagicKey, not InStr(...) > 0")
}
Test("hotstring_prefix_watcher: magic-key detection uses trailing-suffix check, not InStr", _TPWMS_TrailingSuffixCheck)
