; tests/unit/ui/physical_shortcuts/test_physical_shortcut_delivery.ahk

; ==============================================================================
; MODULE: Physical Shortcut Collisions and Delivery Tests (Windows)
; DESCRIPTION:
; Replays the shared collision corpus through the AutoHotkey policy port, then
; drives the Windows collision owner and the delivery owner over injected
; ports: the other physical slots, the tap keys, the registrar's live
; bindings and the native hotkey probe; the qualification getter, the
; registration and the press admission (physical-collision-owner).
; ==============================================================================

#Requires AutoHotkey v2.0

; The collision owner over explicit sources; every port defaults to empty.
_PSD_Owner(Ports := unset) {
	Ports := IsSet(Ports) ? Ports : Map()
	Full := Map("model", PhysicalSlots.Load(), "assignments", () => Map(), "tap_keys", () => [],
		"registrar", () => [], "probe", (*) => false, "scan_of", (Key) => (Key = "a") ? 0x1E : 0)
	for Name, Port in Ports
		Full[Name] := Port
	return PhysicalShortcutCollisions(Full)
}

; One scope row binding a physical slot.
_PSD_Row(Slot, Action := "copy") {
	return { Section: ConfigKey.SHORTCUTS_KEYBOARD, Key: Slot, Value: Action }
}

Test("physical collisions: the AutoHotkey policy answers every shared vector (physical-conflict-vectors)", () => (
	Corpus := JsonParse(FSReadStrict(_SharedDir . "\tests\corpus\shortcuts\physical_conflict_vectors.json")),
	Assert(Corpus["vectors"].Length >= 10, "the corpus lists its vectors"),
	_PSD_ReplayVectors(Corpus["vectors"])
))

_PSD_ReplayVectors(Vectors) {
	for Vector in Vectors {
		Found := PhysicalConflictsCheck(Vector["request"], Vector["claims"], &Binding)
		Expected := Vector["expect"]
		if (Expected == JSON_NULL)
			AssertEqual("", Found, Vector["name"] . ": refused")
		else
			AssertEqual(Expected ? 1 : 0, Found ? 1 : 0, Vector["name"])
		if (Expected != JSON_NULL) && Expected
			AssertEqual(Vector["binding"], Binding, Vector["name"] . " (binding)")
	}
}

Test("physical collisions: a free key passes and a removal needs no key (physical-collision-owner)", () => (
	AssertEqual(1, _PSD_Owner().Call([_PSD_Row("physical_ctrl_KeyQ")]), "nothing else holds Ctrl+Q's position"),
	AssertEqual("unavailable", _PSD_Owner().Call([_PSD_Row("physical_ctrl_KeyQ", "none")]),
		"a row binding nothing has no key to check")
))

Test("physical collisions: a physical slot never collides with itself (physical-collision-owner)", () => (
	AssertEqual(1, _PSD_Owner(Map("assignments", () => Map("physical_ctrl_KeyQ", "paste")))
		.Call([_PSD_Row("physical_ctrl_KeyQ", "copy")]), "rebinding the same slot is free"),
	AssertEqual(1, _PSD_Owner(Map("assignments", () => Map("physical_alt_KeyQ", "paste")))
		.Call([_PSD_Row("physical_ctrl_KeyQ")]), "another modifier set is another chord")
))

Test("physical collisions: a registered hotkey on that position collides (physical-collision-owner)", () => (
	AssertEqual("collision", _PSD_Owner(Map("registrar", () => [Map("spec", "^SC010", "owner", "keyboard")]))
		.Call([_PSD_Row("physical_ctrl_KeyQ")])),
	AssertEqual("collision", _PSD_Owner(Map("registrar", () => [Map("spec", "^a", "owner", "keyboard")]))
		.Call([_PSD_Row("physical_ctrl_KeyA")]), "a logical chord is resolved to its scan code"),
	AssertEqual(1, _PSD_Owner(Map("registrar", () => [Map("spec", "^WheelUp", "owner", "gestures")]))
		.Call([_PSD_Row("physical_ctrl_KeyA")]), "a mouse hotkey holds no keyboard position"),
	AssertEqual("unavailable", _PSD_Owner(Map("registrar", () => [Map("spec", "^Mystery", "owner", "x")]))
		.Call([_PSD_Row("physical_ctrl_KeyA")]), "an unresolvable hotkey refuses the save"),
	AssertEqual(1, _PSD_Owner(Map("registrar", () => [Map("spec", "^SC010", "owner", "physical_shortcuts:physical_ctrl_KeyQ")]))
		.Call([_PSD_Row("physical_ctrl_KeyQ")]), "the delivery owner's own registration is the slot itself")
))

