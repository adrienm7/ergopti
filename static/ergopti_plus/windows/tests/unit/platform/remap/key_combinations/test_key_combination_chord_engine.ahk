; tests/unit/platform/remap/key_combinations/test_key_combination_chord_engine.ahk

; ==============================================================================
; MODULE: Key Combination Chord Engine (Windows)
; DESCRIPTION:
; What a press does when a chord is assigned: it waits for its second key, runs
; the action on a match within the delay, and otherwise comes back as the key it
; is, before anything typed after it. Driven through the real engine and real
; policy on a clock and physical keys of its own, in the order AutoHotkey runs the
; threads. Plain typing, the AltGr families and a terminal replay are pinned too.
; ==============================================================================

#Requires AutoHotkey v2.0

; Runs Body on an isolated engine with the chords given, and a recorder.
_KCCE_With(Chords, Symmetric, Body) {
	global KeyCombinationChords, KeyCombinationChordConfig, _KeyCombinationChordPolicy, _KeyCombinationChordFirsts
	global _KeyCombinationChordWaiting, _KeyCombinationChordTaken, _KeyCombinationChordQueue, _KeyCombinationChordBusy
	global CategoryEnabled, _KeyCombinationScanNames, _KeyCombinationKeysByScanName, _KeyCombinationTaken, _KeyCombinationHandled
	global _KeyCombinationPressAssignments, KeyCombinationTaps, KeyCombinationHolds, _KeyCombinationFirstKeys, LayerEnabled
	Saved := [KeyCombinationChords, KeyCombinationChordConfig, _KeyCombinationChordPolicy, _KeyCombinationChordFirsts,
		CategoryEnabled, LayerEnabled]
	World := { Now: 1000, Held: Map(), Sends: [], Actions: [], Polls: [], Drains: 0, Log: [] }
	Ports := Map(
		"tick", () => World.Now,
		"is_held", (Key) => World.Held.Has(Key),
		"send", (Keys) => (World.Sends.Push(Keys), World.Log.Push("send " . Keys)),
		"run_action", (First, Second, Action) => (World.Actions.Push(First . "+" . Second . "=" . Action), World.Log.Push("action " . Action)),
		"arm_poll", (Armed) => World.Polls.Push(Armed),
		"arm_drain", () => World.Drains += 1)
	Cache := Map()
	for Pair, Action in Chords
		Cache["mod_combos.config." . Pair] := Map("combo", Action)
	Cache["mod_combos"] := Map("simultaneous_threshold_ms", 100, "symmetric", Symmetric)
	CategoryEnabled := Map("KeyCombinations", true)
	LayerEnabled := false
	_KeyCombinationChordWaiting := "", _KeyCombinationChordTaken := Map()
	_KeyCombinationChordQueue := [], _KeyCombinationChordBusy := false
	Scans := Map(), Keys := Map()
	for _, Id in KeyCombinationKeyIds() {
		Scans[Id] := Format("SC{:03X}", _TapHoldScanCodeOf(Id))
		Keys[Scans[Id]] := Id
	}
	SavedScans := _KeyCombinationScanNames, SavedKeys := _KeyCombinationKeysByScanName
	_KeyCombinationScanNames := Scans, _KeyCombinationKeysByScanName := Keys
	try {
		KeyCombinationChordsReadConfig(Cache)
		Body.Call(World, Ports)
	} finally {
		KeyCombinationChords := Saved[1], KeyCombinationChordConfig := Saved[2]
		_KeyCombinationChordPolicy := Saved[3], _KeyCombinationChordFirsts := Saved[4]
		CategoryEnabled := Saved[5], LayerEnabled := Saved[6]
		_KeyCombinationChordWaiting := "", _KeyCombinationChordTaken := Map()
		_KeyCombinationChordQueue := [], _KeyCombinationChordBusy := false
		_KeyCombinationScanNames := SavedScans, _KeyCombinationKeysByScanName := SavedKeys
	}
}

