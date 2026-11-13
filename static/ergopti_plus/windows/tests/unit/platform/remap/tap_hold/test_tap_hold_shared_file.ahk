; tests/unit/platform/remap/tap_hold/test_tap_hold_shared_file.ahk

; ==============================================================================
; MODULE: One tap-hold configuration on every OS (Windows side)
; DESCRIPTION:
; The cross-driver corpus _shared/tests/corpus/tap_hold_shared_file/ holds, for
; each driver, the tap_hold.toml its writers write and the config.toml rows
; written beside it (<name>.toml, <name>.config.toml). The Linux and macOS
; suites pin their own pair and read the others; this suite pins the Windows
; pair (windows_written) and reads all three with the Windows readers:
; LoadTapHoldToml for the keys and the global delay, the config.toml boot
; readers for the lone-tap window, the one-shot timeout and the key chords.
; [reads.<name>.ahk] of expected.toml is what each must read.
; ==============================================================================

#Requires AutoHotkey v2.0

_THSF_CorpusDir() {
	global _SharedDir
	return _SharedDir . "\tests\corpus\tap_hold_shared_file"
}

_THSF_Expected() {
	return TOML_ParseDocument(FSReadUtf8Exact(_THSF_CorpusDir() . "\expected.toml"))
}

; The value a typed document holds, as the Windows readers compare it.
_THSF_Native(Value) {
	return (Value is TOML_Bool) ? (Value.Value ? 1 : 0) : Value
}

; The hold option the picker offers for a modifier set.
_THSF_ModifierHold(Id) {
	for _, Opt in TapHoldHoldOptions() {
		if Opt["kind"] == "modifier" && Opt["id"] == Id
			return Opt
	}
	throw Error("The hold picker offers no modifier hold '" . Id . "'.")
}

; Runs Body with every global the config.toml readers set restored afterwards.
_THSF_WithReaderGlobals(Body) {
	global TAP_HOLD_LONE_TAP_MAX_MS, ONE_SHOT_SHIFT_TIMEOUT_SEC
	global KeyCombinationChords, KeyCombinationChordConfig, _KeyCombinationChordPolicy, _KeyCombinationChordFirsts
	Saved := [TAP_HOLD_LONE_TAP_MAX_MS, ONE_SHOT_SHIFT_TIMEOUT_SEC, KeyCombinationChords,
		KeyCombinationChordConfig, _KeyCombinationChordPolicy, _KeyCombinationChordFirsts]
	try Body.Call()
	finally {
		TAP_HOLD_LONE_TAP_MAX_MS := Saved[1], ONE_SHOT_SHIFT_TIMEOUT_SEC := Saved[2]
		KeyCombinationChords := Saved[3], KeyCombinationChordConfig := Saved[4]
		_KeyCombinationChordPolicy := Saved[5], _KeyCombinationChordFirsts := Saved[6]
	}
}





; =========================================================
; =========================================================
; ======= 1/ Every pair read by the Windows readers =======
; =========================================================
; =========================================================

