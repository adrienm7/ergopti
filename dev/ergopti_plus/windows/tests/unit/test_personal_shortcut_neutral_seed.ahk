; tests/unit/test_personal_shortcut_neutral_seed.ahk

_PersonalShortcutNeutralSeed(Initialized) {
	global _PersonalShortcutsRegistry, Features, CategoryEnabled
	OldRegistry := IsSet(_PersonalShortcutsRegistry) ? _PersonalShortcutsRegistry : unset
	OldFeatures := Features, OldCategories := CategoryEnabled
	State := MasterGateState(), OldState := State.Clone()
	try {
		_PersonalShortcutsRegistry := Map("__Order", [])
		Features := Map("shortcuts", Map("personal", Map("explicit on", true, "explicit off", false)))
		CategoryEnabled := Map("Shortcuts", true)
		State["initialized"] := Initialized
		State["features"] := _HSDeepCloneMap(Features)
		RegisterPersonalFeature("Absent", true, "neutral fixture")
		AssertEqual(Features["shortcuts"]["personal"]["absent"], ManifestDefaultFor("shortcuts.personal.absent"),
			"registration cannot enable an absent preference through its old default argument")
		RegisterPersonalFeature("explicit on", false)
		RegisterPersonalFeature("explicit off", true)
		AssertEqual(Features["shortcuts"]["personal"]["explicit on"], true)
		AssertEqual(Features["shortcuts"]["personal"]["explicit off"], false)
		if Initialized {
			AssertEqual(State["features"]["shortcuts"]["personal"]["absent"], false)
			AssertEqual(State["features"]["shortcuts"]["personal"]["explicit on"], true)
			AssertEqual(State["features"]["shortcuts"]["personal"]["explicit off"], false)
		}
	} finally {
		_PersonalShortcutsRegistry := IsSet(OldRegistry) ? OldRegistry : unset
		Features := OldFeatures, CategoryEnabled := OldCategories
		State.Clear()
		for Key, Value in OldState
			State[Key] := Value
	}
}
Test("personal-shortcut-neutral: boot ignores implicit enable and preserves explicit choices", _PersonalShortcutNeutralSeed.Bind(false))
Test("personal-shortcut-neutral: live desired state ignores implicit enable and preserves explicit choices", _PersonalShortcutNeutralSeed.Bind(true))
