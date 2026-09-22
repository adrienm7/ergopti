; tests/unit/test_global_disable_all_preserves_assignments.ahk

; ==============================================================================
; MODULE: Global Disable All Preserves Assignments
; DESCRIPTION:
; Regression guard for global-disable-all-clears-bindings. « Tout désactiver »
; must behave like a pause: every feature switch goes off (and « Tout activer »
; switches them back on), while per-key assignments and settings stay intact.
;
; ROOT CAUSE ENCODED: ToggleAllFeatures(0) called a binding clear that wrote
; "none" into every gesture, keyboard and SCRIPT-CONTROL slot — killing the
; pause shortcut itself, and « Tout activer » could never bring the bindings
; back — while its flip walker forced EVERY non-table leaf to a boolean, turning
; hotstrings.trigger_char, magic_key_source_char, script.locale and friends into
; true/false. The walker now flips only the "enabled" flag of a feature table,
; category gates, and leaves the manifest declares boolean (never the exclusive
; AltGr/LAlt chord groups, which are per-key assignments).
;
; The tree is the real one (ManifestBuildFeaturesMap), so a new manifest key of
; any type is covered without editing this file.
; ==============================================================================

#Requires AutoHotkey v2.0

_GDAP_RunFlip(Bool, Tree) {
	Updates := []
	for TopKey, TopVal in Tree {
		if (Type(TopVal) == "Map")
			_CollectFeatureFlipUpdates(Bool, TopKey, TopVal, Updates)
	}
	return Updates
}

; Resolves a dotted section in a Features tree, or returns false.
_GDAP_Node(Tree, SectionPath) {
	Node := Tree
	for _, Part in StrSplit(SectionPath, ".") {
		if !(Node is Map) || !Node.Has(Part)
			return false
		Node := Node[Part]
	}
	return Node
}

_GDAP_IsPerKeySection(SectionPath) {
	global _FEATURE_MUTEX_GROUPS
	if (SectionPath == "shortcuts.keyboard" || SectionPath == "shortcuts.script_control")
		return true
	Parts := StrSplit(SectionPath, ".")
	return Parts.Length == 2 && Parts[1] == "shortcuts" && _FEATURE_MUTEX_GROUPS.Has(Parts[2])
}

_GDAP_OnlyBooleanSwitchesAreWritten() {
	Assert(ManifestEnsureLoaded(), "the features manifest must be loaded")
	for _, Bool in [false, true] {
		Tree := ManifestBuildFeaturesMap()
		Updates := _GDAP_RunFlip(Bool, Tree)
		Assert(Updates.Length > 20, "the bulk toggle must still switch the features")
		for _, U in Updates {
			Where := U.Section . "." . U.Key
			AssertFalse(_GDAP_IsPerKeySection(U.Section),
				"the bulk toggle must never rewrite a per-key assignment: " . Where)
			Entry := ManifestFindEntryByPath(Where)
			if (U.Key == "enabled") {
				Owner := _GDAP_Node(ManifestBuildFeaturesMap(), U.Section)
				Assert((Entry is Map && Entry["type"] == "boolean") || (Owner is Map),
					"an enabled write must target a feature switch: " . Where)
			} else {
				Assert(Entry is Map, "a flipped leaf must be a declared feature: " . Where)
				AssertEqual("boolean", Entry["type"],
					"a non-boolean leaf must never be switched to a boolean: " . Where)
			}
		}
	}
}

