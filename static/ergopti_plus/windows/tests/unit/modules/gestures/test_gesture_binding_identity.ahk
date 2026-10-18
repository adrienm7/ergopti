; tests/unit/modules/gestures/test_gesture_binding_identity.ahk

; ==============================================================================
; MODULE: Gesture, Script and Tap Binding Identity
; DESCRIPTION:
; Published gesture, script and tap bindings replay their independent
; corpora, stay detached and bound to the compiled declaration, refuse
; malformed publications, and retired parameters refuse both setter paths
; before any port.
; ==============================================================================

#Requires AutoHotkey v2.0





; The native equivalent replays the exact hand-authored corpus used by Lua.
; Default case-insensitive Maps deliberately exercise the helper's exact lookup.
TestGestures_PublishedBindingIdentityCorpus() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\config_binding_identity\vectors.json", "UTF-8"))
	AssertEqual(29, Corpus["vectors"].Length, "frozen independent publication corpus")
	for Vector in Corpus["vectors"] {
		if Vector.Get("expects_error", false) {
			AssertThrows(ConfigBindingIdentityGestureStatus.Bind(Vector["binding"], Vector["catalogue"]), Vector["id"])
			continue
		}
		if Vector.Has("published") && !Vector["published"] {
			Status := ConfigBindingIdentityGestureStatus(Vector["binding"])
		} else {
			Slots := Map()
			for Slot in Vector["slots"]
				Slots[Slot] := true
			Status := ConfigBindingIdentityGestureStatus(Vector["binding"], Map("prefix", Vector["prefix"], "slots", Slots))
		}
		AssertEqual(Vector["status"], Status, Vector["id"])
	}
}
Test("Gestures: published binding identity replays shared 29-vector corpus (gesture-binding-identity-corpus)",
	TestGestures_PublishedBindingIdentityCorpus)

TestGestures_PublishedNativeSlotDomain() {
	Catalogue := TomlConfigGestureSlotCatalogue()
	AssertEqual("gesture__", Catalogue["prefix"])
	AssertEqual(10, Catalogue["slots"].Count, "actual complete Windows catalogue")
	AssertEqual("On", Catalogue["slots"].CaseSense)
	for Slot in GestureSlotIds()
		AssertEqual("current", ConfigBindingIdentityGestureStatus(GestureBindingId("gesture", Slot), Catalogue), Slot)
	AssertEqual("retired", ConfigBindingIdentityGestureStatus("gesture__removed_gesture_slot", Catalogue))
	AssertEqual("retired", ConfigBindingIdentityGestureStatus("gesture__TAP_3", Catalogue))
	AssertEqual("unjudged", ConfigBindingIdentityGestureStatus("Gesture__tap_3", Catalogue))
	for Binding in ["keyboard__ctrl_k", "tap_key__a", "script__pause", "tap_hold__caps_lock", "combination__caps_lock_then_space"]
		AssertEqual("unjudged", ConfigBindingIdentityGestureStatus(Binding, Catalogue), Binding)
}
Test("Gestures: native owner publishes its exact ten-slot domain (gesture-binding-identity-native-catalogue)",
	TestGestures_PublishedNativeSlotDomain)

