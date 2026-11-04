; tests/unit/platform/remap/tap_hold/test_tap_hold_overlay_and_modifiers.ahk

; ==============================================================================
; MODULE: Tap-Hold Runtime Overlay and Hold Modifiers
; DESCRIPTION:
; The runtime overlay merges the user file over the defaults,
; ResolveHoldModifierKey is the single source of hold modifiers, and the
; semantic key source keeps its owner.
; ==============================================================================

#Requires AutoHotkey v2.0





_TH_DefaultsTmpPath() => A_ScriptDir . "\test_tap_hold_defaults_tmp.toml"

_TH_WriteDefaults(Content) {
	Path := _TH_DefaultsTmpPath()
	if FileExist(Path)
		FileDelete(Path)
	FileAppend(Content, Path, "UTF-8")
	return Path
}

_TH_CleanDefaults() {
	global _TomlFileCache
	Path := _TH_DefaultsTmpPath()
	if FileExist(Path)
		FileDelete(Path)
	if _TomlFileCache.Has(Path)
		_TomlFileCache.Delete(Path)
}

; A missing user file never imports the shipped recommendation.
_TH_OverlayDefaultsOnlyWhenUserMissing() {
	DefPath := _TH_WriteDefaults(
		"[tap_hold.keys.caps_lock]`r`n"
		. 'tap_action = "escape"' . "`r`n"
		. "time_activation_seconds = 0.35`r`n"
	)
	TH := LoadTapHoldToml(A_ScriptDir . "\does_not_exist_user.toml", DefPath)
	_TH_CleanDefaults()
	AssertEqual(0, TH["keys"].Count)
	AssertFalse(TH.Has("layers"), "tap-hold absence must not create a second navigation owner")
}
Test("LoadTapHoldToml: absent user file never imports a recommendation", _TH_OverlayDefaultsOnlyWhenUserMissing)

; User value takes precedence over the matching default field
_TH_OverlayUserWinsOnConflict() {
	DefPath := _TH_WriteDefaults(
		"[tap_hold.keys.caps_lock]`r`n"
		. 'tap_action = "escape"' . "`r`n"
		. "time_activation_seconds = 0.35`r`n"
	)
	UserPath := _TH_Write(
		"[tap_hold.keys.caps_lock]`r`n"
		. 'tap_action = "enter"' . "`r`n"
	)
	TH := LoadTapHoldToml(UserPath, DefPath)
	_TH_Clean()
	_TH_CleanDefaults()
	; Only explicit records are loaded, including when the preset has parameters.
	AssertEqual("enter", TH["keys"]["caps_lock"]["tap_action"])
	AssertFalse(TH["keys"]["caps_lock"].Has("time_activation_seconds"))
}
Test("LoadTapHoldToml overlay: user value wins on conflict", _TH_OverlayUserWinsOnConflict)

; User file introduces a key absent from defaults — it is preserved as-is
_TH_OverlayUserOnlyKeyPreserved() {
	DefPath := _TH_WriteDefaults(
		"[tap_hold.keys.caps_lock]`r`n"
		. 'tap_action = "escape"' . "`r`n"
	)
	UserPath := _TH_Write(
		"[tap_hold.keys.my_custom_key]`r`n"
		. 'hold_modifier = "shift"' . "`r`n"
	)
	TH := LoadTapHoldToml(UserPath, DefPath)
	_TH_Clean()
	_TH_CleanDefaults()
	AssertFalse(TH["keys"].Has("caps_lock"))
	AssertTrue(TH["keys"].Has("my_custom_key"))
	AssertEqual("shift", TH["keys"]["my_custom_key"]["hold_modifier"])
}
Test("LoadTapHoldToml: user-only key survives without importing a preset", _TH_OverlayUserOnlyKeyPreserved)

; Omitting DefaultsFilePath still works (no regression on existing callers)
_TH_OverlayBackwardCompatNoDefaults() {
	Path := _TH_Write(
		"[tap_hold.keys.tab]`r`n"
		. 'tap_action = "tab"' . "`r`n"
	)
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertEqual("tab", TH["keys"]["tab"]["tap_action"])
}
Test("LoadTapHoldToml overlay: backward-compatible when DefaultsFilePath omitted", _TH_OverlayBackwardCompatNoDefaults)