_THSF_ReadsPair(Name, Wanted) {
	global _SharedDir, KeyCombinationChords, KeyCombinationChordConfig
	Dir := _THSF_CorpusDir()
	TapHoldPath := Dir . "\" . Name . ".toml"
	ConfigPath := Dir . "\" . Name . ".config.toml"
	TH := LoadTapHoldToml(TapHoldPath, _SharedDir . "\tap_hold\data\defaults.toml")
	AssertEqual(Wanted["global_seconds"], TapHoldGlobalDuration(TH), Name . ": the global delay")
	Keys := Wanted.Get("keys", Map())
	AssertEqual(Keys.Count, TH["keys"].Count, Name . ": the keys Windows reads")
	for KeyId, Fields in Keys {
		Assert(TH["keys"].Has(KeyId), Name . ": key " . KeyId . " is read")
		Entry := TH["keys"][KeyId]
		for Field in ["tap_action", "hold_modifier", "hold_layer"]
			AssertEqual(Fields.Get(Field, ""), Entry.Get(Field, ""), Name . ": " . KeyId . "." . Field)
		Own := Entry.Has(ConfigLeaf.TIME_ACTIVATION_SECONDS) ? Entry[ConfigLeaf.TIME_ACTIVATION_SECONDS]
			: TapHoldGlobalDuration(TH)
		AssertEqual(Fields[ConfigLeaf.TIME_ACTIVATION_SECONDS], Own, Name . ": " . KeyId . " waits its delay")
	}
	Cache := ParseTomlFile(ConfigPath)
	TapHoldLoneTapReadConfig(Cache)
	AssertEqual(Wanted["lone_tap_max_ms"], TapHoldLoneTapMaxMs(), Name . ": the lone-tap window")
	TapHoldOneShotTimeoutReadConfig(Cache)
	AssertEqual(Wanted["one_shot_timeout_ms"], TapHoldOneShotTimeoutMs(), Name . ": the one-shot timeout")
	KeyCombinationChordsReadConfig(Cache)
	Combos := Wanted["mod_combos"]
	AssertEqual(Combos["simultaneous_threshold_ms"], KeyCombinationChordConfig[ConfigLeaf.SIMULTANEOUS_THRESHOLD_MS],
		Name . ": the chord delay")
	AssertEqual(_THSF_Native(Combos["symmetric"]), KeyCombinationChordConfig[MenuCommand.COMBO_SYMMETRIC],
		Name . ": the chord symmetry")
	Chords := Combos.Get("chords", Map())
	AssertEqual(Chords.Count, KeyCombinationChords.Count, Name . ": the chords Windows reads")
	for Pair, Action in Chords
		AssertEqual(Action, KeyCombinationChords.Get(Pair, ""), Name . ": chord " . Pair)
}

_THSF_EveryPairReads() {
	_THSF_WithReaderGlobals(_THSF_EveryPairReadsBody)
}
_THSF_EveryPairReadsBody() {
	Reads := _THSF_Expected()["reads"]
	Read := 0
	for Name in ["linux_written", "macos_written", "windows_written"] {
		Assert(Reads.Has(Name) && Reads[Name].Has("ahk"), "expected.toml says what Windows reads of " . Name)
		_THSF_ReadsPair(Name, Reads[Name]["ahk"])
		Read += 1
	}
	AssertEqual(3, Read, "every driver's pair is read")
}
Test("tap-hold shared file: Windows reads the pair every driver writes (tap-hold-shared-file)", _THSF_EveryPairReads)





; =====================================================
; =====================================================
; ======= 2/ The pair the Windows writers write =======
; =====================================================
; =====================================================

_THSF_WriterPinsItsTapHoldFileOwned(TargetPath) {
	global TapHold
	SplitPath(TargetPath, , &Root)
	Created := FSCreateDirectoryExclusiveStrict(Root)
	Assert((Created is Integer) && Created == 1, "the fixture exclusively owns its private directory")
	try {
		TapHold := Map("keys", Map())
		Steps := [
			() => WriteTapHoldGlobalDuration(0.25),
			() => WriteTapHoldTap("caps_lock", "backspace"),
			() => WriteTapHoldHold("caps_lock", _THSF_ModifierHold("ctrl")),
			() => WriteTapHoldTap("left_shift", "copy"),
			() => WriteTapHoldHold("left_shift", _THSF_ModifierHold("shift")),
			() => WriteTapHoldDuration("left_shift", 0.3),
			() => WriteTapHoldHold("tab", Map("kind", "layer", "id", "nav")),
			() => WriteTapHoldHold("win", _THSF_ModifierHold("ctrl+alt"))]
		for Index, Step in Steps {
			Result := Step.Call()
			Assert((Result is Integer) && Result == 1, "Windows write " . Index . " is published")
		}
		Wanted := FSReadUtf8Exact(_THSF_CorpusDir() . "\windows_written.toml")
		AssertEqual(Wanted, FSReadUtf8Exact(TargetPath), "the Windows writers write windows_written.toml byte for byte")
	} finally {
		for Cache in [_TomlFileCache, _ParseTomlCache, _ConfigTomlSnapshots]
			if Cache.Has(TargetPath)
				Cache.Delete(TargetPath)
		if Created
			DirDelete(Root, true)
	}
}
_THSF_WriterPinsItsTapHoldFile() {
	return _THHS_WithNativeFixture(_THSF_WriterPinsItsTapHoldFileOwned)
}
Test("tap-hold shared file: the Windows writers write windows_written.toml (tap-hold-shared-file)",
	_THSF_WriterPinsItsTapHoldFile)