TestGestures_RetiredParameterSettersRefuseBeforePorts() {
	global GestureActionParameters
	Previous := GestureActionParameters
	Calls := []
	Writer := (*) => (Calls.Push("writer"), false)
	Notify := (*) => Calls.Push("notify")
	try {
		GestureActionParameters := Map()
		GestureActionParameters.CaseSense := "On"
		GestureActionParameters["Gesture__tap_3__open_url"] := "https://unjudged.example"
		AssertFalse(GestureSetActionParameter("gesture__removed_gesture_slot", "open_url", "https://must-not-write.example", Writer, Notify))
		AssertEqual(0, Calls.Length, "ordinary refusal precedes writer and native notification")
		AssertEqual(1, GestureActionParameters.Count)
		AssertEqual("On", GestureActionParameters.CaseSense)
		Assignments := Map("tap_3", "none")
		Parameters := GestureActionParameters.Clone()
		Candidate := Map("has_value", true, "key", "gesture__removed_gesture_slot__open_url", "value", "https://must-not-write.example")
		AssertFalse(_GestureCommitAssignment(&Assignments, &Parameters, "gestures", "tap_3", "open_url", Candidate, Writer, Notify))
		AssertEqual(0, Calls.Length, "combined assignment also refuses before persistence")
		AssertEqual("none", Assignments["tap_3"])
		AssertEqual(1, Parameters.Count)
		AssertEqual("On", Parameters.CaseSense)
	} finally GestureActionParameters := Previous
}
Test("Gestures: proven retired parameters refuse both ordinary setter paths before ports (gesture-binding-identity-refusal)",
	TestGestures_RetiredParameterSettersRefuseBeforePorts)

TestGestures_ParameterSnapshotsKeepCaseTwins() {
	Known := "gesture__tap_3__open_url"
	Twin := "Gesture__tap_3__open_url"
	Source := Map()
	Source.CaseSense := "On"
	Source[Known] := "https://known.example"
	Source[Twin] := "https://unjudged.example"
	Snapshot := _GestureCloneActionParameters(Source)
	AssertEqual("On", Snapshot.CaseSense)
	AssertEqual(2, Snapshot.Count)
	AssertEqual("https://known.example", Snapshot[Known])
	AssertEqual("https://unjudged.example", Snapshot[Twin])
	Revert := Snapshot.Clone()
	AssertEqual("On", Revert.CaseSense, "native Clone preserves the exact compensation domain")
	AssertEqual(2, Revert.Count)
	AssertEqual("https://known.example", Revert[Known])
	AssertEqual("https://unjudged.example", Revert[Twin])
	Legacy := Map()
	Legacy.CaseSense := "Off"
	Legacy[Known] := "https://legacy.example"
	AssertEqual("Off", Legacy.CaseSense, "the fixture supplies a populated case-insensitive legacy Map")
	Upgraded := _GestureCloneActionParameters(Legacy)
	AssertEqual("On", Upgraded.CaseSense)
	AssertEqual("https://legacy.example", Upgraded[Known])
	AssertEqual("Off", Legacy.CaseSense, "populated legacy Map was never switched in place")
}
Test("Gestures: detached snapshots and exact native clones retain both case twins (gesture-binding-identity-snapshots)",
	TestGestures_ParameterSnapshotsKeepCaseTwins)


; Keeps compiled publication identity outside runtime assignment fixtures.
_GSBP_WithPublication(Body) {
	global SCRIPT_SHORTCUT_SLOTS, _ScriptShortcutBindingPublication
	PreviousSlots := IsSet(SCRIPT_SHORTCUT_SLOTS) ? SCRIPT_SHORTCUT_SLOTS : unset
	PreviousPublication := IsSet(_ScriptShortcutBindingPublication) ? _ScriptShortcutBindingPublication : unset
	try {
		SCRIPT_SHORTCUT_SLOTS := ["script_altgr_enter", "script_altgr_backspace", "script_altgr_delete", "script_altgr_escape"]
		_ScriptShortcutBindingPublication := ConfigBindingIdentityScriptPublication(SCRIPT_SHORTCUT_SLOTS)
		Body.Call()
	} finally {
		SCRIPT_SHORTCUT_SLOTS := IsSet(PreviousSlots) ? PreviousSlots : unset
		_ScriptShortcutBindingPublication := IsSet(PreviousPublication) ? PreviousPublication : unset
	}
}

