; tests/support/altgr_suffix_cohort.ahk

; MODULE: Canonical Native AltGr Suffix Cohort
; DESCRIPTION: Shared unchanged native callbacks and controlled fixture ownership.

; Runs Body with the given slots in force, the switch of the combinations in
; State, and no press in flight; restores everything afterwards.
_KCT_With(Taps, Holds, Body, GateOn := true) {
	global KeyCombinationTaps, KeyCombinationHolds, _KeyCombinationFirstKeys
	global _KeyCombinationTaken, _KeyCombinationHandled, CategoryEnabled, _OB_ALTGR_PASSTHROUGH
	Saved := { Taps: KeyCombinationTaps, Holds: KeyCombinationHolds, Index: _KeyCombinationFirstKeys,
		Taken: _KeyCombinationTaken, Handled: _KeyCombinationHandled,
		HadGate: CategoryEnabled.Has("KeyCombinations"), Gate: CategoryEnabled.Get("KeyCombinations", true),
		Onboarding: IsSet(_OB_ALTGR_PASSTHROUGH) ? _OB_ALTGR_PASSTHROUGH : false }
	KeyCombinationTaps := Taps
	KeyCombinationHolds := Holds
	_KeyCombinationFirstKeys := _KeyCombinationIndexFirstKeys(Taps, Holds)
	_KeyCombinationTaken := Map()
	_KeyCombinationHandled := Map()
	CategoryEnabled["KeyCombinations"] := GateOn
	_OB_ALTGR_PASSTHROUGH := false
	try Body.Call()
	finally {
		KeyCombinationTaps := Saved.Taps
		KeyCombinationHolds := Saved.Holds
		_KeyCombinationFirstKeys := Saved.Index
		_KeyCombinationTaken := Saved.Taken
		_KeyCombinationHandled := Saved.Handled
		if Saved.HadGate
			CategoryEnabled["KeyCombinations"] := Saved.Gate
		else
			CategoryEnabled.Delete("KeyCombinations")
		_OB_ALTGR_PASSTHROUGH := Saved.Onboarding
	}
}

; A physical-keys probe over the key ids of Down, counting its calls.
_KCT_Keys(Down, Calls := 0) {
	Held := Map()
	for _, KeyId in Down
		Held[KeyId] := true
	return (KeyId) => ((Calls is Array) ? Calls.Push(KeyId) : 0, Held.Has(KeyId))
}

; Recording ports for KeyCombinationFire. OwnerTap is the "tap" the hold owner
; reports once the second key is up.
_KCT_Ports(Events, OwnerTap := false) {
	return Map(
		"own_modifier", (Second, ModKey, Seconds) => (
			Events.Push("modifier:" . Second . ":" . (ModKey is Array ? "combination" : ModKey)),
			Map("tap", OwnerTap, "activated", true)),
		"own_layer", (Second, Seconds) => (Events.Push("layer:" . Second), Map("tap", OwnerTap, "activated", true)),
		"run_tap", (First, Second, ActionId) => Events.Push("tap:" . First . ">" . Second . ":" . ActionId),
		"take_first", (First, Second) => Events.Push("take:" . First))
}


; A standard-family AltGr suffix must reach the same admitted pair
; owner before the later native AltGr custom combinations. These cases use
; the real criterion/dispatch and synthetic release ledger. OS delivery and
; the raw fake-LCtrl-as-second boundary require separate native hook cases.
_KCT_AltGrSuffixMode(Hold, Passthrough, Family := "standard", GateOn := true) {
	SavedFamily := _TestSetAltGrFamily(Family == "kana", Family == "standard")
	Pair := "left_alt_then_alt_gr"
	try _KCT_With(Map(Pair, "caps_word"), Hold == "none" ? Map() : Map(Pair, Hold), Inspect, GateOn)
	finally _TestRestoreAltGrFamily(SavedFamily)
	Inspect() {
		Expected := Family == "standard" && GateOn
		AssertEqual(Expected, KeyCombinationOwnsAltGrSuffix(Passthrough, _KCT_Keys(["left_alt"])),
			Family . ": " . Hold . " reaches exactly its selected custom variant")
		if Expected {
			AssertEqual("left_alt", _KeyCombinationTaken["alt_gr"])
			AssertFalse(KeyCombinationOwnsAltGrSuffix(!Passthrough, _KCT_Keys(["left_alt"])),
				"the opposite pass-through variant must stand down")
		}
	}
}