; inherit_defaults = false opts out of the shipped defaults overlay
_TH_InheritDefaultsFalseSkipsShippedDefaults() {
	DefPath := _TH_WriteDefaults(
		"[tap_hold.keys.caps_lock]`r`n"
		. 'tap_action = "escape"' . "`r`n"
	)
	UserPath := _TH_Write(
		"[tap_hold]`r`n"
		. "inherit_defaults = false`r`n"
	)
	TH := LoadTapHoldToml(UserPath, DefPath)
	_TH_Clean()
	_TH_CleanDefaults()
	AssertEqual(0, TH["keys"].Count)
}
Test("LoadTapHoldToml: inherit_defaults=false skips shipped defaults", _TH_InheritDefaultsFalseSkipsShippedDefaults)





; =========================================================
; =========================================================
; ======= 8/ ResolveHoldModifierKey (single-source) =======
; =========================================================
; =========================================================

_TH_ResolveHoldModifierKeyKnownValuesMap() {
	global _ALTGR_KANA_FIXUP
	PreviousKana := _ALTGR_KANA_FIXUP
	try {
		_ALTGR_KANA_FIXUP := false
		AssertEqual("LCtrl", ResolveHoldModifierKey("ctrl", "backspace"))
		AssertEqual("LShift", ResolveHoldModifierKey("shift", "backspace"))
		AssertEqual("LAlt", ResolveHoldModifierKey("alt", "backspace"))
		AssertEqual("RAlt", ResolveHoldModifierKey("alt_gr", "backspace"))
		AssertEqual("LWin", ResolveHoldModifierKey("win", "backspace"))
	} finally {
		_ALTGR_KANA_FIXUP := PreviousKana
	}
}
Test("ResolveHoldModifierKey: maps every known hold_modifier value", _TH_ResolveHoldModifierKeyKnownValuesMap)

; On a Kana-style layout VK_RMENU has no scan code, so RAlt is a plain Alt and
; the layout's AltGr is the SC138 key. Every alt_gr spelling, alone or in a
; combination, must follow the layout (kana-altgr-hold-2026-09-25).
_TH_ResolveHoldModifierKeyAltGrFollowsLayout() {
	global _ALTGR_KANA_FIXUP
	PreviousKana := _ALTGR_KANA_FIXUP
	try {
		for Kana, Expected in Map(true, "SC138", false, "RAlt") {
			_ALTGR_KANA_FIXUP := Kana
			for Spelling in ["alt_gr", "altgr", "ralt"]
				AssertEqual(Expected, ResolveHoldModifierKey(Spelling, "caps_lock"),
					"hold '" . Spelling . "' with Kana=" . Kana)
			Combo := ResolveHoldModifierKey("ctrl+alt_gr", "caps_lock")
			Assert(Combo is Array && Combo.Length = 2 && Combo[1] == "LCtrl" && Combo[2] == Expected,
				"a ctrl+alt_gr hold must hold LCtrl and the layout's AltGr " . Expected)
		}
	} finally {
		_ALTGR_KANA_FIXUP := PreviousKana
	}
}
Test("ResolveHoldModifierKey: alt_gr resolves to the layout's AltGr key (kana-altgr-hold-2026-09-25)",
	_TH_ResolveHoldModifierKeyAltGrFollowsLayout)