TestGestures_ScriptBindingCorpus() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\config_binding_identity\script_vectors.json", "UTF-8"))
	Catalogue := ConfigBindingIdentityScriptPublication([
		"script_altgr_enter", "script_altgr_backspace", "script_altgr_delete", "script_altgr_escape"
	]).Catalogue
	AssertEqual(14, Corpus.Length, "independent handwritten script identity corpus")
	for Row in Corpus {
		Expected := Type(Row["expected"]) == "String" ? Row["expected"] : Row["expected"] ? "current" : "retired"
		AssertEqual(Expected, ConfigBindingIdentityScriptStatus(Row["binding"], Catalogue), Row["name"])
		AssertEqual("unjudged", ConfigBindingIdentityScriptStatus(Row["binding"]), Row["name"] . ": unpublished")
	}
}
Test("Gestures: script bindings replay an independent fourteen-vector corpus (script-binding-identity)",
	TestGestures_ScriptBindingCorpus)

TestGestures_ScriptPublicationIdentity() {
	_GSBP_WithPublication(_GSBP_PublicationIdentityBody)
}
_GSBP_PublicationIdentityBody() {
	global SCRIPT_SHORTCUT_SLOTS, _ScriptShortcutBindingPublication
	OriginalSlots := SCRIPT_SHORTCUT_SLOTS
	OriginalPublication := _ScriptShortcutBindingPublication
	Received := TomlConfigScriptSlotCatalogue()
	AssertEqual("script__", Received["prefix"])
	AssertEqual(4, Received["slots"].Count)
	AssertEqual("On", Received["slots"].CaseSense)
	Received["slots"].Delete("script_altgr_enter")
	Received["slots"]["removed_script_slot"] := true
	AssertEqual("current", TomlConfigParameterBindingStatus("script__script_altgr_enter"))
	AssertEqual("retired", TomlConfigParameterBindingStatus("script__removed_script_slot"))
	SCRIPT_SHORTCUT_SLOTS := OriginalSlots.Clone()
	AssertEqual("unjudged", TomlConfigParameterBindingStatus("script__removed_script_slot"), "foreign declaration identity withdraws authority")
	SCRIPT_SHORTCUT_SLOTS := OriginalSlots
	SCRIPT_SHORTCUT_SLOTS[1] := "foreign_slot"
	AssertEqual("unjudged", TomlConfigParameterBindingStatus("script__removed_script_slot"), "changed declaration withdraws authority")
	SCRIPT_SHORTCUT_SLOTS[1] := "script_altgr_enter"
	_ScriptShortcutBindingPublication := unset
	AssertEqual("unjudged", TomlConfigParameterBindingStatus("script__removed_script_slot"))
	_ScriptShortcutBindingPublication := OriginalPublication
	AssertEqual("retired", TomlConfigParameterBindingStatus("script__removed_script_slot"))
	for Binding in ["keyboard__removed_key", "tap_key__removed_key", "tap_hold__removed_key", "combination__removed_pair", "Script__removed_script_slot"]
		AssertEqual("unjudged", TomlConfigParameterBindingStatus(Binding), Binding)
}
Test("Gestures: script publication is detached, pure and bound to the compiled declaration (script-binding-identity)",
	TestGestures_ScriptPublicationIdentity)

TestGestures_ScriptPublicationRefusesMalformed() {
	for Ids in [[], [""], ["same", "same"], ["nested__id"], [false]]
		AssertThrows(ConfigBindingIdentityScriptPublication.Bind(Ids), "invalid compiled script declaration refuses")
	Sparse := Array()
	Sparse.Length := 2
	Sparse[1] := "script_altgr_enter"
	AssertThrows(ConfigBindingIdentityScriptPublication.Bind(Sparse), "a sparse declaration is not complete")
	for Catalogue in [Map(), Map("prefix", "script__", "slots", Map()), Map("prefix", "keyboard__", "slots", Map("key", true))]
		AssertThrows(ConfigBindingIdentityScriptStatus.Bind("script__removed", Catalogue), "malformed script publication refuses")
}
Test("Gestures: malformed script publication cannot invent retirement (script-binding-identity)",
	TestGestures_ScriptPublicationRefusesMalformed)

