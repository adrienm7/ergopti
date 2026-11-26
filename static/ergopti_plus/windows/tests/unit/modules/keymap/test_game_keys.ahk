; tests/unit/modules/keymap/test_game_keys.ahk

; ==============================================================================
; MODULE: Game Keys Tests (Windows)
; DESCRIPTION:
; « Touches de jeu » (maintainer decision of 2026-11-26). Replays the shared
; vectors macOS and Linux replay (_shared/tests/corpus/layouts/
; game_keys_vectors.json), then drives the held-key primitive through its
; fake injection boundary (_SendHook): an emulated key the system layout
; types goes out down on press, again on each auto-repeat, up on release; a
; character it cannot type keeps the text route. Before the fix every
; emulated key was a {Text} Unicode packet (scan code 0, down and up at
; once), which a scan-code, raw-input or DirectInput game never reads.
; ==============================================================================

#Requires AutoHotkey v2.0

_GKT_Vectors() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\layouts\game_keys_vectors.json", "UTF-8"))
}

; A stable rendering of a string-keyed Map.
_GKT_Render(Value) {
	Keys := []
	for Key in Value
		Keys.Push(Key)
	Sorted := ""
	for Key in Keys
		Sorted .= Key . "`n"
	Sorted := Sort(RTrim(Sorted, "`n"))
	Parts := ""
	for Key in StrSplit(Sorted, "`n")
		if Key != ""
			Parts .= (Parts == "" ? "" : ",") . Key . "=" . Value[Key]
	return Parts
}

; JSON null and an absent field are the same here.
_GKT_Value(Value) => (IsObject(Value) && Value == JSON_NULL) ? "" : Value

_GKT_ReplaysVectors() {
	Vectors := _GKT_Vectors()
	for Vector in Vectors["resolve"] {
		Settings := GameKeys_Resolve(Map("layout", Vector["layout"]))
		AssertEqual(Vector["expected"]["choice"], Settings["choice"], Vector["name"])
		AssertEqual(_GKT_Render(Vector["expected"]["apps"]), _GKT_Render(Settings["apps"]), Vector["name"])
	}
	for Vector in Vectors["choice_for"] {
		Chosen := GameKeys_ChoiceFor(Vector["settings"], Vector["platform"], _GKT_Value(Vector["app"]))
		AssertEqual(Vector["expected"]["choice"], Chosen["choice"], Vector["name"])
		AssertEqual(Vector["expected"]["overridden"] ? true : false, Chosen["overridden"], Vector["name"])
	}
	for Vector in Vectors["apps_with"]
		AssertEqual(_GKT_Render(Vector["expected"]), _GKT_Render(GameKeys_AppsWith(Vector["settings"], Vector["platform"],
			Vector["app"], _GKT_Value(Vector.Get("choice", JSON_NULL)))), Vector["name"])
	for Vector in Vectors["routes"] {
		Name := Vector["platform"] . " " . Vector["mode"] . " " . Vector["choice"]
		Route := GameKeys_Route(Vector["platform"], Vector["mode"], Vector["choice"], Vector["caps"])
		for Field in ["identity", "strategy", "reason_key", "note_key"]
			AssertEqual(_GKT_Value(Vector["expected"][Field]), Route[Field], Name . " " . Field)
		AssertEqual(Vector["expected"]["available"] ? true : false, Route["available"], Name . " available")
	}
	for Vector in Vectors["held"] {
		Step := _GKT_Value(Vector["step"])
		AssertEqual(Vector["expected"] ? true : false,
			GameKeys_HeldAdmissible(Vector["text"], Step == "" ? 0 : Step, Vector["hand"]), Vector["name"])
	}
}
Test("game keys: the settings, routes and held rule replay the shared vectors (game-keys-vectors)", _GKT_ReplaysVectors)