; AutoHotkey runs the criterion before recording the key as held.
_KCCE_Press(World, Ports, Key) {
	Result := KeyCombinationChordOwns(Key, Ports) ? KeyCombinationChordHandle(Key, Ports) : ""
	World.Held[Key] := true
	return Result
}

; The three writers of the chords, driven on a file of their own: a held lease makes
; each one report false with no reload; once free, each persists and reloads once.
_KCCE_ChordWritersFollowTheirCommit() {
	_KCCE_With(Map(), false, _KCCE_ChordWritersBody)
}
_KCCE_ChordWritersBody(World, Ports) {
	Path := A_Temp . "\ergopti_kcce_chord_writers_" . DllCall("GetCurrentProcessId", "UInt") . ".toml"
	if FileExist(Path)
		FileDelete(Path)
	FileAppend("", Path, "UTF-8-RAW")
	Reloads := 0
	Reload := () => (Reloads += 1, "reloaded")
	Writers := Map(
		"combo", () => SetKeyCombinationChord("caps_lock_then_tab", "copy", Path, Reload),
		"symmetric", () => KeyCombinationChordToggleSymmetric(Path, Reload),
		"simultaneous_threshold_ms", () => KeyCombinationChordCommitDelay("150", Path, Reload))
	try {
		Owner := _ConfigWriteLeaseTryAcquire(Path, "chord-writer-refusal")
		AssertTrue(Owner is Object, "the test holds the write lease")
		try {
			for Needle, Writer in Writers
				AssertEqual(false, Writer.Call(), Needle . ": a refused commit reports false")
		} finally _ConfigWriteLeaseRelease(Owner)
		AssertEqual(0, Reloads, "a refused commit never reloads")
		AssertEqual("", FileRead(Path, "UTF-8"), "a refused commit writes nothing")
		AssertEqual(false, KeyCombinationChordCommitDelay("soon", Path, Reload), "a delay that is no number changes nothing")
		AssertEqual(0, Reloads, "a refused delay never reloads")
		for Needle, Writer in Writers {
			Before := Reloads
			AssertEqual("reloaded", Writer.Call(), Needle . ": a commit answers with its reload")
			AssertEqual(Before + 1, Reloads, Needle . ": a commit reloads once")
			Assert(InStr(FileRead(Path, "UTF-8"), Needle), Needle . " reaches the file")
		}
	} finally FileDelete(Path)
}
Test("key combination chords: the writers report a refused commit and never reload behind it",
	_KCCE_ChordWritersFollowTheirCommit)

_KCCE_ChordFiresInsideTheDelay() {
	_KCCE_With(Map("caps_lock_then_tab", "copy"), false, _KCCE_ChordFiresBody)
}
_KCCE_ChordFiresBody(World, Ports) {
	AssertEqual("wait", _KCCE_Press(World, Ports, "caps_lock"), "the first key waits")
	AssertEqual(0, World.Sends.Length, "nothing reaches the system while it waits")
	World.Now += 100
	AssertEqual("chord", _KCCE_Press(World, Ports, "tab"), "inside the delay, its boundary included")
	AssertEqual("caps_lock+tab=copy", World.Actions[1], "the action runs once")
	AssertEqual(0, World.Sends.Length, "neither key is sent")
	AssertEqual(false, TapHoldRollUndecided(), "typing is free again")
	AssertEqual("swallowed", KeyCombinationChordHandle("tab", Ports), "its auto-repeat is consumed")
	World.Held.Delete("tab"), World.Held.Delete("caps_lock")
	KeyCombinationChordTick(Ports)
	AssertEqual(false, KeyCombinationChordOwns("tab", Ports), "the release ends what the chord took")
	AssertEqual(false, World.Polls[World.Polls.Length], "the look stops with nothing left to watch")
}
Test("key chord engine: two keys inside the delay run the action and send nothing (item2-chord)",
	_KCCE_ChordFiresInsideTheDelay)

