; tests/unit/keyboard/engine/key_combinations/test_chord_engine.ahk

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
	global _KeyCombinationChordOwner
	global _KeyCombinationChordWaiting, _KeyCombinationChordTaken, _KeyCombinationChordQueue, _KeyCombinationChordBusy
	global _KeyCombinationChordWaitAt, _KeyCombinationChordReplaying
	global CategoryEnabled, _KeyCombinationScanNames, _KeyCombinationKeysByScanName, _KeyCombinationTaken, _KeyCombinationHandled
	global _KeyCombinationPressAssignments, KeyCombinationTaps, KeyCombinationHolds, _KeyCombinationFirstKeys, LayerEnabled
	AssertTrue(_KeyCombinationChordWaiting == "" && _KeyCombinationChordQueue.Length == 0
		&& _KeyCombinationChordTaken.Count == 0 && !_KeyCombinationChordBusy,
		"A foreign live chord batch cannot be parked across lifecycle teardown")
	SavedChord := {Waiting: _KeyCombinationChordWaiting, At: _KeyCombinationChordWaitAt,
		Taken: _KeyCombinationChordTaken, Queue: _KeyCombinationChordQueue, Busy: _KeyCombinationChordBusy,
		Replaying: _KeyCombinationChordReplaying}
	Saved := [KeyCombinationChords, KeyCombinationChordConfig, _KeyCombinationChordPolicy, _KeyCombinationChordFirsts,
		CategoryEnabled, LayerEnabled, IsSet(_KeyCombinationChordOwner) ? _KeyCombinationChordOwner : 0]
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
	_KeyCombinationChordOwner := 0
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
		_KeyCombinationChordOwner := IsObject(Saved[7]) && !TapHoldOwnerCurrent(Saved[7]) ? 0 : Saved[7]
		_KeyCombinationChordWaiting := SavedChord.Waiting, _KeyCombinationChordWaitAt := SavedChord.At
		_KeyCombinationChordTaken := SavedChord.Taken, _KeyCombinationChordQueue := SavedChord.Queue
		_KeyCombinationChordBusy := SavedChord.Busy, _KeyCombinationChordReplaying := SavedChord.Replaying
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

; The bulk copy, as macOS and Linux plan it: a chord takes its pair's tap, an
; empty tap empties the chord, a chord already equal is left alone and a tap no
; chord can run keeps the chord it has.
_KCCE_CopyRows(Source) {
	Rows := Map()
	for Row in KeyCombinationChordCopyRows(ConfigTomlDecodeSnapshot(Source), (*) => true)
		Rows[Row.Section] := Row
	return Rows
}
_KCCE_ChordCopySource(Symmetric) {
	return '[shortcuts.key_combination_taps]`ncaps_lock_then_tab = "copy"`ntab_then_caps_lock = "paste"`n'
		. 'space_then_tab = "one_shot_shift"`n'
		. '[mod_combos]`nsymmetric = ' . (Symmetric ? "true" : "false") . '`n'
		. '[mod_combos.config.caps_lock_then_space]`ncombo = "copy"`n'
		. '[mod_combos.config.space_then_tab]`ncombo = "copy"`n'
}
_KCCE_ChordCopyPlansFromTheTaps() {
	Rows := _KCCE_CopyRows(_KCCE_ChordCopySource(false) . '[mod_combos.config.tab_then_caps_lock]`ncombo = "paste"`n')
	Row := Rows.Get("mod_combos.config.caps_lock_then_tab", 0)
	AssertTrue(IsObject(Row) && Row.Key == "combo" && Row.Value == "copy", "the chord takes the pair's tap")
	AssertFalse(Rows.Has("mod_combos.config.tab_then_caps_lock"), "a chord already equal to its tap is left alone")
	Row := Rows.Get("mod_combos.config.caps_lock_then_space", 0)
	AssertTrue(IsObject(Row) && Row.HasOwnProp("Delete") && Row.Delete, "an empty tap empties the chord")
	AssertFalse(Rows.Has("mod_combos.config.space_then_tab"), "a tap no chord can run keeps the chord it has")
	AssertEqual(2, Rows.Count, "nothing else moves")
	AssertEqual(0, _KCCE_CopyRows("").Count, "an empty configuration has nothing to copy")
}
Test("key combination chords: the bulk copy plans each chord from its pair's tap (copy-tap-to-combo)",
	_KCCE_ChordCopyPlansFromTheTaps)