; The fake boundary: every send recorded, the system layout's keystroke and the
; hand's state given, the release hotkeys registered on a recorder.
_GKT_Fixture(Choice, Sent) {
	global _SendHook, Features
	_GameKeys_ResetForTest()
	Registered := []
	GameKeys_RegisterReleases((Name, Callback, Options) => Registered.Push(Name . "|" . Options), (*) => 0)
	_SendHook := (Fn, Keys) => (Sent.Push(Keys), true)
	Features := Map("layout", Map(ConfigLeaf.GAME_KEYS, Choice, ConfigLeaf.GAME_KEYS_APPS, Map()))
	return Map(
		"step", (Text) => Text == "e" ? Map("vk", 0x45, "mods", []) : 0,
		"held", () => Map("shift", false, "altgr", false),
		"app", () => "game.exe",
		"klid", () => "")
}

_GKT_HoldsUntilRelease() {
	global _SendHook, Features
	SavedHook := _SendHook, SavedFeatures := Features
	Sent := []
	try {
		Ports := _GKT_Fixture("letters", Sent)
		AssertTrue(GameKeys_TryHold("SC020", "e", Ports), "the press goes out held")
		AssertEqual("{Blind}{vk45 down}", Sent.Length ? Sent[1] : "", "press: the system layout's key down, no up")
		AssertTrue(GameKeys_TryHold("SC020", "e", Ports), "the auto-repeat of the held key")
		AssertEqual(2, Sent.Length, "a repeat sends another down, never a tap")
		AssertEqual("{Blind}{vk45 down}", Sent[2], "the repeat is a down of the same key")
		AssertTrue(GameKeys_Release("SC020"), "the physical release")
		AssertEqual("{Blind}{vk45 up}", Sent[3], "release: the up of the held key")
		AssertFalse(GameKeys_Release("SC020"), "a second release sends nothing")
		AssertEqual(3, Sent.Length, "each down got exactly one up")
	} finally {
		_SendHook := SavedHook, Features := SavedFeatures
		_GameKeys_ResetForTest()
	}
}
Test("game keys: an emulated key is held from press to release (game-keys-held)", _GKT_HoldsUntilRelease)

_GKT_PhysicalSplit() {
	global _SendHook, Features
	SavedHook := _SendHook, SavedFeatures := Features
	Sent := []
	try {
		Ports := _GKT_Fixture("physical", Sent)
		AssertTrue(GameKeys_TryHold("SC020", "e", Ports), "held at its physical place")
		AssertEqual("{Blind}{vk45sc020 down}", Sent[1], "one event: the physical scan code, the letter's VK")
		GameKeys_Release("SC020")
		AssertEqual("{Blind}{vk45sc020 up}", Sent[2], "its up carries the same identity")
	} finally {
		_SendHook := SavedHook, Features := SavedFeatures
		_GameKeys_ResetForTest()
	}
}
Test("game keys: « physical » sends the split event (game-keys-split-event)", _GKT_PhysicalSplit)

_GKT_TextRoute() {
	global _SendHook, Features
	SavedHook := _SendHook, SavedFeatures := Features
	Sent := []
	try {
		Ports := _GKT_Fixture("letters", Sent)
		AssertFalse(GameKeys_TryHold("SC010", "★", Ports), "the system layout has no key for ★")
		Ports["held"] := () => Map("shift", true)
		AssertFalse(GameKeys_TryHold("SC020", "e", Ports), "Shift held would type another character")
		AssertEqual(0, Sent.Length, "nothing sent: the caller keeps the text route")
		_GameKeys_ResetForTest()
		AssertFalse(GameKeys_TryHold("SC020", "e", Ports), "without its release hotkey no key is held")
	} finally {
		_SendHook := SavedHook, Features := SavedFeatures
		_GameKeys_ResetForTest()
	}
}
Test("game keys: a character the system layout cannot type keeps the text route (game-keys-text-route)", _GKT_TextRoute)