_THSF_WriterPinsItsConfigRows() {
	_THSF_WithReaderGlobals(_THSF_WriterPinsItsConfigRowsBody)
}
_THSF_WriterPinsItsConfigRowsBody() {
	Path := A_Temp . "\ergopti_thsf_config_" . DllCall("GetCurrentProcessId", "UInt") . ".toml"
	if FileExist(Path)
		FileDelete(Path)
	FileAppend("", Path, "UTF-8-RAW")
	Reload := () => "reloaded"
	try {
		AssertEqual("reloaded", _TH_CommitLoneTapMaxMs(0, Path, Reload), "the lone-tap window is written")
		AssertEqual("reloaded", _TH_CommitOneShotTimeoutMs(1500, Path, Reload), "the one-shot timeout is written")
		AssertEqual("reloaded", KeyCombinationChordCommitDelay("80", Path, Reload), "the chord delay is written")
		KeyCombinationChordsReadConfig(TOML_ParseFreshFile(Path))
		AssertEqual("reloaded", KeyCombinationChordToggleSymmetric(Path, Reload), "the chord symmetry is written")
		Written := TOML_ParseDocument(FSReadUtf8Exact(Path))
		Wanted := TOML_ParseDocument(FSReadUtf8Exact(_THSF_CorpusDir() . "\windows_written.config.toml"))
		for Section, Values in Wanted {
			Assert(Written.Has(Section), "the Windows writers write [" . Section . "]")
			AssertEqual(Values.Count, Written[Section].Count, "[" . Section . "] holds the corpus leaves only")
			for Key, Value in Values
				AssertEqual(_THSF_Native(Value), _THSF_Native(Written[Section].Get(Key, "")),
					"[" . Section . "] " . Key . " is what windows_written.config.toml holds")
		}
		AssertEqual(Wanted.Count, Written.Count, "no other section is written")
	} finally FileDelete(Path)
}
Test("tap-hold shared file: the Windows writers write the config.toml rows of windows_written (tap-hold-shared-file)",
	_THSF_WriterPinsItsConfigRows)





; ===================================================
; ===================================================
; ======= 3/ Another driver's leaves are kept =======
; ===================================================
; ===================================================

; A Windows edit keeps the macOS Karabiner section and the keys only macOS has,
; drops the macOS hold it replaces and switches a rebound key back on.
_THSF_WriterKeepsOtherDriversOwned(TargetPath) {
	global TapHold, _SharedDir
	SplitPath(TargetPath, , &Root)
	Created := FSCreateDirectoryExclusiveStrict(Root)
	Assert((Created is Integer) && Created == 1, "the fixture exclusively owns its private directory")
	try {
		Source := "[_meta]`nschema_version = " . TapHoldMigrationRegistry()["current"] . "`n`n"
			. "[karabiner]`nintegration_enabled = false`n`n"
			. "[tap_hold.keys.left_option]`nhold_modifier = " . Chr(34) . "alt" . Chr(34) . "`n`n"
			. "[tap_hold.keys.caps_lock]`nhold_action = " . Chr(34) . "hyper" . Chr(34) . "`nenabled = false`n"
		AssertEqual(1, FSWriteCreateDurable(TargetPath, Source))
		TapHold := LoadTapHoldToml(TargetPath, _SharedDir . "\tap_hold\data\defaults.toml")
		Result := WriteTapHoldHold("caps_lock", _THSF_ModifierHold("ctrl"))
		Assert((Result is Integer) && Result == 1, "the Windows hold is published")
		Document := TOML_ParseDocument(FSReadUtf8Exact(TargetPath))
		Assert(Document.Has("karabiner") && Document["karabiner"].Has("integration_enabled"),
			"the macOS Karabiner section stays")
		Assert(Document["tap_hold"]["keys"].Has("left_option"), "a key only macOS has stays")
		CapsLock := Document["tap_hold"]["keys"]["caps_lock"]
		AssertEqual("ctrl", CapsLock["hold_modifier"], "the Windows hold is written")
		AssertFalse(CapsLock.Has("hold_action"), "the macOS hold it replaces goes")
		AssertFalse(CapsLock.Has("enabled"), "a key the user rebinds is switched back on")
	} finally {
		for Cache in [_TomlFileCache, _ParseTomlCache, _ConfigTomlSnapshots]
			if Cache.Has(TargetPath)
				Cache.Delete(TargetPath)
		if Created
			DirDelete(Root, true)
	}
}
_THSF_WriterKeepsOtherDrivers() {
	return _THHS_WithNativeFixture(_THSF_WriterKeepsOtherDriversOwned)
}
Test("tap-hold shared file: a Windows edit keeps the other drivers' leaves (tap-hold-shared-file)",
	_THSF_WriterKeepsOtherDrivers)

