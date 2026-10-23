; tests/unit/infra/config/persistence/test_config_keyboard_binding_identity.ahk

; ==============================================================================
; MODULE: Shared Keyboard Binding Identity Tests
; DESCRIPTION:
; Pure native policy replays handwritten identities without inventing a native
; publication. Complete keyboard source admission remains the native owner task.
; ==============================================================================

#Requires AutoHotkey v2.0

TestConfigKeyboardBindingIdentity_Corpus() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\config_binding_identity\keyboard_vectors.json", "UTF-8"))
	AssertEqual(17, Corpus["vectors"].Length, "independent handwritten keyboard identity vectors")
	Ids := Corpus["ids"]
	Catalogue := ConfigBindingIdentityKeyboardCatalogue(Ids)
	Ids[1] := "changed_after_capture"
	Assert(Catalogue["slots"].Has("ctrl_k"), "detached publication retains the admitted source value")
	Assert(!Catalogue["slots"].Has("changed_after_capture"), "source mutation does not rewrite the detached catalogue")
	for Row in Corpus["vectors"] {
		AssertEqual(Row["expected"], ConfigBindingIdentityKeyboardStatus(Row["binding"], Catalogue), Row["name"])
		AssertEqual("unjudged", ConfigBindingIdentityKeyboardStatus(Row["binding"]), Row["name"] . ": unavailable authority")
	}
	AssertEqual("no keyboard shortcut slot of this build has this name", ConfigBindingIdentityKeyboardRetiredReason())
}

TestConfigKeyboardBindingIdentity_InvalidSources() {
	for Ids in [[], ["ctrl_k", "ctrl_k"], [""], ["nested__id"], [true], Map(1, "ctrl_k")]
		AssertThrows(ConfigBindingIdentityKeyboardCatalogue.Bind(Ids), "invalid native source refuses before publication")
	Sparse := Array()
	Sparse.Length := 2
	Sparse[2] := "ctrl_k"
	AssertThrows(ConfigBindingIdentityKeyboardCatalogue.Bind(Sparse), "sparse native source refuses before publication")
	Catalogue := ConfigBindingIdentityKeyboardCatalogue(["ctrl_k", "Ctrl_k"])
	AssertEqual(2, Catalogue["slots"].Count, "case-distinct admitted source identities remain independent")
}

TestConfigKeyboardBindingIdentity_InvalidCatalogues() {
	for Catalogue in [false, Map(), Map("prefix", "script__", "slots", Map("ctrl_k", true)),
		Map("prefix", "keyboard__", "slots", Map()), Map("prefix", "keyboard__", "slots", Map("ctrl_k", false)),
		Map("prefix", "keyboard__", "slots", Map("", true)), Map("prefix", "keyboard__", "slots", Map("nested__id", true))]
		AssertThrows(ConfigBindingIdentityKeyboardStatus.Bind("keyboard__removed", Catalogue), "malformed explicit authority refuses")
}

Test("Config binding identity: keyboard replays independent exact identities without publishing an owner",
	TestConfigKeyboardBindingIdentity_Corpus)
Test("Config binding identity: keyboard rejects empty sparse duplicate and typed native sources",
	TestConfigKeyboardBindingIdentity_InvalidSources)
Test("Config binding identity: keyboard rejects malformed explicit publication metadata",
	TestConfigKeyboardBindingIdentity_InvalidCatalogues)


class _CKBI_DerivedArray extends Array {
}

_CKBI_RejectCallback(Counter, *) {
	Counter[1] += 1
	throw Error("An invalid keyboard source callback must never execute.")
}

TestConfigKeyboardBindingIdentity_NamedProperties() {
	Named := ["ctrl_k"]
	Named.named := "ctrl_j"
	AssertThrows(ConfigBindingIdentityKeyboardCatalogue.Bind(Named), "named native Array members refuse")
	for PropertyName in ["OwnProps", "Has", "Length", "__Item", "__Enum", "Get"] {
		Counter := [0]
		Ids := ["ctrl_k"]
		Ids.DefineProp(PropertyName, { Get: _CKBI_RejectCallback.Bind(Counter), Call: _CKBI_RejectCallback.Bind(Counter) })
		AssertThrows(ConfigBindingIdentityKeyboardCatalogue.Bind(Ids), PropertyName . ": named callback source refuses")
		AssertEqual(0, Counter[1], PropertyName . ": source rejection must not execute any callback")
		AssertEqual("ctrl_k", Array.Prototype.Get.Call(Ids, 1), PropertyName . ": native indexed source stays intact")
	}
}

TestConfigKeyboardBindingIdentity_DerivedSources() {
	Derived := _CKBI_DerivedArray("ctrl_k")
	AssertThrows(ConfigBindingIdentityKeyboardCatalogue.Bind(Derived), "derived native Array source refuses")
	Counter := [0]
	Prototype := Array()
	Prototype.DefineProp("Has", { Call: _CKBI_RejectCallback.Bind(Counter) })
	Ids := ["ctrl_k"]
	ObjSetBase(Ids, Prototype)
	AssertThrows(ConfigBindingIdentityKeyboardCatalogue.Bind(Ids), "a distinct inherited native Array source refuses")
	AssertEqual(0, Counter[1], "inherited source rejection must not execute its overridden Has")
	AssertEqual("ctrl_k", Array.Prototype.Get.Call(Ids, 1), "rejected inherited source retains its native indexed cell")
}

Test("Config binding identity: keyboard rejects named Array metadata without invoking source callbacks",
	TestConfigKeyboardBindingIdentity_NamedProperties)
Test("Config binding identity: keyboard rejects derived and inherited callback Array sources",
	TestConfigKeyboardBindingIdentity_DerivedSources)