_GKT_ReleaseAll() {
	global _SendHook, Features
	SavedHook := _SendHook, SavedFeatures := Features
	Sent := []
	try {
		Ports := _GKT_Fixture("letters", Sent)
		GameKeys_TryHold("SC020", "e", Ports)
		AssertEqual(1, GameKeys_ReleaseAll(), "a suspend releases the held key")
		AssertEqual("{Blind}{vk45 up}", Sent[2])
	} finally {
		_SendHook := SavedHook, Features := SavedFeatures
		_GameKeys_ResetForTest()
	}
}
Test("game keys: a suspend leaves no key held (game-keys-release-all)", _GKT_ReleaseAll)

_GKT_ReleaseHotkeys() {
	_GameKeys_ResetForTest()
	Names := Map()
	Criteria := 0
	try {
		Count := GameKeys_RegisterReleases((Name, Callback, Options) => Names[Name] := Options,
			(Criterion := 0) => (Criterion ? Criteria += 1 : 0))
		AssertEqual(Names.Count, Count, "every release is counted")
		AssertEqual("I2 S", Names.Get("*SC010 Up", ""), "a letter's release, exempt from Suspend")
		AssertTrue(Names.Has("*SC056 Up"), "the ISO key")
		AssertFalse(Names.Has("*SC01D Up") || Names.Has("*SC02A Up"), "never a modifier")
		AssertEqual(Count, Criteria, "each under its own held-key criterion")
		AssertTrue(!_GameKeys_HeldCriterion("SC010"), "a key held by nobody keeps its own release")
	} finally {
		_GameKeys_ResetForTest()
	}
}
Test("game keys: one Suspend-exempt release hotkey per holdable key (game-keys-release-hotkeys)", _GKT_ReleaseHotkeys)

_GKT_PassThrough() {
	global Features, KLE_Model, KLE_Ergopti
	SavedFeatures := Features, SavedModel := KLE_Model, SavedErgopti := KLE_Ergopti
	_GameKeys_ResetForTest()
	Selected := []
	try {
		GameKeys_RegisterReleases((*) => 0, (*) => 0)
		KLE_Model := Map(), KLE_Ergopti := true
		Features := Map("layout", Map(ConfigLeaf.GAME_KEYS, "physical",
			ConfigLeaf.GAME_KEYS_APPS, Map("game.exe", "physical")))
		Ports := Map("hwnd", () => 0x51A0, "app", () => "game.exe", "klid", () => "A000040C",
			"active", () => "0000040C", "select", (Klid) => (Selected.Push(Klid), true))
		AssertTrue(GameKeys_PassThrough(Ports), "a game keeps its keys at their place on the installed layout")
		AssertEqual("A000040C", Selected.Length ? Selected[1] : "", "its window is switched to Ergopti")
		Ports["hwnd"] := () => 0x51A1, Ports["app"] := () => "notepad.exe"
		AssertFalse(GameKeys_PassThrough(Ports), "another application stays emulated")
		AssertEqual("0000040C", Selected.Length >= 2 ? Selected[2] : "", "the previous layout comes back")
	} finally {
		Features := SavedFeatures, KLE_Model := SavedModel, KLE_Ergopti := SavedErgopti
		_GameKeys_ResetForTest()
	}
}
Test("game keys: « physical » in a game switches to the installed layout and back (game-keys-switch-installed)",
	_GKT_PassThrough)