_KCT_AltGrSuffixAdmission() {
	for _, Hold in ["none", "shift", "ctrl+shift", "nav"]
		_KCT_AltGrSuffixMode(Hold, false)
	for _, Hold in ["alt_gr", "shift+alt_gr", "ctrl+alt_gr", "alt_gr+win"]
		_KCT_AltGrSuffixMode(Hold, true)
	_KCT_AltGrSuffixMode("none", false, "qwerty")
	_KCT_AltGrSuffixMode("none", false, "kana")
	_KCT_AltGrSuffixMode("none", false, "standard", false)
}
Test("key combinations: standard AltGr suffix chooses its actual pair hold owner (todo91-altgr-suffix)",
	_KCT_AltGrSuffixAdmission)

_KCT_AltGrSuffixRejectsFakeFirst() {
	SavedFamily := _TestSetAltGrFamily(false, true)
	try _KCT_With(Map("left_ctrl_then_alt_gr", "caps_word"), Map(), Inspect)
	finally _TestRestoreAltGrFamily(SavedFamily)
	Inspect() {
		AssertFalse(KeyCombinationOwnsAltGrSuffix(false, _KCT_Keys(["left_ctrl"])),
			"the fake LCtrl prefix cannot become the pair's first key")
		AssertFalse(KeyCombinationOwnsAltGrSuffix(true, _KCT_Keys(["left_ctrl"])))
		AssertFalse(_KeyCombinationTaken.Has("alt_gr"))
		AssertEqual("", KeyCombinationFireAltGrSuffix(false, _KCT_Ports([])),
			"an unclaimed AltGr suffix cannot retract or dispatch another press")
	}
}
Test("key combinations: native AltGr prefix does not supply an admitted first key (todo91-altgr-suffix)",
	_KCT_AltGrSuffixRejectsFakeFirst)