; A generic modifier token resolves to the tap-hold key's OWN side only when the
; key is that very modifier; every other key keeps the left-side default. The
; former positional "CtrlKeyName" override was read by left_shift, right_shift
; and alt_gr as "my own key": left_shift + hold "ctrl" held Shift, right_shift +
; "shift" synthesized LShift instead of passing RShift through, and alt_gr +
; "ctrl" held AltGr (hold-modifier-own-side-2026-09-25).
_TH_ResolveHoldModifierKeyOwnSide() {
	Cases := [
		["ctrl", "left_ctrl", "LCtrl"],
		["ctrl", "right_ctrl", "RCtrl"],
		["lctrl", "right_ctrl", "LCtrl"],
		["shift", "right_ctrl", "LShift"],
		["shift", "left_shift", "LShift"],
		["ctrl", "left_shift", "LCtrl"],
		["shift", "right_shift", "RShift"],
		["lshift", "right_shift", "LShift"],
		["ctrl", "right_shift", "LCtrl"],
		["alt", "left_alt", "LAlt"],
		["win", "win", "LWin"],
		["ctrl", "alt_gr", "LCtrl"],
		["shift", "alt_gr", "LShift"],
	]
	for Row in Cases
		AssertEqual(Row[3], ResolveHoldModifierKey(Row[1], Row[2]),
			"hold '" . Row[1] . "' on tap-hold key '" . Row[2] . "'")
	Combo := ResolveHoldModifierKey("ctrl+shift", "left_shift")
	Assert(Combo is Array && Combo.Length = 2 && Combo[1] == "LCtrl" && Combo[2] == "LShift",
		"a ctrl+shift hold on left_shift must hold both LCtrl and LShift, never LShift twice")
	Combo := ResolveHoldModifierKey("ctrl+shift", "right_shift")
	Assert(Combo is Array && Combo.Length = 2 && Combo[1] == "LCtrl" && Combo[2] == "RShift",
		"a ctrl+shift hold on right_shift must keep its own RShift side")
}
Test("ResolveHoldModifierKey: a token resolves to the key's own side only on that modifier (hold-modifier-own-side-2026-09-25)",
	_TH_ResolveHoldModifierKeyOwnSide)

; The other spellings come from [tap_hold.hold_picker] in the shared defaults,
; which the Linux loader reads too. An alias means its id; a left_ alias names
; the left key even on the right-hand modifier keys. AltGr follows the layout
; on both a standard and a Kana AltGr (hold-alias-single-source).
_TH_ResolveHoldModifierKeyReadsSharedAliases() {
	global _ALTGR_KANA_FIXUP, _SharedDir
	Picker := ParseTomlFile(_SharedDir . "\tap_hold\defaults.toml")["tap_hold.hold_picker"]
	Aliases := Picker["modifier_aliases"]
	LeftAliases := Picker["left_modifier_aliases"]
	Assert(Aliases is Map && Aliases.Count >= 2, "the shared picker must declare modifier_aliases")
	Assert(LeftAliases is Map && LeftAliases.Count >= 4, "the shared picker must declare left_modifier_aliases")
	PreviousKana := _ALTGR_KANA_FIXUP
	try {
		for Kana in [true, false] {
			_ALTGR_KANA_FIXUP := Kana
			for Alias, Id in Aliases {
				for KeyId in ["caps_lock", "right_ctrl"]
					AssertEqual(ResolveHoldModifierKey(Id, KeyId), ResolveHoldModifierKey(StrUpper(Alias), KeyId),
						"'" . Alias . "' on " . KeyId . " with Kana=" . Kana . " holds what '" . Id . "' holds")
			}
			for Alias, Id in LeftAliases {
				for KeyId in ["caps_lock", "right_ctrl", "right_shift"]
					AssertEqual(ResolveHoldModifierKey(Id, "caps_lock"), ResolveHoldModifierKey(Alias, KeyId),
						"'" . Alias . "' on " . KeyId . " with Kana=" . Kana . " holds the left " . Id)
			}
		}
	} finally {
		_ALTGR_KANA_FIXUP := PreviousKana
	}
}
Test("ResolveHoldModifierKey: resolves the aliases of the shared hold picker (hold-alias-single-source)",
	_TH_ResolveHoldModifierKeyReadsSharedAliases)