; Under symmetry both orders share the earlier order's chord slot: only that
; order's tap is copied, and the later order gets no slot of its own.
_KCCE_ChordCopyFollowsSymmetry() {
	Owner := _KeyCombinationChordOwnerPairFor("caps_lock_then_tab", true)
	AssertTrue(Owner == "caps_lock_then_tab" || Owner == "tab_then_caps_lock", "the owner is one of the two orders")
	Other := Owner == "caps_lock_then_tab" ? "tab_then_caps_lock" : "caps_lock_then_tab"
	Rows := _KCCE_CopyRows(_KCCE_ChordCopySource(true))
	Row := Rows.Get("mod_combos.config." . Owner, 0)
	AssertTrue(IsObject(Row) && Row.Value == (Owner == "caps_lock_then_tab" ? "copy" : "paste"),
		"the shared slot takes its owner order's tap")
	AssertFalse(Rows.Has("mod_combos.config." . Other), "the other order gets no slot of its own")
}
Test("key combination chords: the bulk copy follows the chord symmetry (copy-tap-to-combo)",
	_KCCE_ChordCopyFollowsSymmetry)

; The command commits like every chord writer: a held lease reports false with no
; reload and no write; a free one writes and reloads once; a second copy has
; nothing left to do and neither writes nor reloads.
_KCCE_ChordCopyFollowsItsCommit() {
	Path := A_Temp . "\ergopti_kcce_chord_copy_" . DllCall("GetCurrentProcessId", "UInt") . ".toml"
	if FileExist(Path)
		FileDelete(Path)
	Source := _KCCE_ChordCopySource(false)
	FileAppend(Source, Path, "UTF-8-RAW")
	Reloads := 0
	Reload := () => (Reloads += 1, "reloaded")
	try {
		Owner := _ConfigWriteLeaseTryAcquire(Path, "chord-copy-refusal")
		AssertTrue(Owner is Object, "the test holds the write lease")
		try AssertEqual(false, KeyCombinationCopyTapsToChords(Path, Reload, (*) => true), "a refused commit reports false")
		finally _ConfigWriteLeaseRelease(Owner)
		AssertEqual(0, Reloads, "a refused commit never reloads")
		AssertEqual(Source, FileRead(Path, "UTF-8"), "a refused commit writes nothing")
		AssertEqual("reloaded", KeyCombinationCopyTapsToChords(Path, Reload, (*) => true), "a commit answers with its reload")
		AssertEqual(1, Reloads, "a commit reloads once")
		Cache := ConfigTomlDecodeSnapshot(FileRead(Path, "UTF-8")).Cache
		AssertEqual("copy", Cache["mod_combos.config.caps_lock_then_tab"]["combo"], "the copied chord reaches the file")
		AssertEqual(true, KeyCombinationCopyTapsToChords(Path, Reload, (*) => true), "a second copy has nothing to do")
		AssertEqual(1, Reloads, "a copy with nothing to change never reloads")
	} finally FileDelete(Path)
}
Test("key combination chords: the bulk copy reports a refused commit and never reloads behind it (copy-tap-to-combo)",
	_KCCE_ChordCopyFollowsItsCommit)

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

; Deliver the actual poll/drain through native SetTimer after native Suspend.
; The real engine/policy owns admission and queueing; only keyboard edges are observed.
_KCCE_NativePauseDelivery(Queued, Pause, RetireBeforeDelivery := false) {
	_KCCE_With(Map("space_then_tab", "copy"), false, _KCCE_NativePauseBody.Bind(Queued, Pause, RetireBeforeDelivery))
}