_KCT_AltGrSuffixReleaseDebt(Passthrough) {
	global _AHK_SendInput, _TapHoldKeyIsDown, _TH_SyntheticHeldKeys
	global _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys
	global _TH_OwnedModifiers, _TH_RetractedOwners, _TH_AltGrLCtrlOwners, _TH_AltGrPresses
	Saved := { Send: _AHK_SendInput, Probe: _TapHoldKeyIsDown,
		Held: _TH_SyntheticHeldKeys, Pending: _TH_SyntheticReleasePendingKeys,
		User: _TH_SyntheticUserHeldKeys, Owned: _TH_OwnedModifiers,
		Retracted: _TH_RetractedOwners, Ctrl: _TH_AltGrLCtrlOwners, Presses: _TH_AltGrPresses,
		Family: _TestSetAltGrFamily(false, true) }
	Wire := []
	_AHK_SendInput := (Keys) => Wire.Push(Keys)
	_TapHoldKeyIsDown := (Name, Mode) => Name == "SC01D" && Mode == "P"
	_TH_SyntheticHeldKeys := Map()
	_TH_SyntheticReleasePendingKeys := Map()
	_TH_SyntheticUserHeldKeys := Map()
	_TH_OwnedModifiers := Map()
	_TH_RetractedOwners := Map()
	_TH_AltGrLCtrlOwners := Map()
	_TH_AltGrPresses := Map()
	try _KCT_With(Map("left_alt_then_alt_gr", "caps_word"),
		Passthrough ? Map("left_alt_then_alt_gr", "alt_gr") : Map(), Run)
	finally {
		_AHK_SendInput := Saved.Send
		_TapHoldKeyIsDown := Saved.Probe
		_TH_SyntheticHeldKeys := Saved.Held
		_TH_SyntheticReleasePendingKeys := Saved.Pending
		_TH_SyntheticUserHeldKeys := Saved.User
		_TH_OwnedModifiers := Saved.Owned
		_TH_RetractedOwners := Saved.Retracted
		_TH_AltGrLCtrlOwners := Saved.Ctrl
		_TH_AltGrPresses := Saved.Presses
		_TestRestoreAltGrFamily(Saved.Family)
	}
	Run() {
		Effects := []
		Wait(*) {
			AssertTrue(KeyCombinationOwnsAltGrSuffix(Passthrough, _KCT_Keys(["left_alt"])))
			KeyCombinationFireAltGrSuffix(Passthrough, _KCT_Ports(Effects))
			AssertFalse(_TH_SyntheticHeldKeys.Has("LShift"),
				"the fake LCtrl's remapped Shift must be released before the pair effect")
			AssertEqual(Passthrough, _TH_AltGrLCtrlOwners.Has("left_ctrl"),
				"only the native AltGr pair keeps an explicit Ctrl release debt")
			return true
		}
		Owner := TapHoldOwnImmediateModifier("left_ctrl", "SC01D", "LShift", 0.2,
			Wait, (*) => false, (*) => 1000, , , (*) => "")
		AssertFalse(Owner["tap"], "the fake LCtrl cannot dispatch its own configured tap")
		AssertTrue(Owner["released"], "the original LCtrl owner closes the retained release debt")
		Expected := ["{LShift Down}", "{LShift Up}"]
		if Passthrough {
			Expected.Push("{LCtrl Down}")
			Expected.Push("{LCtrl Up}")
		}
		AssertEqual(Expected.Length, Wire.Length, "one release per actual synthetic modifier")
		for Idx, Value in Expected
			AssertEqual(Value, Wire[Idx], "independent wire edge " . Idx)
		AssertEqual("take:left_alt", Effects[1])
		AssertEqual(Passthrough ? "modifier:alt_gr:RAlt" : "tap:left_alt>alt_gr:caps_word", Effects[2])
		AssertEqual(0, _TH_SyntheticHeldKeys.Count + _TH_SyntheticReleasePendingKeys.Count)
		AssertEqual(0, _TH_RetractedOwners.Count + _TH_AltGrLCtrlOwners.Count + _TH_OwnedModifiers.Count)
	}
}
Test("key combinations: suppressed AltGr pair returns the fake Ctrl owner before action (todo91-altgr-suffix)",
	() => _KCT_AltGrSuffixReleaseDebt(false))
Test("key combinations: native AltGr pair retains and closes its Ctrl release debt (todo91-altgr-suffix)",
	() => _KCT_AltGrSuffixReleaseDebt(true))

_KCT_AltGrSuffixStaticVariants() {
	Src := _DriverSourceNoComments()
	for _, Pass in ["false", "true"] {
		Label := Pass == "true" ? "~SC01D & ~SC138" : "~SC01D & SC138"
		Expected := "#HotIf not LayerEnabled and KeyCombinationOwnsAltGrSuffix(" . Pass . ")`n"
			. Label . ":: KeyCombinationFireAltGrSuffix(" . Pass . ")`n"
		Assert(InStr(Src, Expected) > 0, "the actual static custom variant wires " . Pass . " admission to the same owner")
	}
	global _KeyCombinationKeysByScanName
	SavedScanIndex := _KeyCombinationKeysByScanName
	_KeyCombinationKeysByScanName := Map("SC138", "alt_gr", "SC01D", "left_ctrl")
	try AssertEqual("alt_gr", KeyCombinationKeyOfHotkey("~SC01D & ~SC138"),
		"a custom suffix spells the second key rather than the fake prefix")
	finally _KeyCombinationKeysByScanName := SavedScanIndex
	Body := _DriverFuncBody("_KeyCombinationAltGrSuffixPorts")
	Assert(Body != "", "the native suffix modifier owner must exist")
	Assert(InStr(Body, "KS_AltGrKeyName()") > 0,
		"native pair modifier ownership must exempt the already passed physical AltGr member")
}
Test("key combinations: custom AltGr variants are registered before the standalone owner (todo91-altgr-suffix)",
	_KCT_AltGrSuffixStaticVariants)


