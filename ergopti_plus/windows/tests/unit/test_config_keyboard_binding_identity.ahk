; tests/unit/test_config_keyboard_binding_identity.ahk

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