_KCCE_NativePauseBody(Queued, Pause, RetireBeforeDelivery, World, Ports) {
	global _KeyCombinationChordQueue, _KeyCombinationChordWaiting, _KeyCombinationChordBusy
	WasSuspended := A_IsSuspended, PreviousCritical := Critical("On")
	Delivered := 0, Failure := 0, Before := 0, BusyAfterResume := false
	Deliver() {
		try {
			if Queued
				KeyCombinationChordDrain(Ports)
			else
				KeyCombinationChordTick(Ports)
		} catch as Err {
			Failure := Err
		} finally Delivered += 1
	}
	OriginalPoll := Ports["arm_poll"]
	Poll(Armed) {
		OriginalPoll.Call(Armed)
		if !Queued
			SetTimer(Deliver, Armed ? -1 : 0)
	}
	Ports["arm_poll"] := Poll
	if Queued
		Ports["arm_drain"] := () => SetTimer(Deliver, -1)
	try {
		Suspend(false)
		AssertEqual("wait", _KCCE_Press(World, Ports, "space"), "the real policy must admit the first press")
		if Queued {
			KeyCombinationChordInterrupt(0x010, Ports)
			AssertEqual(1, World.Sends.Length, "the originating Space precedes the queued letter before pause")
		} else {
			World.Held.Delete("space")
			World.Now += 5
		}
		Before := World.Sends.Length
		if RetireBeforeDelivery {
			Suspend(true)
			try AssertTrue(TapHoldReleaseSyntheticKeys())
			finally Suspend(false)
			BusyAfterResume := TapHoldRollUndecided()
		} else
			Suspend(Pause)
		Critical("Off")
		Started := A_TickCount
		while Delivered == 0 && A_TickCount - Started < 3000
			Sleep(5)
		AssertEqual(1, Delivered, "one genuine native timer must deliver the production callback")
		if IsObject(Failure)
			throw Failure
		AssertEqual(Before + ((Pause || RetireBeforeDelivery) ? 0 : 1), World.Sends.Length,
			"a paused poll/drain must never inject; its unpaused control must genuinely replay")
		if RetireBeforeDelivery
			AssertFalse(BusyAfterResume, "a retired criterion must not intercept new typing before its old timer delivers")
		AssertEqual(0, _KeyCombinationChordQueue.Length, "a retired queue must not replay after resume")
		AssertEqual("", _KeyCombinationChordWaiting)
		AssertFalse(_KeyCombinationChordBusy)
		Suspend(false)
		KeyCombinationChordDrain(Ports)
		KeyCombinationChordTick(Ports)
		AssertEqual(Before + ((Pause || RetireBeforeDelivery) ? 0 : 1), World.Sends.Length, "resume cannot revive the retired replay")
	} finally {
		SetTimer(Deliver, 0)
		Suspend(WasSuspended)
		Critical(PreviousCritical)
	}
}
for _KCCE_QueuedNative in [false, true]
	for _KCCE_PauseNative in [false, true]
		Test("key chord lifecycle: native queued=" . _KCCE_QueuedNative . " paused=" . _KCCE_PauseNative . " fences replay (chord-native-pause)",
			_KCCE_NativePauseDelivery.Bind(_KCCE_QueuedNative, _KCCE_PauseNative))


_KCCE_NativeResumeBeforeDelivery(Queued) {
	_TSUH_Begin(Map(), Map())
	try _KCCE_NativePauseDelivery(Queued, false, true)
	finally _TSUH_End()
}
for _KCCE_ResumeQueued in [false, true]
	Test("key chord lifecycle: queued=" . _KCCE_ResumeQueued . " pause and resume before native delivery revoke replay (chord-native-resume)",
		_KCCE_NativeResumeBeforeDelivery.Bind(_KCCE_ResumeQueued))

; A real lifecycle cleanup retires A, then B enters through the real criterion/handler.
_KCCE_PublishResumedFirst(World, Ports) {
	Suspend(true)
	try AssertTrue(TapHoldReleaseSyntheticKeys())
	finally Suspend(false)
	World.Held := Map()
	return _KCCE_Press(World, Ports, "space")
}