_KCCE_DelayPassesTheKeyIsItself() {
	_KCCE_With(Map("caps_lock_then_tab", "copy"), false, _KCCE_DelayBody)
}
_KCCE_DelayBody(World, Ports) {
	_KCCE_Press(World, Ports, "caps_lock")
	World.Now += 100
	KeyCombinationChordTick(Ports)
	AssertEqual(0, World.Sends.Length, "the delay is inclusive")
	World.Now += 1
	KeyCombinationChordTick(Ports)
	AssertEqual("{Blind}{SC03A down}", World.Sends[1], "held past the delay: a press, its physical release follows")
	AssertEqual(false, TapHoldRollUndecided(), "no longer busy")
	AssertEqual("", KeyCombinationChordHandle("caps_lock", Ports) == "swallowed" ? "x" : "",
		"its repeats are its own again")
}
Test("key chord engine: the delay passing gives the key back as a press (item2-delay)",
	_KCCE_DelayPassesTheKeyIsItself)

_KCCE_ReleaseInTheWaitIsATap() {
	_KCCE_With(Map("caps_lock_then_tab", "copy"), false, _KCCE_ReleaseBody)
}
_KCCE_ReleaseBody(World, Ports) {
	_KCCE_Press(World, Ports, "caps_lock")
	World.Held.Delete("caps_lock")
	World.Now += 5
	KeyCombinationChordTick(Ports)
	AssertEqual("{Blind}{SC03A}", World.Sends[1], "up already: press and release, at once")
}
Test("key chord engine: a release during the wait gives the key back at once (item2-tap)",
	_KCCE_ReleaseInTheWaitIsATap)

; The Space roll of plain typing: a chord on Space must not swap its letters.
_KCCE_TypingKeepsItsOrder() {
	_KCCE_With(Map("space_then_tab", "copy"), false, _KCCE_TypingBody)
}
_KCCE_TypingBody(World, Ports) {
	AssertEqual("wait", _KCCE_Press(World, Ports, "space"))
	AssertEqual(true, TapHoldRollUndecided(), "the roll block now takes the characters")
	KeyCombinationChordInterrupt(0x010, Ports)
	AssertEqual("{Blind}{SC039 down}", World.Sends[1], "Space goes first")
	AssertEqual(1, World.Sends.Length, "the letter waits for Space's own thread to have run")
	AssertEqual(true, TapHoldRollUndecided(), "a further letter still queues behind it")
	KeyCombinationChordInterrupt(0x011, Ports)
	AssertEqual(2, World.Drains, "each letter asks for the drain")
	KeyCombinationChordDrain(Ports)
	AssertEqual("{Blind}{SC010}", World.Sends[2], "the letters follow in their order")
	AssertEqual("{Blind}{SC011}", World.Sends[3])
	AssertEqual(false, TapHoldRollUndecided(), "nothing is left")
	AssertEqual(0, World.Actions.Length, "no chord ran")
}
Test("key chord engine: characters struck during the wait follow the key, in order (item2-roll)",
	_KCCE_TypingKeepsItsOrder)

_KCCE_OtherCatalogueKeyEndsTheWait() {
	_KCCE_With(Map("caps_lock_then_tab", "copy"), false, _KCCE_OtherBody)
}
_KCCE_OtherBody(World, Ports) {
	_KCCE_Press(World, Ports, "caps_lock")
	AssertEqual("queued", _KCCE_Press(World, Ports, "enter"), "no chord for this pair")
	AssertEqual("{Blind}{SC03A down}", World.Sends[1], "the first key goes first")
	KeyCombinationChordDrain(Ports)
	AssertEqual("{Blind}{SC01C down}", World.Sends[2], "then the other key, as itself")
	AssertEqual(0, World.Actions.Length)
}
Test("key chord engine: another key gives both back in their order (item2-other-key)",
	_KCCE_OtherCatalogueKeyEndsTheWait)