TestGestures_RetiredScriptSettersRefuse() {
	_GSBP_WithPublication(_GSBP_RetiredSettersBody)
}
_GSBP_RetiredSettersBody() {
	global GestureActionParameters
	Previous := GestureActionParameters
	Calls := []
	Writer := (*) => (Calls.Push("writer"), false)
	Notify := (*) => Calls.Push("notify")
	try {
		GestureActionParameters := Map()
		GestureActionParameters.CaseSense := "On"
		GestureActionParameters["Script__removed_script_slot__open_url"] := "https://unjudged.example"
		AssertFalse(GestureSetActionParameter("script__removed_script_slot", "open_url", "https://must-not-write.example", Writer, Notify))
		AssertEqual(0, Calls.Length)
		AssertEqual(1, GestureActionParameters.Count)
		Assignments := Map("script_altgr_enter", "none")
		Parameters := _GestureCloneActionParameters(GestureActionParameters)
		Candidate := Map("has_value", true, "key", "script__removed_script_slot__open_url", "value", "https://must-not-write.example")
		AssertFalse(_GestureCommitAssignment(&Assignments, &Parameters, "shortcuts.script_control", "script_altgr_enter", "open_url", Candidate, Writer, Notify))
		AssertEqual(0, Calls.Length)
		AssertEqual("none", Assignments["script_altgr_enter"])
		AssertEqual("https://unjudged.example", Parameters["Script__removed_script_slot__open_url"])
		Snapshot := _GestureCloneActionParameters(Map("script__removed_script_slot__open_url", "https://inverse.example"))
		AssertEqual("https://inverse.example", Snapshot["script__removed_script_slot__open_url"], "exact inverse is separate from setter admission")
	} finally GestureActionParameters := Previous
}
Test("Gestures: retired script parameter refuses both setter paths before ports (script-binding-identity)",
	TestGestures_RetiredScriptSettersRefuse)

; Uses the two actual compiled declarations, never a fixture's copied slot list.
_GTKP_WithPublication(Body) {
	global TAP_KEY_ORDER, TAP_KEY_SCANCODES, _TapKeyBindingPublication
	PreviousPublication := IsSet(_TapKeyBindingPublication) ? _TapKeyBindingPublication : unset
	try {
		_TapKeyBindingPublication := ConfigBindingIdentityTapPublication(TAP_KEY_ORDER, TAP_KEY_SCANCODES)
		Body.Call()
	} finally _TapKeyBindingPublication := IsSet(PreviousPublication) ? PreviousPublication : unset
}

TestGestures_TapBindingCorpus() {
	global _SharedDir, TAP_KEY_ORDER, TAP_KEY_SCANCODES
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\config_binding_identity\tap_vectors.json", "UTF-8"))
	Catalogue := ConfigBindingIdentityTapPublication(TAP_KEY_ORDER, TAP_KEY_SCANCODES).Catalogue
	AssertEqual(13, Corpus.Length, "independent handwritten tap identity corpus")
	for Row in Corpus {
		Expected := Type(Row["expected"]) == "String" ? Row["expected"] : Row["expected"] ? "current" : "retired"
		AssertEqual(Expected, ConfigBindingIdentityTapStatus(Row["binding"], Catalogue), Row["name"])
		AssertEqual("unjudged", ConfigBindingIdentityTapStatus(Row["binding"]), Row["name"] . ": unpublished")
	}
}
Test("Gestures: tap bindings replay the independent actual-slot corpus (tap-binding-identity)",
	TestGestures_TapBindingCorpus)