_KCT_AltGrChildDone(Capture, Code, Stdout, Stderr) {
	Capture["count"] += 1
	Capture["exit"] := Code
	Capture["stdout"] := Stdout
	Capture["stderr"] := Stderr
}

_KCT_AltGrNativePriority() {
	Root := A_Temp . "\ergopti-kct-hook-" . DllCall("GetCurrentProcessId", "uint")
		. "-" . A_TickCount . "-" . Random(100000, 999999)
	AssertTrue(DllCall("CreateDirectoryW", "str", Root, "ptr", 0, "int"),
		"the parent must exclusively own native hook evidence")
	Probe := A_ScriptDir . "\fixtures\key_combination_altgr_suffix_probe.ahk"
	Nonce := "suffix-" . Random(100000, 999999) . "-" . A_TickCount
	CleanupDebt := false
	Passed := false
	try {
		for _, Mode in ["candidate", "bypass"] {
			Receipt := Root . "\" . Mode . ".txt"
			Capture := Map("count", 0, "exit", -1, "stdout", "", "stderr", "", "cleanup", "")
			ObservationGeneration := Random(100000, 999999999)
			ObservationNote := " [observation unavailable=1]"
			Arguments := ["/ErrorStdOut", Probe, Receipt, Nonce, Mode, ObservationGeneration . ""]
			RefusedArguments := Arguments.Clone()
			RefusedArguments[6] := ObservationGeneration
			AssertEqual("Argument 6 must be a string.", ShellRunner_ValidateSpawnArgs(A_AhkPath, RefusedArguments)["error"],
				"the original numeric observation generation must refuse native process acquisition")
			AssertEqual("", ShellRunner_ValidateSpawnArgs(A_AhkPath, Arguments)["error"],
				"the same generation must cross the native argv boundary as text")
			Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, Arguments,
				_KCT_AltGrChildDone.Bind(Capture))
			ObservationLease := _KCT_ObservationOpen(Receipt . ".observation")
			ReleaseObservationLease := _KCT_ObservationOpen(Receipt . ".release-observation")
			Cleaned := false
			ChildPid := 0
			try {
				AssertTrue(Handle.start(), "an owned interpreted hook child must start")
				ChildPid := Handle.processId()
				Assert(ChildPid > 0, "the actual adopted native child identity must be captured before finalization")
				Started := A_TickCount
				while Capture["count"] == 0 && TickElapsed(Started) < 7000 {
					_SR_TreePoll()
					Sleep(10)
				}
			} finally {
				ObservationNote := _KCT_ObservationRead(ObservationLease, ChildPid, Nonce, Mode, ObservationGeneration)
				ReleaseObservationNote := _KCT_ObservationRead(ReleaseObservationLease, ChildPid, Nonce, Mode, ObservationGeneration)
				ObservationNote .= StrReplace(ReleaseObservationNote, "[observation ", "[release observation ")
				try Cleaned := Handle.terminate()
				catch Error as Err
					Capture["cleanup"] := Err.Message
				if !_KCT_ObservationClose(ObservationLease)
					CleanupDebt := true
				if !_KCT_ObservationClose(ReleaseObservationLease)
					CleanupDebt := true
				if !Cleaned
					CleanupDebt := true
				FileAppend("exit=" . Capture["exit"] . " completions=" . Capture["count"]
					. " pid=" . ChildPid . " closed=" . Cleaned . "`n"
					. Capture["stdout"] . "`n" . Capture["stderr"] . "`n" . Capture["cleanup"],
					Root . "\" . Mode . "-diagnostics.txt", "UTF-8-RAW")
			}
			AssertTrue(Cleaned, "native child cleanup debt retains evidence at " . Root)
			AssertEqual(1, Capture["count"], "one exact native child completion; evidence=" . Root . ObservationNote)
			AssertEqual(0, Capture["exit"], Capture["stdout"] . "`n" . Capture["stderr"] . "`nevidence=" . Root)
			Lines := StrSplit(Trim(FileRead(Receipt, "UTF-8-RAW"), "`n"), "`n")
			AssertEqual(4, Lines.Length, "one fresh native identity and three controlled injected-hook observations")
			Identity := StrSplit(Lines[1], "|")
			AssertEqual(6, Identity.Length)
			AssertEqual(Nonce, Identity[1], "the child receipt must belong to this invocation")
			AssertEqual(ChildPid, Integer(Identity[2]), "the receipt must match the actual owned native process identity")
			Assert(Integer(Identity[3]) > 0 && Integer(Identity[4]) > 0, "the child records its admitted HWND/thread")
			AssertEqual("04090409", Identity[5], "this is controlled existing-US-layout registration priority")
			AssertEqual("injected-registration", Identity[6], "injected events cannot claim physical AltGr evidence")
			Expected := Mode == "candidate"
				? ["suppress|1|0|0|0|0", "native|0|1|0|0|0", "fallback|0|0|0|1|0"]
				: ["suppress|0|0|0|1|0", "native|0|0|0|1|0", "fallback|0|0|0|1|0"]
			for Idx, Value in Expected
				AssertEqual(Value, Lines[Idx + 1], Mode . ": independent native variant observation " . Idx)
		}
		Passed := true
	} finally {
		if Passed && !CleanupDebt
			DirDelete(Root, true)
	}
}
Test("key combinations: interpreted native hook selects the earlier custom AltGr owner with bypass control (todo91-altgr-suffix)",
	_KCT_AltGrNativePriority, true)