; ================================================
; ================================================
; ======= Native Keyboard Slot Publication =======
; ================================================
; ================================================

; The boot loader, the cleanup and the input owner judged keyboard slots by
; three different rules: the loader by a lowercase grammar, the input owner by
; no rule at all (any persisted slot whose prefix resolved became a live
; hotkey, a case-insensitive « CTRL_K » or a hand-written « ctrl_f1 »
; included, while the cleanup offered to delete it), and the parameter owner
; never judged a keyboard binding, so a parameter of a slot this build lacks
; stayed unread and unoffered forever. One published slot domain now serves
; all three (keyboard-slot-publication).
_CKBI_CurrentSlots() {
	return ["ctrl_k", "ctrl_shift_space", "alt_9", "win_period", "win_sc029", "win_SC03A", "magic_editor"]
}
_CKBI_ForeignSlots() {
	return ["ctrl_f1", "CTRL_K", "ctrl_alt_k", "win_SC0FF", "super_space"]
}

TestConfigKeyboardBindingIdentity_OwnerAndLoaderAgree() {
	global KeyboardShortcutAssignments, KEYBOARD_SHORTCUT_DEFAULTS, _IniCache, KEYBOARD_SLOT_GROUPS
	SavedAssignments := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	SavedDefaults := IsSet(KEYBOARD_SHORTCUT_DEFAULTS) ? KEYBOARD_SHORTCUT_DEFAULTS : unset
	SavedCache := IsSet(_IniCache) ? _IniCache : unset
	try {
		Tree := ManifestBuildFeaturesMap()
		Stored := Map()
		Stored.CaseSense := "On"
		for Slot in _CKBI_CurrentSlots() {
			AssertEqual("", TomlConfigUnknownKind(Tree, "shortcuts.keyboard", Slot), Slot . ": a slot the input owner binds is no unused key")
			Stored[Slot] := "none"
		}
		for Slot in _CKBI_ForeignSlots() {
			AssertEqual("leaf", TomlConfigUnknownKind(Tree, "shortcuts.keyboard", Slot), Slot . ": the loader reports it as unused")
			Stored[Slot] := "none"
		}
		KEYBOARD_SHORTCUT_DEFAULTS := Map()
		KeyboardShortcutAssignments := Map()
		KeyboardShortcutAssignments.CaseSense := "On"
		_IniCache := Map("shortcuts.keyboard", Stored)
		ReadKeyboardShortcutsConfig()
		for Slot in _CKBI_CurrentSlots()
			AssertTrue(KeyboardShortcutAssignments.Has(Slot), Slot . ": the input owner reads its own slot")
		for Slot in _CKBI_ForeignSlots()
			AssertFalse(KeyboardShortcutAssignments.Has(Slot), Slot . ": an unused key never becomes a live hotkey")
		Offered := []
		for Group in KEYBOARD_SLOT_GROUPS {
			if Group["prefix"] != "magic_"
				Offered.Push(Group["prefix"])
		}
		AssertEqual(_CUK_Join(KeyboardSlotDeclaration()["groups"]), _CUK_Join(Offered),
			"the tray's chord groups are exactly the published slot groups")
	} finally {
		KeyboardShortcutAssignments := IsSet(SavedAssignments) ? SavedAssignments : unset
		KEYBOARD_SHORTCUT_DEFAULTS := IsSet(SavedDefaults) ? SavedDefaults : unset
		_IniCache := IsSet(SavedCache) ? SavedCache : unset
	}
}
Test("Config binding identity: the keyboard input owner and the boot loader admit the same slots (keyboard-slot-publication)",
	TestConfigKeyboardBindingIdentity_OwnerAndLoaderAgree)

TestConfigKeyboardBindingIdentity_ParametersFollowThePublication() {
	global GestureActionParameters
	Saved := GestureActionParameters
	try {
		Tree := ManifestBuildFeaturesMap()
		for Slot in _CKBI_CurrentSlots() {
			if Slot == "win_SC03A"
				continue
			Key := GestureBindingId("keyboard", Slot) . "__open_url"
			AssertEqual("current", TomlConfigActionParameterBindingStatus(Key), Slot)
			Owner := ""
			AssertEqual("", TomlConfigUnknownKind(Tree, "action_parameters", Key, &Owner), Slot)
			AssertEqual("Gestures", Owner, Slot)
		}
		Retired := "keyboard__ctrl_f1__open_url"
		AssertEqual("retired", TomlConfigActionParameterBindingStatus(Retired))
		AssertEqual("section", TomlConfigUnknownKind(Tree, "action_parameters", Retired),
			"a retired keyboard parameter is offered for explicit cleanup")
		AssertEqual("unjudged", TomlConfigActionParameterBindingStatus("Keyboard__ctrl_k__open_url"),
			"another prefix spelling is no keyboard binding")
		GestureActionParameters := Map()
		GestureActionParameters.CaseSense := "On"
		GestureActionParameters[Retired] := "https://example.invalid/"
		AssertEqual("", GestureGetActionParameter("keyboard__ctrl_f1", "open_url"), "a retired binding reads neutral")
		Writes := 0
		Writer := (*) => (Writes += 1, true)
		AssertFalse(GestureSetActionParameter("keyboard__ctrl_f1", "open_url", "https://other.invalid/", Writer, (*) => 0))
		AssertEqual(0, Writes, "a retired binding is refused before any write")
		AssertEqual("https://example.invalid/", GestureActionParameters[Retired], "its source value is kept for the cleanup")
	} finally GestureActionParameters := Saved
}
Test("Config binding identity: keyboard parameters are judged against the published slot domain (keyboard-slot-publication)",
	TestConfigKeyboardBindingIdentity_ParametersFollowThePublication)