Test("physical collisions: an assigned tap key owns its plain key only (physical-collision-owner)", () => (
	Owner := _PSD_Owner(Map("tap_keys", () => [Map("code", 0x29, "binding", "tap_key__number_row_left")])),
	AssertEqual("collision", Owner.Call([_PSD_Row("physical_none_Backquote")]), "the plain tap key"),
	AssertEqual("unavailable", Owner.Call([_PSD_Row("physical_ctrl_Backquote")]),
		"a modified press of a tap key stays unproven")
))

Test("physical collisions: an existing AutoHotkey variant on the key collides (physical-collision-owner)", () => (
	Probed := [],
	Owner := _PSD_Owner(Map("probe", (Name) => (Probed.Push(Name), Name == "*SC010"))),
	AssertEqual("collision", Owner.Call([_PSD_Row("physical_ctrl_KeyQ")]), "a wildcard hotkey on Q's position"),
	AssertEqual("^SC010", Probed[1], "the exact variant is probed first")
))

Test("physical delivery: nothing is registered while delivery is unqualified (physical-collision-owner)", () => (
	Bound := [],
	AssertEqual(0, PhysicalShortcutDelivery.BindAll(Map("available", () => false,
		"assignments", () => Map("physical_ctrl_KeyQ", "copy"), "bind", (Chord, Callback, Owner) => (Bound.Push(Chord), "h")))),
	AssertEqual(0, Bound.Length, "no hotkey while the getter answers false"),
	AssertFalse(PhysicalShortcutDeliveryAvailable(), "the production getter still answers false")
))

Test("physical delivery: a qualified slot binds its scan code with its exact modifiers (physical-collision-owner)", () => (
	Bound := [],
	Saved := PhysicalShortcutDelivery.Handles,
	PhysicalShortcutDelivery.Handles := Map(),
	Count := PhysicalShortcutDelivery.BindAll(Map("available", () => true,
		"assignments", () => Map("physical_ctrl_shift_KeyQ", "copy", "physical_none_KeyA", "none", "ctrl_a", "paste"),
		"collisions", (*) => true, "bind", (Chord, Callback, Owner) => (Bound.Push([Chord, Owner]), "h1"))),
	Handles := PhysicalShortcutDelivery.Handles,
	PhysicalShortcutDelivery.Handles := Saved,
	AssertEqual(1, Count, "only the bound physical slot"),
	AssertEqual("ctrl+shift+sc010", Bound[1][1]),
	AssertEqual("physical_shortcuts:physical_ctrl_shift_KeyQ", Bound[1][2]),
	AssertTrue(Handles.Has("^+SC010"), "the owner remembers the hotkey it registered"),
	AssertEqual(0, PhysicalShortcutDelivery.BindAll(Map("available", () => true,
		"assignments", () => Map("physical_ctrl_KeyQ", "copy"), "collisions", (*) => "collision",
		"bind", (*) => "h2")), "a colliding slot is not bound")
))

Test("physical delivery: a press runs only when physical, running and without AltGr (physical-collision-owner)", () => (
	Ran := [],
	RunAction := (Slot) => Ran.Push(Slot),
	AssertTrue(PhysicalShortcutDelivery._Press("physical_ctrl_KeyQ", "^SC010", RunAction,
		Map("suspended", false, "physical", true, "altgr", false))),
	AssertFalse(PhysicalShortcutDelivery._Press("physical_ctrl_KeyQ", "^SC010", RunAction,
		Map("suspended", true, "physical", true, "altgr", false)), "paused"),
	AssertFalse(PhysicalShortcutDelivery._Press("physical_ctrl_KeyQ", "^SC010", RunAction,
		Map("suspended", false, "physical", false, "altgr", false)), "a synthetic press"),
	AssertFalse(PhysicalShortcutDelivery._Press("physical_ctrl_KeyQ", "^SC010", RunAction,
		Map("suspended", false, "physical", true, "altgr", true)), "AltGr held"),
	AssertEqual(1, Ran.Length, "the action ran once")
))