TestGestures_TapPublicationIdentity() {
	_GTKP_WithPublication(_GTKP_PublicationIdentityBody)
}
_GTKP_PublicationIdentityBody() {
	global TAP_KEY_ORDER, TAP_KEY_SCANCODES, _TapKeyBindingPublication
	OriginalOrder := TAP_KEY_ORDER
	OriginalScans := TAP_KEY_SCANCODES
	OriginalPublication := _TapKeyBindingPublication
	OriginalScan := TAP_KEY_SCANCODES[TAP_KEY_ORDER[1]]
	try {
		Received := TomlConfigTapSlotCatalogue()
		AssertEqual("tap_key__", Received["prefix"])
		AssertEqual(TAP_KEY_ORDER.Length, Received["slots"].Count)
		AssertEqual("On", Received["slots"].CaseSense)
		Received["slots"].Delete(TAP_KEY_ORDER[1])
		Received["slots"]["removed_tap_key"] := true
		AssertEqual("current", TomlConfigParameterBindingStatus("tap_key__" . TAP_KEY_ORDER[1]))
		AssertEqual("retired", TomlConfigParameterBindingStatus("tap_key__removed_tap_key"))
		TAP_KEY_ORDER := OriginalOrder.Clone()
		AssertEqual("unjudged", TomlConfigParameterBindingStatus("tap_key__removed_tap_key"))
		TAP_KEY_ORDER := OriginalOrder
		TAP_KEY_SCANCODES := OriginalScans.Clone()
		AssertEqual("unjudged", TomlConfigParameterBindingStatus("tap_key__removed_tap_key"))
		TAP_KEY_SCANCODES := OriginalScans
		TAP_KEY_SCANCODES[TAP_KEY_ORDER[1]] := OriginalScan + 1000
		AssertEqual("unjudged", TomlConfigParameterBindingStatus("tap_key__removed_tap_key"))
		TAP_KEY_SCANCODES[TAP_KEY_ORDER[1]] := OriginalScan
		_TapKeyBindingPublication := unset
		AssertEqual("unjudged", TomlConfigParameterBindingStatus("tap_key__removed_tap_key"))
		_TapKeyBindingPublication := OriginalPublication
		AssertEqual("retired", TomlConfigParameterBindingStatus("tap_key__removed_tap_key"))
		AssertEqual("unjudged", TomlConfigParameterBindingStatus("Tap_key__" . TAP_KEY_ORDER[1]))
	} finally {
		TAP_KEY_ORDER := OriginalOrder
		TAP_KEY_SCANCODES := OriginalScans
		TAP_KEY_SCANCODES[TAP_KEY_ORDER[1]] := OriginalScan
		_TapKeyBindingPublication := OriginalPublication
	}
}
Test("Gestures: tap publication binds both actual compiled source identities and scan values (tap-binding-identity)",
	TestGestures_TapPublicationIdentity)

TestGestures_TapPublicationRefusesMalformed() {
	for Ids in [[], [""], ["same", "same"], ["nested__id"], [false]]
		AssertThrows(ConfigBindingIdentityTapPublication.Bind(Ids, Map()), "invalid compiled tap declaration refuses")
	Sparse := Array()
	Sparse.Length := 2
	Sparse[1] := "first"
	AssertThrows(ConfigBindingIdentityTapPublication.Bind(Sparse, Map("first", 1)), "a sparse declaration is not complete")
	for Scans in [Map(), Map("other", 1), Map("first", false), Map("first", "1"), Map("first", -1)]
		AssertThrows(ConfigBindingIdentityTapPublication.Bind(["first"], Scans), "invalid actual scan owner refuses")
	AssertThrows(ConfigBindingIdentityTapPublication.Bind(["first", "second"], Map("first", 1, "second", 1)),
		"two IDs cannot borrow one scan identity")
}
Test("Gestures: malformed tap order and scan publications cannot prove retirement (tap-binding-identity)",
	TestGestures_TapPublicationRefusesMalformed)