; The one-shot Shift's results come from _shared/tap_hold/one_shot_shift.json,
; which the Linux driver reads too; they were an if/else chain in
; one_shot_shift.ahk (one-shot-results-shared).
_TH_OneShotResultsComeFromTheSharedTable() {
	global _SharedDir
	Root := JsonParse(FileRead(_SharedDir . "\tap_hold\one_shot_shift.json", "UTF-8"))
	Assert(Root["results"].Length >= 7, "the shared table must declare the one-shot results")
	EndKeys := TapHoldOneShotEndKeys("★")
	for Entry in Root["results"] {
		AssertEqual(Entry["result"], TapHoldOneShotResult(Entry["char"], "★"),
			"the one-shot result of '" . Entry["char"] . "'")
		Assert(InStr(EndKeys, Entry["char"], true) > 0, "'" . Entry["char"] . "' ends the one-shot capture")
	}
	AssertEqual(Root["magic_key_result"], TapHoldOneShotResult("★", "★"), "the magic key's result")
	AssertEqual("", TapHoldOneShotResult("a", "★"), "a letter has no result: it is typed in title case")
	AssertEqual("", TapHoldOneShotResult("", "★"), "a capture that ended on no character has no result")
	Assert(SubStr(EndKeys, -1) == "★", "the magic key ends the one-shot capture")
}
Test("tap-holds: the one-shot Shift results come from the shared table (one-shot-results-shared)",
	_TH_OneShotResultsComeFromTheSharedTable)

; The magic key is the user's choice: it gives its result even on a character
; the shared table has a result for, as the old chain gave it before ",", "'"
; and " ", and as Linux does (one-shot-magic-first). A table the file cannot
; give is logged and kept, so the one-shot capitalises until the next start
; instead of reading the file again at every tap (one-shot-table-once).
_TH_OneShotMagicKeyFirstAndFailureKept() {
	global _SharedDir, _TapHoldOneShotCache
	Root := JsonParse(FileRead(_SharedDir . "\tap_hold\one_shot_shift.json", "UTF-8"))
	for Entry in Root["results"]
		AssertEqual(Root["magic_key_result"], TapHoldOneShotResult(Entry["char"], Entry["char"]),
			"a magic '" . Entry["char"] . "' gives the magic key's result")
	PreviousShared := _SharedDir
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	try {
		_TapHoldOneShotCache := ""
		_SharedDir := A_Temp . "\ergopti_one_shot_no_shared_dir"
		AssertEqual("", TapHoldOneShotResult(" ", "★"), "an unreadable table leaves the one-shot capitalising")
		_SharedDir := PreviousShared
		AssertEqual("", TapHoldOneShotResult(" ", "★"), "the failure is kept, not read again at every tap")
	} finally {
		LoggerClearTestSink()
		_SharedDir := PreviousShared
		_TapHoldOneShotCache := ""
	}
	AssertEqual("-", TapHoldOneShotResult(" ", "★"), "a fresh read gives the table again")
}
Test("tap-holds: the magic key's result comes first and an unreadable table is kept (one-shot-magic-first)",
	_TH_OneShotMagicKeyFirstAndFailureKept)

_TH_ResolveHoldModifierKeyUnknownReturnsEmpty() {
	AssertEqual("", ResolveHoldModifierKey("contrl", "backspace"),
		"an unrecognized hold_modifier (typo) must resolve to empty, never a garbage key name")
}
Test("ResolveHoldModifierKey: unrecognized value returns empty string", _TH_ResolveHoldModifierKeyUnknownReturnsEmpty)

_TH_ResolveHoldModifierKeyUnknownLogsWarning() {
	; Distinct value/field pair from the previous test's "contrl"/"backspace"
	; call — an identical (Tag, Body) within Logger's 5000 ms dedup window
	; would suppress this second emission before it ever reaches the sink.
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	ResolveHoldModifierKey("bogus_mod", "escape")
	LoggerClearTestSink()
	Found := false
	for Line in Captured {
		if (InStr(Line, "[WARNING]") and InStr(Line, "bogus_mod") and InStr(Line, "escape"))
			Found := true
	}
	Assert(Found, "unrecognized hold_modifier must log a WARNING naming both the bad value and the affected tap-holds field so the config typo is easy to locate")
}
Test("ResolveHoldModifierKey: unrecognized value logs a WARNING naming the value and field", _TH_ResolveHoldModifierKeyUnknownLogsWarning)