; End of shared authored cohort definitions.


/** Holds one exclusively created diagnostic file; omitting delete-sharing pins its identity. */
_KCT_ObservationOpen(KctPath) {
	KctLease := {Handle: 0}
	try {
		KctNative := DllCall("CreateFileW", "Str", KctPath, "UInt", 0xC0000000,
			"UInt", 3, "Ptr", 0, "UInt", 1, "UInt", 0x00200080, "Ptr", 0, "Ptr")
		if KctNative && KctNative != -1
			KctLease.Handle := KctNative
	} catch Any {
		KctLease.Handle := 0
	}
	return KctLease
}

/** Releases only the retained exact file handle; refusal retains cleanup debt. */
_KCT_ObservationClose(KctLease) {
	if !KctLease.Handle
		return true
	try {
		if !DllCall("CloseHandle", "Ptr", KctLease.Handle, "Int")
			return false
	} catch Any {
		return false
	}
	KctLease.Handle := 0
	return true
}

/** Reads at most 32 KiB from the held handle, requiring stable single-link file identity. */
_KCT_ObservationRead(KctLease, KctPid, KctNonce, KctMode, KctGeneration) {
	if !KctLease.Handle
		return " [observation unavailable=1]"
	try {
		KctBefore := Buffer(52, 0)
		KctAfter := Buffer(52, 0)
		if !DllCall("GetFileInformationByHandle", "Ptr", KctLease.Handle, "Ptr", KctBefore, "Int")
			|| NumGet(KctBefore, 0, "UInt") & 0x400 || NumGet(KctBefore, 40, "UInt") != 1
			return " [observation identity_refused=1]"
		KctBytes := NumGet(KctBefore, 32, "UInt") * 0x100000000 + NumGet(KctBefore, 36, "UInt")
		if KctBytes < 1 || KctBytes > 32768
			return " [observation bounds_refused=1]"
		if !DllCall("SetFilePointerEx", "Ptr", KctLease.Handle, "Int64", 0, "Ptr", 0, "UInt", 0, "Int")
			return " [observation read_refused=1]"
		KctData := Buffer(KctBytes + 1, 0)
		KctRead := 0
		if !DllCall("ReadFile", "Ptr", KctLease.Handle, "Ptr", KctData, "UInt", KctBytes,
			"UInt*", &KctRead, "Ptr", 0, "Int") || KctRead != KctBytes
			return " [observation read_refused=1]"
		if !DllCall("GetFileInformationByHandle", "Ptr", KctLease.Handle, "Ptr", KctAfter, "Int")
			return " [observation stability_refused=1]"
		for KctOffset in [0, 20, 24, 28, 32, 36, 40, 44, 48] {
			if NumGet(KctBefore, KctOffset, "UInt") != NumGet(KctAfter, KctOffset, "UInt")
				return " [observation stability_refused=1]"
		}
		Loop KctRead {
			KctByte := NumGet(KctData, A_Index - 1, "UChar")
			if (KctByte < 32 && KctByte != 10 && KctByte != 13) || KctByte > 126
				return " [observation invalid=1]"
		}
		return _KCT_ObservationFacts(StrGet(KctData, KctRead, "UTF-8"), KctPid, KctNonce, KctMode, KctGeneration)
	} catch Any {
		return " [observation read_refused=1]"
	}
}