_GKT_MenuRows() {
	Written := []
	Write := (Path, Value) => (Written.Push([Path, Value]), true)
	Source := Map("layout", Map(ConfigLeaf.GAME_KEYS, "physical", ConfigLeaf.GAME_KEYS_APPS, Map()))
	Rows := _LAY_GameKeysRows(Source, Write, "game.exe", "emulation", "")
	AssertEqual(1, Rows.Length, "one submenu")
	Items := Rows[1]["items"]
	AssertEqual(t("menu.layout.game_keys.physical"), Items[1]["label"], "the global choices first")
	AssertTrue(Items[1]["checked"] && !Items[2]["checked"], "physical is the default")
	AssertEqual(t("platform_reason.game_keys_vk_games_follow_letters"), Items[3]["label"],
		"the checked choice's limit is a greyed row beneath")
	AssertTrue(Items[3]["disabled"])
	Own := Items[4]["items"]
	AssertEqual(3, Own.Length, "the application follows the global choice, or has its own")
	AssertTrue(Own[1]["checked"], "no own choice yet")
	Own[3]["action"].Call()
	AssertEqual(ConfigKey.LAYOUT_GAME_KEYS_APPS, Written[1][1], "an own choice writes the application table")
	AssertEqual("letters", Written[1][2]["game.exe"])
	Items[2]["action"].Call()
	AssertEqual("letters", Written[2][2], "the global choice writes layout.game_keys")
	Installed := _LAY_GameKeysRows(Map("layout", Map(ConfigLeaf.GAME_KEYS, "letters")), Write, "", "installed", "A000040C")
	Letters := Installed[1]["items"][2]
	AssertTrue(Letters["disabled"], "the letters cannot follow over the installed layout")
	AssertEqual("platform_reason.game_keys_letters_needs_base_layout", Letters["disabled_reason_key"])
	AssertEqual(t("menu.layout.game_keys_no_app"), Installed[1]["items"][Installed[1]["items"].Length]["label"],
		"no application typed in yet")
}
Test("game keys: the menu rows choose globally and per application (game-keys-menu)", _GKT_MenuRows)

_GKT_TapHoldsSkipped() {
	global TapHold, _GK_Game
	SavedTapHold := TapHold
	try {
		TapHold := Map("keys", Map("space", Map("tap_action", "space", "hold_modifier", "shift")))
		StoredMap := Map("keys", Map("space", Map("tap_action", "space", "hold_modifier", "shift")))
		_GK_Game["hwnd"] := DllCall("GetForegroundWindow", "Ptr"), _GK_Game["game"] := true
		AssertEqual("", TapHoldHoldModifier(TapHold, "space"), "a game holds no tap-hold modifier")
		AssertEqual("", TapHoldTapAction(TapHold, "space"), "nor runs a tap action")
		AssertEqual("space", TapHoldTapAction(StoredMap, "space"), "the stored tap action stays readable")
		AssertFalse(TapHoldIsActive(TapHold, "space"), "the key is no tap-hold in a game")
		AssertEqual("shift", TapHoldHoldModifier(StoredMap, "space"), "the stored configuration a write reads is kept")
		_GK_Game["game"] := false
		AssertEqual("shift", TapHoldHoldModifier(TapHold, "space"), "another application keeps its tap-holds")
	} finally {
		TapHold := SavedTapHold
		GameKeys_Invalidate()
	}
}
Test("game keys: a game skips every tap-hold delay (game-keys-tap-holds)", _GKT_TapHoldsSkipped)

; The tap-hold #HotIf criteria ask GameKeys_ForegroundIsGame, live before the
; boot has published anything: it decides by the settings GameKeys_Invalidate
; publishes, never by reading the manifest itself, and before that no
; application is a game.
_GKT_ForegroundGameSnapshot() {
	global Features, _GK_Game
	HadFeatures := IsSet(Features)
	SavedFeatures := HadFeatures ? Features : 0
	try {
		_GK_Game := Map("hwnd", -1, "game", false, "settings", 0)
		AssertFalse(GameKeys_ForegroundIsGame(), "unpublished settings make no application a game")
		AssertEqual(-1, _GK_Game["hwnd"], "an unpublished answer is not kept for the window")
		App := GameKeys_ForegroundApp()
		Features := Map("layout", Map(ConfigLeaf.GAME_KEYS, "physical",
			ConfigLeaf.GAME_KEYS_APPS, App == "" ? Map() : Map(App, "letters")))
		GameKeys_Invalidate()
		AssertTrue(_GK_Game["settings"] is Map, "the registration and a choice change publish the settings")
		AssertEqual(App != "", GameKeys_ForegroundIsGame(), "the application in front is a game when it has its own choice")
	} finally {
		Features := HadFeatures ? SavedFeatures : unset
		GameKeys_Invalidate()
	}
}
Test("game keys: the foreground game reads the published settings (game-keys-foreground-snapshot)", _GKT_ForegroundGameSnapshot)