; A hold_modifier no spelling of the shared hold picker names is refused where
; it is read, as the Linux loader refuses it: an error names it and the key,
; the hold is stored as the picker's "none" and the tap is kept. Every
; hold-modifier hotkey gates on the raw string, so "hyper" armed the hold
; branch with no modifier and swallowed CapsLock, its Enter included, while the
; tap-only branch that types Enter stayed off (unknown-hold-keeps-tap-2026-09-26).
_TH_UnknownHoldModifierKeepsTheTap() {
	global _ALTGR_KANA_FIXUP
	Known :="[tap_hold.keys.alt_gr]`n" . 'hold_modifier = "AltGr"' . "`n"
		. "[tap_hold.keys.space]`n" . 'hold_modifier = "Ctrl + lShift"' . "`n"
	for Source, Unknown in Map("user", "hyper", "defaults", "fn") {
		DefaultsText := "[tap_hold.keys.caps_lock]`n" . 'tap_action = "enter"' . "`n"
			. 'hold_modifier = "' . (Source == "defaults" ? Unknown : "ctrl") . '"' . "`n"
		UserText := Known
		if (Source == "user")
			UserText .= "[tap_hold.keys.caps_lock]`n" . 'tap_action = "enter"' . "`n" . 'hold_modifier = "' . Unknown . '"' . "`n"
		else
			UserText .= DefaultsText
		DefaultsPath := _TH_WriteDefaults(DefaultsText)
		Path := _TH_Write(UserText)
		Captured := []
		LoggerSetTestSink((Line) => Captured.Push(Line))
		try {
			TH := LoadTapHoldToml(Path, DefaultsPath)
		} finally {
			LoggerClearTestSink()
			_TH_Clean()
			_TH_CleanDefaults()
		}
		Entry := TH["keys"]["caps_lock"]
		AssertEqual("", Entry.Get("hold_modifier", ""), Source . ": '" . Unknown . "' must hold nothing")
		AssertEqual("enter", Entry["tap_action"], Source . ": the key must keep its tap")
		; The tap-only gate of capslock.ahk 2.5; 2.3 needs a non-empty hold.
		AssertTrue(Entry["tap_action"] != "" && Entry.Get("hold_modifier", "") == "" && Entry.Get("hold_layer", "") == "",
			Source . ": the tap-only hotkey must own CapsLock")
		Errors := 0
		for _, Line in Captured {
			if (InStr(Line, "[ERROR]") and InStr(Line, "'" . Unknown . "'") and InStr(Line, "caps_lock"))
				Errors++
		}
		AssertEqual(1, Errors, Source . ": one ERROR must name '" . Unknown . "' and the key")
		AssertEqual("AltGr", TH["keys"]["alt_gr"]["hold_modifier"], Source . ": an alias is a known hold")
		AssertEqual("Ctrl + lShift", TH["keys"]["space"]["hold_modifier"], Source . ": so is a spelled-out combination")
		PreviousKana := _ALTGR_KANA_FIXUP
		try {
			for Kana, AltGr in Map(true, "SC138", false, "RAlt") {
				_ALTGR_KANA_FIXUP := Kana
				AssertEqual(AltGr, ResolveHoldModifierKey(TH["keys"]["alt_gr"]["hold_modifier"], "alt_gr"),
					Source . ": the AltGr hold with Kana=" . Kana)
				Combo := ResolveHoldModifierKey(TH["keys"]["space"]["hold_modifier"], "space")
				AssertTrue(Combo is Array && Combo.Length = 2 && Combo[1] == "LCtrl" && Combo[2] == "LShift",
					Source . ": the Ctrl + lShift hold with Kana=" . Kana)
			}
		} finally {
			_ALTGR_KANA_FIXUP := PreviousKana
		}
	}
}
Test("LoadTapHoldToml: an unknown hold_modifier drops the hold and keeps the tap (unknown-hold-keeps-tap-2026-09-26)",
	_TH_UnknownHoldModifierKeepsTheTap)