_GDAP_SettingsAndAssignmentsSurvive() {
	Assert(ManifestEnsureLoaded(), "the features manifest must be loaded")
	Pristine := ManifestBuildFeaturesMap()
	Tree := ManifestBuildFeaturesMap()
	_GDAP_RunFlip(false, Tree)
	for _, Path in ["hotstrings.trigger_char", "hotstrings.magic_key_source_char",
			"hotstrings.magic_key_source_scan", "script.locale", "script.log_level",
			"script.alt_gr_is_kana_remap", "shortcuts.chatgpt_url",
			"shortcuts.a_grave.letter"] {
		Dot := InStr(Path, ".", , -1)
		Section := SubStr(Path, 1, Dot - 1)
		Key := SubStr(Path, Dot + 1)
		AssertEqual(_GDAP_Node(Pristine, Section)[Key], _GDAP_Node(Tree, Section)[Key],
			"Tout désactiver must keep the setting " . Path)
	}
	for _, Section in ["shortcuts.keyboard", "shortcuts.script_control",
			"shortcuts.alt_gr_caps_lock", "shortcuts.alt_gr_lalt", "shortcuts.lalt_caps_lock"] {
		Before := _GDAP_Node(Pristine, Section)
		After := _GDAP_Node(Tree, Section)
		Assert(Before is Map && Before.Count > 0, "the manifest must declare " . Section)
		for Slot, Value in Before
			AssertEqual(Value, After[Slot],
				"Tout désactiver must keep the assignment " . Section . "." . Slot)
	}
	for Slot, Value in Pristine["gestures"] {
		if (Slot != "enabled")
			AssertEqual(Value, Tree["gestures"][Slot],
				"Tout désactiver must keep the gesture slot " . Slot)
	}
}

_GDAP_SwitchesFlipAndRestore() {
	Assert(ManifestEnsureLoaded(), "the features manifest must be loaded")
	Tree := ManifestBuildFeaturesMap()
	_GDAP_RunFlip(false, Tree)
	for _, Path in ["gestures.enabled", "llm.enabled", "metrics.enabled",
			"shortcuts.a_grave.enabled", "shortcuts.microsoft_bold",
			"layout.ergopti_base", "hotstrings.repeat_key_enabled"] {
		Dot := InStr(Path, ".", , -1)
		AssertEqual(false, _GDAP_Node(Tree, SubStr(Path, 1, Dot - 1))[SubStr(Path, Dot + 1)],
			"Tout désactiver must switch off " . Path)
	}
	for Gate, Value in Tree["category_enabled"]
		AssertEqual(false, Value, "Tout désactiver must close the category gate " . Gate)
	_GDAP_RunFlip(true, Tree)
	for _, Path in ["gestures.enabled", "llm.enabled", "metrics.enabled",
			"shortcuts.a_grave.enabled", "layout.ergopti_base"] {
		Dot := InStr(Path, ".", , -1)
		AssertEqual(true, _GDAP_Node(Tree, SubStr(Path, 1, Dot - 1))[SubStr(Path, Dot + 1)],
			"Tout activer must switch back on " . Path)
	}
	for Gate, Value in Tree["category_enabled"]
		AssertEqual(true, Value, "Tout activer must reopen the category gate " . Gate)
	AssertEqual("★", Tree["hotstrings"]["trigger_char"],
		"a disable/enable round trip must leave the trigger character intact")
}

; The in-memory assignment Maps and their TOML sections must not be touched by
; the bulk toggle at all: it used to clear them to "none" on every disable.
_GDAP_ToggleAllNeverClearsBindings() {
	Body := _StripFullLineComments(_DriverFuncBody("ToggleAllFeatures"))
	Assert(Body != "", "ToggleAllFeatures must be readable")
	AssertEqual(0, InStr(Body, '"none"'), "the bulk toggle must never write a none binding")
	for _, Name in ["GestureAssignments", "KeyboardShortcutAssignments", "ScriptShortcutAssignments",
			"shortcuts.keyboard", "shortcuts.script_control"]
		AssertEqual(0, InStr(Body, Name), "the bulk toggle must leave " . Name . " alone")
}

Test("global actions: disable all writes only boolean feature switches (global-disable-all-clears-bindings)",
	_GDAP_OnlyBooleanSwitchesAreWritten)
Test("global actions: disable all keeps settings and per-key assignments (global-disable-all-clears-bindings)",
	_GDAP_SettingsAndAssignmentsSurvive)
Test("global actions: disable all switches features off and enable all restores them (global-disable-all-clears-bindings)",
	_GDAP_SwitchesFlipAndRestore)
Test("global actions: the bulk toggle never clears a binding (global-disable-all-clears-bindings)",
	_GDAP_ToggleAllNeverClearsBindings)