_KCCE_SuccessorDuringHeldRead() {
	_TSUH_Begin(Map(), Map())
	try _KCCE_With(Map("space_then_tab", "copy"), false, _KCCE_SuccessorHeldBody)
	finally _TSUH_End()
}
_KCCE_SuccessorHeldBody(World, Ports) {
	global _KeyCombinationChordWaiting, _KeyCombinationChordQueue, _KeyCombinationChordBusy
	WasSuspended := A_IsSuspended, Ready := false, Replaced := false, BResult := ""
	OriginalHeld := Ports["is_held"]
	Read(Key) {
		if Ready && !Replaced && Key == "space" {
			Replaced := true
			BResult := _KCCE_PublishResumedFirst(World, Ports)
		}
		return OriginalHeld.Call(Key)
	}
	Ports["is_held"] := Read
	try {
		Suspend(false)
		AssertEqual("wait", _KCCE_Press(World, Ports, "space"))
		Ready := true
		KeyCombinationChordInterrupt(0x010, Ports)
		AssertTrue(Replaced, "the actual held-state callout must run lifecycle teardown and admit B")
		AssertEqual(0, World.Sends.Length, "old A must not emit after its held-state callback publishes B")
		AssertEqual("wait", BResult, "the resumed first key must start its own real wait")
		AssertEqual("space", _KeyCombinationChordWaiting)
		AssertEqual(0, _KeyCombinationChordQueue.Length, "old Interrupt must not append its character into B's queue")
		AssertTrue(_KeyCombinationChordBusy)
	} finally Suspend(WasSuspended)
}
Test("key chord lifecycle: held-state callback preserves a resumed successor (chord-callout-successor)", _KCCE_SuccessorDuringHeldRead)

_KCCE_SuccessorDuringLog() {
	global _LOGGER_TEST_SINK, _LOGGER_INFO_ENABLED, _LOGGER_MIN_SEVERITY
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT, _LastErrTime, _LOGGER_REPEAT_ENABLED
	Saved := {Sink: _LOGGER_TEST_SINK, Info: _LOGGER_INFO_ENABLED, Severity: _LOGGER_MIN_SEVERITY,
		Dedup: _LOGGER_DEDUP_KEY, Level: _LOGGER_DEDUP_LEVEL, Count: _LOGGER_DEDUP_COUNT,
		Time: _LastErrTime, Repeat: _LOGGER_REPEAT_ENABLED}
	_TSUH_Begin(Map(), Map())
	try {
		_LOGGER_INFO_ENABLED := true, _LOGGER_MIN_SEVERITY := 10
		_LOGGER_DEDUP_KEY := "", _LOGGER_REPEAT_ENABLED := false
		_KCCE_With(Map("space_then_tab", "copy"), false, _KCCE_SuccessorLogBody)
	} finally {
		_LOGGER_TEST_SINK := Saved.Sink, _LOGGER_INFO_ENABLED := Saved.Info, _LOGGER_MIN_SEVERITY := Saved.Severity
		_LOGGER_DEDUP_KEY := Saved.Dedup, _LOGGER_DEDUP_LEVEL := Saved.Level, _LOGGER_DEDUP_COUNT := Saved.Count
		_LastErrTime := Saved.Time, _LOGGER_REPEAT_ENABLED := Saved.Repeat
		_TSUH_End()
	}
}
_KCCE_SuccessorLogBody(World, Ports) {
	global _KeyCombinationChordWaiting, _KeyCombinationChordQueue, _KeyCombinationChordBusy
	WasSuspended := A_IsSuspended, Replaced := false, BResult := ""
	Observe(Line) {
		if Replaced || !InStr(Line, "[KeyCombinations] Chord '")
			return
		Replaced := true
		BResult := _KCCE_PublishResumedFirst(World, Ports)
	}
	try {
		Suspend(false)
		AssertEqual("wait", _KCCE_Press(World, Ports, "space"))
		LoggerSetTestSink(Observe)
		World.Now += 10
		KeyCombinationChordHandle("tab", Ports)
		AssertTrue(Replaced, "the actual chord log must reach the controlled lifecycle interruption")
		AssertEqual(0, World.Actions.Length, "old A must not fire its action after logging publishes B")
		AssertEqual("wait", BResult)
		AssertEqual("space", _KeyCombinationChordWaiting)
		AssertEqual(0, _KeyCombinationChordQueue.Length)
		AssertTrue(_KeyCombinationChordBusy)
	} finally Suspend(WasSuspended)
}
Test("key chord lifecycle: logging cannot fire a retired action or erase its successor (chord-callout-successor)", _KCCE_SuccessorDuringLog)