_KCCE_ReverseOrderFollowsSymmetry() {
	_KCCE_With(Map("caps_lock_then_tab", "copy"), false, _KCCE_NotSymmetricBody)
	; Tab comes first in the catalogue: under symmetry its order owns the slot.
	_KCCE_With(Map("tab_then_caps_lock", "copy"), true, _KCCE_SymmetricBody)
}
_KCCE_NotSymmetricBody(World, Ports) {
	AssertEqual("", _KCCE_Press(World, Ports, "tab"), "this order begins no chord: Tab does not even wait")
}
_KCCE_SymmetricBody(World, Ports) {
	AssertEqual("wait", _KCCE_Press(World, Ports, "caps_lock"), "symmetric: both orders begin it")
	AssertEqual("chord", _KCCE_Press(World, Ports, "tab"))
	AssertEqual("tab+caps_lock=copy", World.Actions[1], "the canonical pair's binding and action")
	AssertEqual("tab_then_caps_lock", KeyCombinationChordOwnerPair("caps_lock_then_tab"), "the menu edits the same slot")
}
Test("key chord engine: the reverse order follows the symmetry setting (item2-symmetry)",
	_KCCE_ReverseOrderFollowsSymmetry)

_KCCE_NoChordChangesNothing() {
	_KCCE_With(Map(), false, _KCCE_NoChordBody)
}
_KCCE_NoChordBody(World, Ports) {
	AssertEqual(false, KeyCombinationChordOwns("space", Ports), "with no chord no key waits")
	AssertEqual("", KeyCombinationChordHandle("space", Ports))
	AssertEqual(false, TapHoldRollUndecided(), "plain typing keeps its one read false")
	AssertEqual(0, World.Polls.Length, "no timer is armed")
}
Test("key chord engine: with no chord assigned nothing waits (item2-plain-typing)",
	_KCCE_NoChordChangesNothing)

; A second press of a key already held is its auto-repeat, and another held key means
; the press is no first key: a key a hold owns never starts a wait.
_KCCE_NoWaitUnderAHeldKey() {
	_KCCE_With(Map("caps_lock_then_tab", "copy"), false, _KCCE_HeldBody)
}
_KCCE_HeldBody(World, Ports) {
	World.Held["left_alt"] := true
	AssertEqual(false, KeyCombinationChordOwns("caps_lock", Ports), "another key held: not a first key")
	World.Held.Delete("left_alt")
	World.Held["caps_lock"] := true
	AssertEqual(false, KeyCombinationChordOwns("caps_lock", Ports), "its own auto-repeat begins nothing")
}
Test("key chord engine: a key held or repeating never begins a wait (item2-held)", _KCCE_NoWaitUnderAHeldKey)

; AltGr on both families: it is no chord member, and it passes the wait untouched.
_KCCE_AltGrStaysOut() {
	for _, Kana in [false, true] {
		Family := _TestSetAltGrFamily(Kana)
		try _KCCE_With(Map("alt_gr_then_tab", "copy", "tab_then_alt_gr", "paste", "caps_lock_then_left_ctrl", "cut", "caps_lock_then_tab", "copy"),
			false, _KCCE_AltGrBody.Bind(Kana))
		finally _TestRestoreAltGrFamily(Family)
	}
}
_KCCE_AltGrBody(Kana, World, Ports) {
	AssertEqual(false, KeyCombinationChordOwns("alt_gr", Ports), "AltGr never waits: its prefix must see its press")
	AssertEqual(false, KeyCombinationChordPairIsAllowed("alt_gr_then_tab"))
	if !Kana
		AssertEqual(false, KeyCombinationChordOwns("left_ctrl", Ports), "the fake LCtrl of AltGr is never swallowed")
	else
		AssertEqual(true, KeyCombinationChordKeyIsAllowed("left_ctrl"), "Kana: LCtrl is only LCtrl")
	AssertEqual("wait", _KCCE_Press(World, Ports, "caps_lock"))
	AssertEqual(false, KeyCombinationChordOwns("alt_gr", Ports), "a wait lets AltGr through")
	if !Kana
		AssertEqual(false, KeyCombinationChordOwns("left_ctrl", Ports), "and its fake LCtrl")
}
Test("key chord engine: AltGr is never buffered on either family (item2-altgr)", _KCCE_AltGrStaysOut)