; ================================================
; ================================================
; ======= 8/ Semantic key source ownership =======
; ================================================
; ================================================

_TH_SemanticAliasRoundtrip() {
	Sources := [
		'tap_hold.keys.caps_lock.tap_action = "escape"`ntap_hold.keys.caps_lock.hold_modifier = "ctrl"`n'
			. 'tap_hold.keys.caps_lock.time_activation_seconds = 0.375`ntap_hold.keys.caps_lock.enabled = true`n',
		'["tap_hold"."keys"."caps_lock"]`n"tap_action" = "escape"`nhold_modifier = "ctrl"`n'
			. 'time_activation_seconds = 0.375`nenabled = true`n',
		'[tap_hold]`nkeys = { caps_lock = { tap_action = "escape", hold_modifier = "ctrl", time_activation_seconds = 0.375, enabled = true } }`n'
	]
	for Source in Sources {
		try {
			Path := _TH_Write(Source)
			Loaded := LoadTapHoldToml(Path)
			AssertEqual("escape", TapHoldTapAction(Loaded, "caps_lock"), "the actual reader owns the admitted semantic key")
			AssertEqual("ctrl", TapHoldHoldModifier(Loaded, "caps_lock"))
			AssertEqual(0.375, TapHoldDuration(Loaded, "caps_lock"), "the runtime receives the published milliseconds after restart")
			AssertTrue(TapHoldIsActive(Loaded, "caps_lock"))
		} finally _TH_Clean()
	}
}
Test("TapHoldLoader: root dotted, quoted and inline sources roundtrip through actual runtime getters (tap-hold-key-delay)",
	_TH_SemanticAliasRoundtrip)

_TH_SemanticFieldTypesStayStrict() {
	Sources := [
		'tap_hold.keys.caps_lock.tap_action = true`ntap_hold.keys.caps_lock.enabled = 1`n'
			. 'tap_hold.keys.tab.tap_action = "alt_tab_monitor"`n',
		'["tap_hold"."keys"."caps_lock"]`ntap_action = escape`nhold_modifier = "ctrl"`n'
			. '[tap_hold.keys.tab]`ntap_action = "alt_tab_monitor"`n',
		'[tap_hold]`nkeys = { caps_lock = { tap_action = escape, hold_modifier = "ctrl" }, tab = { tap_action = "alt_tab_monitor" } }`n'
	]
	for Source in Sources {
		try {
			Path := _TH_Write(Source)
			Loaded := LoadTapHoldToml(Path)
			AssertFalse(TapHoldIsActive(Loaded, "caps_lock"), "typed aliases do not manufacture valid Boolean or quoted string intent")
			AssertEqual("", TapHoldTapAction(Loaded, "caps_lock"))
			AssertTrue(TapHoldIsActive(Loaded, "tab"), "an invalid known field never suppresses a valid sibling")
			AssertEqual("alt_tab_monitor", TapHoldTapAction(Loaded, "tab"))
		} finally _TH_Clean()
	}
}
Test("TapHoldLoader: semantic aliases retain strict Boolean and quoted-string field admission (tap-hold-key-delay)",
	_TH_SemanticFieldTypesStayStrict)

_TH_LiteralDottedNamesDoNotBorrowKnownNamespace() {
	for Source in ['["tap_hold.keys.caps_lock"]`ntap_action = "escape"`n',
		'[tap_hold."keys.caps_lock"]`ntap_action = "escape"`n',
		'"tap_hold.keys.caps_lock.tap_action" = "escape"`n'] {
		try {
			Path := _TH_Write(Source)
			Loaded := LoadTapHoldToml(Path)
			AssertEqual(0, Loaded["keys"].Count, "literal dotted names stay foreign semantic identities")
			AssertFalse(TapHoldIsActive(Loaded, "caps_lock"))
		} finally _TH_Clean()
	}
}
Test("TapHoldLoader: literal dotted foreign keys cannot borrow a native key namespace (tap-hold-key-delay)",
	_TH_LiteralDottedNamesDoNotBorrowKnownNamespace)