_KCSBOOT_ReadTypedSettings(Mode, _World, _Ports) {
	global ConfigurationFile, _ConfigBootReadFailed
	global KeyCombinationChordConfig, _KeyCombinationChordPolicy
	SavedPath := ConfigurationFile, SavedReadFailed := _ConfigBootReadFailed
	Root := A_Temp . "\ergopti_key_chord_boot_types_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . "\config.toml", Created := false
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created, "the real source fixture must acquire its root before any write")
		DelayRaw := "100", SymmetryRaw := "false", ExpectedDelay := 100, ExpectedSymmetry := false, Elapsed := 0
		switch Mode {
			case "quoted-symmetry": SymmetryRaw := '"false"'
			case "number-symmetry": SymmetryRaw := "2"
			case "quoted-delay": DelayRaw := '"500"', Elapsed := 200
			case "boolean-delay": DelayRaw := "true", Elapsed := 50
			case "true-control": SymmetryRaw := "true", ExpectedSymmetry := true
			case "numeric-delay-control": DelayRaw := "500", ExpectedDelay := 500, Elapsed := 200
		}
		Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n[mod_combos]`n"
			. "simultaneous_threshold_ms = " . DelayRaw . "`nsymmetric = " . SymmetryRaw . "`n"
			. '[mod_combos.config.caps_lock_then_tab]`ncombo = "copy"`n'
			. '[mod_combos.config.tab_then_caps_lock]`ncombo = "paste"`n'
		AssertTrue(FSWriteCreateDurable(Path, Source))
		ConfigurationFile := Path
		Boot := ConfigMigrateBoot(Path)
		AssertEqual("current", Boot["status"], "the source must have a genuine current-schema boot admission")
		Cache := ParseConfigTomlFile(Path)
		Snapshot := ConfigTomlBootSnapshot(Cache)
		AssertTrue(IsObject(Snapshot), "the policy must receive the actual boot cache rather than a detached mock")
		ConfigTomlBootSnapshotValue(Snapshot, "mod_combos", "symmetric", &CanonicalSymmetry)
		ConfigTomlBootSnapshotValue(Snapshot, "mod_combos", "simultaneous_threshold_ms", &CanonicalDelay)
		AssertEqual(ExpectedSymmetry, CanonicalSymmetry, "the canonical boot owner already knows the stored or default symmetry")
		AssertEqual(ExpectedDelay, CanonicalDelay, "the canonical boot owner already knows the stored or default timing")
		KeyCombinationChordsReadConfig(Cache)
		Forward := _KeyCombinationChordPolicy.Choose("caps_lock", "tab", Elapsed)
		Reverse := _KeyCombinationChordPolicy.Choose("tab", "caps_lock", Elapsed)
		if Elapsed > ExpectedDelay {
			AssertFalse(Forward, "an outdated quoted delay cannot lengthen the real policy's chord window")
			AssertFalse(Reverse)
		} else {
			AssertTrue(Forward is Map && Reverse is Map, "valid timing must preserve both authored actions")
			AssertEqual(ExpectedSymmetry ? "paste" : "copy", Forward["action"], "the actual policy must not route a non-symmetric order to its reverse action")
			AssertEqual("paste", Reverse["action"])
		}
		AssertEqual(ExpectedSymmetry, KeyCombinationChordConfig[MenuCommand.COMBO_SYMMETRIC])
		AssertEqual(ExpectedDelay, KeyCombinationChordConfig[ConfigLeaf.SIMULTANEOUS_THRESHOLD_MS])
		AssertEqual(Source, FSReadUtf8Exact(Path), "loading outdated values must leave the authored source unchanged")
	} finally {
		ConfigurationFile := SavedPath, _ConfigBootReadFailed := SavedReadFailed
		if Created {
			try _TOML_InvalidateParseCache(Path)
			finally DirDelete(Root, true)
		}
	}
}
for _KCSBOOT_Mode in ["quoted-symmetry", "number-symmetry", "quoted-delay", "boolean-delay", "false-control", "true-control", "numeric-delay-control"]
	Test("key chord boot settings: " . _KCSBOOT_Mode,
		_KCCE_With.Bind(Map(), false, _KCSBOOT_ReadTypedSettings.Bind(_KCSBOOT_Mode)))

; Uses the real-file admission fixture from test_tap_hold_lone_tap.ahk.
_KCSENABLED_Run(Mode, _World, _Ports) {
	Raw := Mode == "number-zero" ? "-0" : Mode == "legacy-zero-control" ? "0"
		: Mode == "legacy-one-control" ? "1 # retained old writer intent" : Mode == "false-control" ? "false" : "true"
	Source := "[mod_combos]`nenabled = " . Raw . "`n"
		. '[mod_combos.config.caps_lock_then_tab]`ncombo = "copy"`n'
	_RBC_WithActualBootCache(Source, _KCSENABLED_Read.Bind(Mode))
}
_KCSENABLED_Read(Mode, Cache) {
	global _KeyCombinationChordPolicy
	Expected := Mode != "false-control" && Mode != "legacy-zero-control"
	Snapshot := ConfigTomlBootSnapshot(Cache)
	AssertFalse(ManifestFindEntryByPath("mod_combos.enabled") is Map, "the private enabled switch has no feature-manifest default")
	Authored := Snapshot.Document["mod_combos"]["enabled"]
	if Mode == "number-zero"
		AssertTrue(Authored is Integer && Authored == 0, "signed zero keeps its native integer shape but is not an old writer bare0 spelling")
	else if InStr(Mode, "legacy-") == 1
		AssertTrue(Authored is Integer && Authored == Expected, "the exact bare0/1 old writer spellings preserve legacy intent")
	else
		AssertTrue(Authored is TOML_Bool, "valid controls retain their actual authored Boolean type")
	KeyCombinationChordsReadConfig(Cache)
	AssertEqual(Expected, IsObject(_KeyCombinationChordPolicy), "an outdated numeric zero must not disable the admitted default chord policy")
	if Expected {
		Chosen := _KeyCombinationChordPolicy.Choose("caps_lock", "tab", 0)
		AssertTrue(Chosen is Map)
		AssertEqual("copy", Chosen["action"])
	}
}
for _KCSENABLED_Mode in ["number-zero", "false-control", "true-control", "legacy-zero-control", "legacy-one-control"]
	Test("key chord boot enabled admission: " . _KCSENABLED_Mode,
		_KCCE_With.Bind(Map(), false, _KCSENABLED_Run.Bind(_KCSENABLED_Mode)))


_KCCE_ChordDelayCannotWrap() {
 _KCCE_With(Map(), false, _KCCE_ChordDelayCannotWrapBody)
}
_KCCE_ChordDelayCannotWrapBody(World, Ports) {
 Path := A_Temp . "\ergopti_chord_numeric_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999) . ".toml"
 AssertTrue(FSWriteCreateDurable(Path, "") != 0)
 Reloads := 0, Reload := () => (Reloads += 1, true)
 try {
  Before := FSReadUtf8Exact(Path)
  for Raw in ["18446744073709551619", "00018446744073709551619", "9223372036854775808", "0", "", "soon"] {
   AssertFalse(KeyCombinationChordCommitDelay(Raw, Path, Reload), "The complete user magnitude must be refused before any config write")
   AssertEqual(Before, FSReadUtf8Exact(Path), "A rejected delay cannot change even private source bytes")
   AssertEqual(0, Reloads, "A rejected delay cannot reload")
  }
  AssertTrue(KeyCombinationChordCommitDelay("3", Path, Reload))
  AssertEqual(1, Reloads)
  AssertTrue(KeyCombinationChordCommitDelay("3.5", Path, Reload), "The existing positive fractional grammar must stay accepted")
  AssertEqual(2, Reloads)
  AssertContains(FSReadUtf8Exact(Path), "simultaneous_threshold_ms = 3.5")
 } finally FileDelete(Path)
}
Test("Key combination chord delay rejects overflowing decimal aliases (chord-delay-numeric-domain)", _KCCE_ChordDelayCannotWrap)