; A file another driver wrote: macOS holds and an older build's manifest rows
; are warned once each and left in the file, never an ERROR; the key keeps its tap.
_THSF_LoaderWarnsOtherDriversLeaves() {
	global _SharedDir, _TomlFileCache, _ParseTomlCache
	Path := A_Temp . "\ergopti_thsf_loader_" . DllCall("GetCurrentProcessId", "UInt") . ".toml"
	Content := "[_meta]`nschema_version = " . TapHoldMigrationRegistry()["current"] . "`n`n"
		. "[mod_combos]`nsymmetric = true`n`n"
		. "[tap_hold]`nenabled = true`nsticky_timeout_ms = 1500`n`n"
		. "[tap_hold.keys.left_ctrl]`ntap_action = " . Chr(34) . "copy" . Chr(34)
		. "`nhold_modifier = " . Chr(34) . "shift+cmd" . Chr(34) . "`n`n"
		. "[tap_hold.keys.caps_lock]`nhold_action = " . Chr(34) . "hyper" . Chr(34) . "`n"
	if FileExist(Path)
		FileDelete(Path)
	FileAppend(Content, Path, "UTF-8-RAW")
	try {
		TH := LoadTapHoldToml(Path, _SharedDir . "\tap_hold\data\defaults.toml")
		AssertEqual("copy", TH["keys"]["left_ctrl"]["tap_action"], "a Cmd hold keeps the key's tap")
		AssertEqual("", TH["keys"]["left_ctrl"]["hold_modifier"], "a Cmd hold holds nothing here")
		; The ring buffer is bounded and full in a long run: keep this file's lines.
		Text := ""
		for Line in LoggerRingBufferSnapshot()
			if InStr(Line, "ergopti_thsf_loader_")
				Text .= Line . "`n"
		for Wanted in ["tap_hold.enabled", "tap_hold.sticky_timeout_ms", "mod_combos", "a macOS modifier", "a macOS hold action"]
			AssertContains(Text, Wanted)
		AssertFalse(InStr(Text, "Unknown hold_modifier"), "a macOS modifier is no unknown hold")
	} finally {
		for Cache in [_TomlFileCache, _ParseTomlCache]
			if Cache.Has(Path)
				Cache.Delete(Path)
		FileDelete(Path)
	}
}
Test("tap-hold shared file: the loader warns once about another driver's leaves (tap-hold-shared-file)",
	_THSF_LoaderWarnsOtherDriversLeaves)

; TCL-004, « follow the position »: a Mac thumb key a Mac wrote under its own id
; is the PC key at its place, unless the file names that key too, which wins.
; The expectations are the ones Linux reads ([reads.mac_thumb.linux]).
_THSF_MacThumbKeysFollowThePosition() {
	global _SharedDir
	Dir := _SharedDir . "\tests\corpus\tap_hold_spellings"
	Expected := TOML_ParseDocument(FSReadUtf8Exact(Dir . "\expected.toml"))
	TH := LoadTapHoldToml(Dir . "\mac_thumb.toml", _SharedDir . "\tap_hold\data\defaults.toml")
	Keys := Expected["reads"]["mac_thumb"]["linux"]["keys"]
	for KeyId, Fields in Keys {
		AssertTrue(TH["keys"].Has(KeyId), KeyId . " is read from its Mac thumb id")
		for Field, Value in Fields
			AssertEqual(_THSF_Native(Value), TH["keys"][KeyId].Get(Field, ""), KeyId . "." . Field)
	}
}
Test("tap-hold shared file: a Mac thumb key is the PC key at its place (tap-hold-spellings)",
	_THSF_MacThumbKeysFollowThePosition)
