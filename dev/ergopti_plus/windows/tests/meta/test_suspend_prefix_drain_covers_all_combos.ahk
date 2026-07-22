; static/ergopti_plus/windows/tests/meta/test_suspend_prefix_drain_covers_all_combos.ahk

; ==============================================================================
; MODULE: Suspend Prefix-Drain Coverage Meta Test
; DESCRIPTION:
; Guard for finding F-30 (audit 2026-07-20 second pass).
;
; SUSPEND_CUSTOM_COMBO_PREFIX_KEYS drives _SuspendPrefixesAreClear, the gate that
; defers a suspend until every custom-combination prefix key is physically
; released. That gate exists because an AHK prefix-down flag LATCHES across
; Suspend and is cleared only by a real physical release processed by the live
; layer — a synthetic {SC138 Up} does NOT clear it, and re-registering the combos
; Off->On re-latches it. So the latch must be prevented at the source.
;
; The list was hand-maintained and held 2 entries while the driver registered 5
; custom-combination prefixes. SC01D (LCtrl), SC02A (LShift) and SC11D (RCtrl)
; were missing, so holding any of them while triggering a suspend — via the tray
; item or an assigned gesture, neither of which requires releasing a modifier —
; latched that prefix and reproduced the « AltGr bloqué » class for that key.
;
; ROOT CAUSE pinned here: the list must cover the CLASS, not the sites someone
; remembered. This test therefore DERIVES the real prefix set from driver source
; and asserts the list covers it, so a newly introduced `X & Y` combination
; fails loudly instead of silently escaping the drain.
; ==============================================================================

#Requires AutoHotkey v2.0

; Scans driver source for both spellings of a custom-combination registration:
;   - a static hotkey label   `SC01D & ~SC138::`
;   - a dynamic registration  `Hotkey("SC138 & " . SC, ...)`
; Returns a Map of prefix key -> true.
_SPDC_CollectCombinationPrefixes() {
	Found := Map()
	Mods := "SC[0-9A-Fa-f]+|RAlt|LAlt|RCtrl|LCtrl|RShift|LShift|RWin|LWin"
	for Line in StrSplit(_DriverSourceNoComments(), "`n", "`r") {
		; Static label form: optional leading whitespace, prefix, &, suffix, ::
		if RegExMatch(Line, "^\s*(" . Mods . ")\s*&\s*[^:]+::", &M)
			Found[M[1]] := true
		; Dynamic form inside a Hotkey() call. Single-quoted AHK string so the
		; literal double quote of the AHK source being scanned needs no escape.
		if RegExMatch(Line, 'Hotkey\(\s*"(' . Mods . ')\s*&', &M2)
			Found[M2[1]] := true
	}
	return Found
}

; Reads the declared drain list straight from source. lib/lifecycle.ahk is not
; loaded by the headless harness, so the super-global is not available at runtime
; — and parsing the declaration is the stronger check anyway: it pins what the
; driver ships, not what a test fixture happens to hold.
_SPDC_DeclaredDrainList() {
	Src := _DriverSourceNoComments()
	Assert(RegExMatch(Src, "SUSPEND_CUSTOM_COMBO_PREFIX_KEYS\s*:=\s*\[([^\]]*)\]", &M) > 0,
		"SUSPEND_CUSTOM_COMBO_PREFIX_KEYS must be declared as an array literal in lib/lifecycle.ahk")
	Out := []
	for _, Raw in StrSplit(M[1], ",") {
		; Trim in stages so neither quote character needs an escape: a
		; single-quoted AHK string holds the double quote and vice versa.
		Key := Trim(Raw, " `t`r`n")
		Key := Trim(Key, '"')
		Key := Trim(Key, "'")
		if (Key != "")
			Out.Push(Key)
	}
	return Out
}

_SPDC_DrainListCoversEveryCombinationPrefix() {
	Found := _SPDC_CollectCombinationPrefixes()
	Declared := _SPDC_DeclaredDrainList()
	Assert(Declared.Length > 0, "prerequisite: the drain list must not be empty")
	Assert(Found.Count > 0,
		"prerequisite: the scanner must find at least one custom-combination prefix in driver source — if this fails the regex has drifted, not the driver")

	; The SC138 AltGr/Kana prefix is the canonical one the whole mechanism was
	; built for; if the scanner misses it the scan itself is broken.
	Assert(Found.Has("SC138"),
		"prerequisite: SC138 (AltGr/Kana) must be detected as a combination prefix — it is the key the drain mechanism was originally built for")

	for Prefix in Found {
		InList := false
		for _, Known in Declared {
			if (Known = Prefix) {
				InList := true
				break
			}
		}
		Assert(InList,
			"custom-combination prefix '" . Prefix . "' is registered in the driver but absent from SUSPEND_CUSTOM_COMBO_PREFIX_KEYS — its AHK prefix-down flag latches across Suspend and cannot be cleared by synthetic key events, so holding it while pausing reproduces the « AltGr bloqué » latch for that key. Add it to the list in lib/lifecycle.ahk")
	}
}
Test("lifecycle: the suspend prefix drain covers every custom-combination prefix (F-30)",
	_SPDC_DrainListCoversEveryCombinationPrefix)