TestGestures_TapLatePublicationRead() {
	_GTKP_WithPublication(_GTKP_LatePublicationReadBody)
}
_GTKP_LatePublicationReadBody() {
	global GestureActionParameters, _TapKeyBindingPublication, TAP_KEY_ORDER
	PreviousParameters := GestureActionParameters
	Publication := _TapKeyBindingPublication
	try {
		GestureActionParameters := Map()
		GestureActionParameters.CaseSense := "On"
		Retired := "tap_key__removed_tap_key__open_url"
		Current := "tap_key__" . TAP_KEY_ORDER[1] . "__open_url"
		GestureActionParameters[Retired] := "https://obsolete.example"
		GestureActionParameters[Current] := "https://current.example"
		_TapKeyBindingPublication := unset
		AssertEqual("https://obsolete.example", GestureGetActionParameter("tap_key__removed_tap_key", "open_url"))
		_TapKeyBindingPublication := Publication
		AssertEqual("", GestureGetActionParameter("tap_key__removed_tap_key", "open_url"))
		AssertEqual("https://current.example", GestureGetActionParameter("tap_key__" . TAP_KEY_ORDER[1], "open_url"))
		AssertEqual("https://obsolete.example", GestureActionParameters[Retired], "a read cannot change the exact inverse snapshot")
		_TapKeyBindingPublication := unset
		AssertEqual("https://obsolete.example", GestureGetActionParameter("tap_key__removed_tap_key", "open_url"))
	} finally {
		GestureActionParameters := PreviousParameters
		_TapKeyBindingPublication := Publication
	}
}
Test("Gestures: late tap publication neutralizes reads without destroying exact runtime snapshots (tap-binding-identity)",
	TestGestures_TapLatePublicationRead)

TestGestures_RetiredTapSettersRefuse() {
	_GTKP_WithPublication(_GTKP_RetiredSettersBody)
}
_GTKP_RetiredSettersBody() {
	global GestureActionParameters
	Previous := GestureActionParameters
	Calls := []
	Writer := (*) => (Calls.Push("writer"), false)
	Notify := (*) => Calls.Push("notify")
	try {
		GestureActionParameters := Map()
		GestureActionParameters.CaseSense := "On"
		GestureActionParameters["Tap_key__removed_tap_key__open_url"] := "https://unjudged.example"
		AssertFalse(GestureSetActionParameter("tap_key__removed_tap_key", "open_url", "https://must-not-write.example", Writer, Notify))
		AssertEqual(0, Calls.Length)
		AssertEqual(1, GestureActionParameters.Count)
		Assignments := Map("number_row_left", "none")
		Parameters := _GestureCloneActionParameters(GestureActionParameters)
		Candidate := Map("has_value", true, "key", "tap_key__removed_tap_key__open_url", "value", "https://must-not-write.example")
		AssertFalse(_GestureCommitAssignment(&Assignments, &Parameters, "shortcuts.tap_keys", "number_row_left", "open_url", Candidate, Writer, Notify))
		AssertEqual(0, Calls.Length)
		AssertEqual("none", Assignments["number_row_left"])
		AssertEqual("https://unjudged.example", Parameters["Tap_key__removed_tap_key__open_url"])
		Snapshot := _GestureCloneActionParameters(Map("tap_key__removed_tap_key__open_url", "https://inverse.example"))
		AssertEqual("https://inverse.example", Snapshot["tap_key__removed_tap_key__open_url"], "exact inverse is separate from setter admission")
	} finally GestureActionParameters := Previous
}
Test("Gestures: retired tap parameter refuses both setter paths before ports (tap-binding-identity)",
	TestGestures_RetiredTapSettersRefuse)


TestGestures_ScriptLatePublicationRead() {
	AssertEqual(0, _FeatureStateBootRun("script_late_parameter"),
		"the compiled Script retirement child must complete all native assertions")
}
Test("gestures: late script publication neutralizes retained parameters (script-late-publication)",
	TestGestures_ScriptLatePublicationRead)