/** Untrusted observation rows produce only closed scalar facts, never their text. */
_KCT_ObservationFacts(KctText, KctPid, KctNonce, KctMode, KctGeneration) {
	KctInvalid := " [observation invalid=1]"
	if !(KctText is String) || StrLen(KctText) < 1 || StrLen(KctText) > 32768
		|| SubStr(KctText, -1) != "`n" || !RegExMatch(KctText, "^[ -~`r`n]+$")
		return KctInvalid
	if !(KctPid is Integer) || KctPid <= 0 || KctPid > 0xFFFFFFFF || !(KctGeneration is Integer) || KctGeneration <= 0 || KctGeneration > 999999999
		|| !(KctNonce is String) || !RegExMatch(KctNonce, "^[A-Za-z0-9-]{1,64}$")
		|| (!(KctMode == "candidate") && !(KctMode == "bypass"))
		return KctInvalid
	KctRows := StrSplit(KctText, "`n")
	KctRows.Pop()
	if KctRows.Length < 1 || KctRows.Length > 128
		return KctInvalid
	KctThread := 0
	for KctIndex, KctRow in KctRows {
		if SubStr(KctRow, -1) == "`r"
			KctRow := SubStr(KctRow, 1, -1)
		KctFields := StrSplit(KctRow, "|")
		if KctFields.Length != 13 || !(KctFields[1] == KctNonce)
			return KctInvalid
		for KctColumn in [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12] {
			if !RegExMatch(KctFields[KctColumn], "^[0-9]{1,10}$")
				return KctInvalid
			KctFields[KctColumn] := Integer(KctFields[KctColumn])
		}
		if !RegExMatch(KctFields[13], "^(?:-1|[0-9]{1,10})$")
			return KctInvalid
		KctFields[13] := Integer(KctFields[13])
		if KctFields[2] != KctPid || KctFields[3] <= 0 || KctFields[3] > 0xFFFFFFFF || (KctThread && KctFields[3] != KctThread)
			|| KctFields[4] != KctGeneration || KctFields[5] != (KctMode == "candidate" ? 1 : 2)
			|| KctFields[6] != KctIndex || KctFields[7] < 1 || KctFields[7] > 16
			|| KctFields[8] > 3 || KctFields[9] > 2 || KctFields[10] > 8 || KctFields[11] > 3
			|| KctFields[12] > 65535 || KctFields[13] > 0xFFFFFFFF
			|| (!KctFields[11] && KctFields[12]) || (KctFields[11] && !KctFields[12])
			|| (KctFields[7] != 14 && KctFields[13] != -1)
			|| (KctFields[7] == 14 && KctIndex == 1)
			|| ((KctFields[7] != 15 && KctFields[7] != 16) && (KctFields[10] || KctFields[11] || KctFields[12]))
			return KctInvalid
		KctThread := KctFields[3]
	}
	return Format(" [observation records={1},phase={2},scenario={3},owned={4},error={5},source={6},line={7},exit={8}]",
		KctRows.Length, KctFields[7], KctFields[8], KctFields[9], KctFields[10], KctFields[11], KctFields[12], KctFields[13])
}