; A press replayed by the native owner after a terminal expansion is held only in the
; ledger: its wait must not read it as already released.
_KCCE_ReplayedPressIsHeld() {
	Previous := KS_NativeKeyPressPort()
	KS_NativeKeyPressPort((Sc) => { flags: Sc == 0x03A ? KS_NATIVE_KEY_HIDDEN | KS_NATIVE_KEY_REAL_DOWN : 0, sequence: 0 })
	try {
		_KCCE_With(Map("caps_lock_then_tab", "copy"), false, (World, Ports) => (
			AssertEqual(true, _KeyCombinationKeyIsHeld("caps_lock"), "the ledger holds the replayed key"),
			AssertEqual(false, _KeyCombinationKeyIsHeld("tab"))))
	} finally KS_NativeKeyPressPort(Previous)
}
Test("key chord engine: a key replayed after a terminal expansion stays held (item2-terminal)",
	_KCCE_ReplayedPressIsHeld)

_KCCE_ConfigRefusals() {
	_KCCE_With(Map("caps_lock_then_tab", "one_shot_shift", "tab_then_caps_lock", "no_such_action", "not_a_pair", "copy"),
		false, _KCCE_RefusalsBody)
}
_KCCE_RefusalsBody(World, Ports) {
	AssertEqual(0, KeyCombinationChords.Count, "an action that needs the key's press, an unknown action, an unknown pair")
	AssertEqual(100, KeyCombinationChordConfig["simultaneous_threshold_ms"])
}
Test("key chord engine: the config refuses what a chord cannot hold (item2-config)", _KCCE_ConfigRefusals)

_KCCE_MenuSlots() {
	_KCCE_With(Map("caps_lock_then_tab", "copy"), false, _KCCE_MenuBody)
}
_KCCE_MenuBody(World, Ports) {
	Rows := KeyCombinationSlotRows("caps_lock_then_tab", "CapsLock + Tab")
	AssertEqual(3, Rows.Length, "tap, hold and chord")
	Assert(InStr(Rows[3]["label"], StrReplace(t("menu.shortcuts.key_combinations_chord"), "%s", "")) > 0, "the chord row")
	Family := _TestSetAltGrFamily(false)
	try {
		Rows := KeyCombinationSlotRows("caps_lock_then_alt_gr", "CapsLock + AltGr")
		AssertEqual("menu.shortcuts.key_combinations_chord_no_altgr", Rows[3]["disabled_reason_key"], "the row says why")
		AssertEqual(true, Rows[3]["disabled"])
	} finally _TestRestoreAltGrFamily(Family)
	AssertEqual("copy", KeyCombinationChordOf("caps_lock_then_tab"))
	AssertEqual("none", KeyCombinationChordOf("tab_then_caps_lock"), "not symmetric: the other order holds nothing")
}
Test("key chord engine: each pair shows its chord slot, AltGr's says why not (item2-menu)", _KCCE_MenuSlots)

; The cost a plain character pays: the one read added to the roll block's criterion.
_KCCE_PlainTypingBudget() {
	_KCCE_With(Map(), false, _KCCE_BudgetBody)
}
_KCCE_BudgetBody(World, Ports) {
	Start := A_TickCount
	Loop 100000
		TapHoldRollUndecided()
	Elapsed := A_TickCount - Start
	Assert(Elapsed < 2000, "100000 criterion reads took " . Elapsed . " ms: the hot path budget is 20 us per key")
}
Test("key chord engine: plain typing stays inside the hot path budget (item2-budget)", _KCCE_PlainTypingBudget)
