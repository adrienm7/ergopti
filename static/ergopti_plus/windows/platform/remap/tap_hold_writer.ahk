; platform/remap/tap_hold_writer.ahk

; ==============================================================================
; MODULE: Tap-Hold Writer
; DESCRIPTION:
; Persists user tray-menu choices for tap/hold configuration to the v2
; ``tap_hold.toml`` file. The new architecture gives each physical key two
; independent selectors — tap (any action from GESTURE_ACTIONS) and hold
; (modifier or nav layer) — mirroring the macOS Karabiner menu design.
;
; FEATURES & RATIONALE:
; 1. Per-key tap + hold pickers: every key exposes a free tap selector
;    (drawing from the full GESTURE_ACTIONS registry) and a hold selector
;    (fixed set of modifiers and the nav layer). No more pre-baked variant
;    tuples — the user composes the pair themselves.
; 2. Single source of truth for key order, hold options, and i18n keys —
;    all defined here and consumed by the tray-menu builder.
; 3. Preserves per-key ``time_activation_seconds`` already in TapHold —
;    the tray menu does not expose this, but hand-editing tap_hold.toml is
;    supported and survives writes.
; ==============================================================================





; ===========================
; ===========================
; ======= 1/ Key defs =======
; ===========================
; ===========================

; Ordered list of physical keys exposed in the tap-hold tray submenu.
; Each entry: Map("id" => v2_key_id, "i18n" => label_i18n_key,
;                 "hand" => "left"|"right").
;
; Built from the shared key catalogue, the ``ahk`` column of [tap_hold.catalog]
; in _shared/tap_hold/defaults.toml, in catalogue order. It was a hardcoded
; array here whose comment said it mirrored a menu-manifest
; ``tap_hold_keys_catalog`` that never existed, while the macOS and Linux trays
; kept lists of their own. Those read the same table through
; _shared/lua/tap_hold/key_catalog.lua, and
; tools/test/test-tap-hold-key-catalog-single-source.cjs holds each column to
; the keys its engine arms.
global _TH_KeyDefs := _TH_BuildKeyDefs()

; Reads this driver's column of the shared key catalogue. An entry that names
; no hand or no label is a broken catalogue: it is logged as an ERROR and left
; out, so the tray never shows a guessed hand.
; @returns {Array} One Map per Windows key, in catalogue order.
_TH_BuildKeyDefs() {
	global _SharedDir
	Out := []
	Path := _SharedDir . "\tap_hold\defaults.toml"
	Sections := ParseTomlFile(Path)
	Catalog := Sections.Has("tap_hold.catalog") ? Sections["tap_hold.catalog"] : Map()
	Keys := Catalog.Has("keys") ? Catalog["keys"] : ""
	if !(Keys is Array) || Keys.Length == 0 {
		try LoggerError("TapHoldWriter", "'{1}' declares no [tap_hold.catalog] keys — the Tap-Hold submenu has no key rows.", Path)
		return Out
	}
	for Index, Entry in Keys {
		if !(Entry is Map) || !Entry.Has("id") || !Entry.Has("hand") || !Entry.Has("label_key") {
			try LoggerError("TapHoldWriter", "[tap_hold.catalog] keys[{1}] needs an id, a hand and a label_key — left out.", Index)
			continue
		}
		Hand := Entry["hand"]
		if (Hand != "left" && Hand != "right") {
			try LoggerError("TapHoldWriter", "[tap_hold.catalog] key '{1}' has hand '{2}', not left or right — left out.", Entry["id"], Hand)
			continue
		}
		if !Entry.Has("ahk")
			continue
		Out.Push(Map("id", Entry["ahk"], "i18n", Entry["label_key"], "hand", Hand))
	}
	return Out
}

; Ordered hold options — value stored as hold_modifier or hold_layer in TOML.
; Each entry: Map("id" => storage_value, "kind" => "modifier"|"layer"|"none",
;                 "i18n" => label_i18n_key).
;
; The ids come from _shared/tap_hold/defaults.toml's [tap_hold.hold_picker].
; They were a hardcoded array here until 2026-08-08, under a comment claiming it
; "mirrors _shared/modules/menu/menu_manifest.json hold_options" — a key that has
; never existed in that file. So the canonical list was a copy pointing at
; nothing, and the two Lua drivers offered no hold picker at all. They read the
; same table now through _shared/lua/tap_hold/hold_options.lua, and
; tools/test/test-tap-hold-hold-options-parity.cjs holds the two enumerations
; together.
global _TH_HoldOptions := _TH_BuildHoldOptions()

; Reads one array from [tap_hold.hold_picker] in the shared defaults.
; Returns an empty array when the file or the key is unreadable — the caller
; logs and falls back, because a hold picker with no options is a menu that
; cannot be diagnosed from the outside.
_TH_ReadHoldPickerArray(FieldName) {
	global _SharedDir
	Out := []
	Path := _SharedDir . "\tap_hold\defaults.toml"
	Content := ""
	try Content := ReadTomlFile(Path)
	if (Content == "") {
		try LoggerError("TapHoldWriter", "Cannot read '{1}' — the hold picker has no {2}.", Path, FieldName)
		return Out
	}
	InSection := false
	loop parse, Content, "`n", "`r" {
		Line := Trim(A_LoopField)
		if (SubStr(Line, 1, 1) == "[") {
			InSection := (Line == "[tap_hold.hold_picker]")
			continue
		}
		if !InSection or (Line == "") or (SubStr(Line, 1, 1) == "#") {
			continue
		}
		if RegExMatch(Line, "^" . FieldName . "\s*=\s*\[(.*)\]", &M) {
			; Quotes stripped with Chr() rather than a regex class: AHK v2 escapes a
			; double quote with a BACKTICK, so a backslash-escaped one inside a
			; string is not an escape at all — it ends the literal early and leaves
			; the rest of the line as code. The brace-balance meta test caught
			; exactly that, four braces out.
			DQ := Chr(34)
			SQ := Chr(39)
			loop parse, M[1], "," {
				Item := Trim(A_LoopField)
				Item := Trim(Item, DQ . SQ)
				if (Item != "") {
					Out.Push(Item)
				}
			}
			return Out
		}
	}
	try LoggerError("TapHoldWriter", "[tap_hold.hold_picker] declares no '{1}' — the hold picker is short.", FieldName)
	return Out
}

; Build the menu hold options once at startup: native-key sentinel, all
; modifier combinations, then one entry per declared layer.
_TH_BuildHoldOptions() {
	Options := []
	Options.Push(Map("id", "", "kind", "none", "i18n", "tap_hold.hold.none"))

	ModifierCombos := []
	_TH_EnumerateHoldModifierCombos("", 1, _TH_ReadHoldPickerArray("modifiers"), ModifierCombos)
	for _, ComboId in ModifierCombos {
		Options.Push(Map("id", ComboId, "kind", "modifier", "i18n", ""))
	}

	for _, LayerId in _TH_ReadHoldPickerArray("layers") {
		Options.Push(Map("id", LayerId, "kind", "layer", "i18n", "tap_hold.hold." . LayerId . "_layer"))
	}
	return Options
}

; Recursively enumerate all non-empty combinations of the shared modifier ids with
; deterministic order: single modifiers first, then longer ordered combinations.
_TH_EnumerateHoldModifierCombos(Prefix, StartIndex, Modifiers, Out) {
	Loop Modifiers.Length {
		if (A_Index < StartIndex)
			continue
		ComboId := Prefix == "" ? Modifiers[A_Index] : (Prefix . "+" . Modifiers[A_Index])
		Out.Push(ComboId)
		_TH_EnumerateHoldModifierCombos(ComboId, A_Index + 1, Modifiers, Out)
	}
}

; i18n key for the "nothing / disable" tap action sentinel.
global _TH_TapNoneI18n := "tap_hold.tap.none"





; ==========================================
; ==========================================
; ======= 2/ Public accessor helpers =======
; ==========================================
; ==========================================

; Return the ordered key-definition array.
TapHoldKeyDefs() {
	global _TH_KeyDefs
	return _TH_KeyDefs
}

; Return the key definitions of one hand ("left" or "right"), in order.
TapHoldKeyDefsOfHand(Hand) {
	global _TH_KeyDefs
	Out := []
	for _, KeyDef in _TH_KeyDefs {
		if (KeyDef["hand"] == Hand)
			Out.Push(KeyDef)
	}
	return Out
}

; Return the ordered hold-option array.
TapHoldHoldOptions() {
	global _TH_HoldOptions
	return _TH_HoldOptions
}

; Return the i18n-resolved short label for the current tap action of a key.
; Falls back to _GestureActionLabel() so the gesture-action locale chain is
; the single source of truth for action names.
TapHoldCurrentTapLabel(KeyId) {
	global TapHold, _TH_TapNoneI18n
	TapAction := TapHoldTapAction(MasterGateDesiredTapHold(TapHold), KeyId)
	if (TapAction == "") {
		return t(_TH_TapNoneI18n)
	}
	return GestureActionDisplayLabel(TapAction, GestureBindingId("tap_hold", KeyId))
}

; Return the i18n-resolved short label for the current hold option of a key.
TapHoldCurrentHoldLabel(KeyId) {
	global TapHold, _TH_HoldOptions
	HoldMod   := TapHoldHoldModifier(MasterGateDesiredTapHold(TapHold), KeyId)
	HoldLayer := TapHoldHoldLayer(MasterGateDesiredTapHold(TapHold), KeyId)
	for _, Opt in _TH_HoldOptions {
		if (Opt["kind"] == "modifier" and Opt["id"] == HoldMod) {
			return _TH_HoldOptionLabel(HoldMod)
		}
		if (Opt["kind"] == "layer" and Opt["id"] == HoldLayer) {
			return t(Opt["i18n"])
		}
		if (Opt["kind"] == "none" and HoldMod == "" and HoldLayer == "") {
			return t(Opt["i18n"])
		}
	}
	return HoldMod != "" ? HoldMod : (HoldLayer != "" ? HoldLayer : t(_TH_HoldOptions[1]["i18n"]))
}

; Human label for a hold modifier identifier.
; Built from base i18n keys when possible, then joined with ' + '.
_TH_HoldOptionLabel(HoldId) {
	if (HoldId == "") {
		return t("tap_hold.hold.none")
	}
	Parts := StrSplit(HoldId, "+")
	Out := []
	for _, Part in Parts {
		Clean := Trim(Part)
		if (Clean == "") {
			continue
		}
		Label := t("tap_hold.hold." . Clean)
		if (InStr(Label, "tap_hold.hold.") > 0) {
			Label := Clean
		}
		Out.Push(Label)
	}
	if (Out.Length == 0) {
		return t("tap_hold.hold.none")
	}
	Result := ""
	for Index, Label in Out {
		Result .= (Index = 1 ? "" : " + ") . Label
	}
	return Result
}

; Return true when the tap action for a key matches the given action id.
IsTapHoldTapActive(KeyId, ActionId) {
	global TapHold
	if !IsSet(TapHold) {
		return false
	}
	Current := TapHoldTapAction(MasterGateDesiredTapHold(TapHold), KeyId)
	if (ActionId == "") {
		return (Current == "")
	}
	return (Current == ActionId)
}

; Return true when the hold option for a key matches the given hold option entry.
IsTapHoldHoldActive(KeyId, HoldOpt) {
	global TapHold
	if !IsSet(TapHold) {
		return false
	}
	HoldMod   := TapHoldHoldModifier(MasterGateDesiredTapHold(TapHold), KeyId)
	HoldLayer := TapHoldHoldLayer(MasterGateDesiredTapHold(TapHold), KeyId)
	Kind := HoldOpt["kind"]
	Id   := HoldOpt["id"]
	if (Kind == "none") {
		return (HoldMod == "" and HoldLayer == "")
	}
	if (Kind == "modifier") {
		return (HoldMod == Id)
	}
	if (Kind == "layer") {
		return (HoldLayer == Id)
	}
	return false
}





; =============================
; =============================
; ======= 3/ Tap writer =======
; =============================
; =============================

; Apply a new tap action for a key directly to TapHold + tap_hold.toml.
; ``ActionId`` is a GESTURE_ACTIONS id string, or "" to force native passthrough
; while still persisting an explicit per-key override (so shipped defaults do not
; leak back on reload).
WriteTapHoldTap(KeyId, ActionId, WriterFn := 0, ReplaceFn := 0,
		DeleteFn := 0, AuthorizeFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return WriteTapHoldTap(KeyId, ActionId, WriterFn, ReplaceFn,
			DeleteFn, AuthorizeFn)
		finally Critical(InheritedCritical)
	}
	if !(KeyId is String) || KeyId == "" || !(ActionId is String) {
		try LoggerError("TapHoldWriter", "Refusing an invalid tap-hold tap update.")
		return false
	}
	if !GestureActionIsAssignable(ActionId, true) {
		try LoggerError("TapHoldWriter",
			"Refusing unknown tap-hold action '{1}' for key '{2}'.", ActionId, KeyId)
		return false
	}
	try LoggerDebug("TapHoldWriter",
		"WriteTapHoldTap requested: key='{1}', action='{2}'.",
		KeyId, ActionId == "" ? "<native>" : ActionId)
	return _TH_CommitTapHoldMutation("tap",
		_TH_BuildTapCandidate.Bind(KeyId, ActionId),
		WriterFn, ReplaceFn, DeleteFn, AuthorizeFn)
}

; Apply a new hold option for a key directly to TapHold + tap_hold.toml.
; ``HoldOpt`` is one entry from ``_TH_HoldOptions``.
WriteTapHoldHold(KeyId, HoldOpt, WriterFn := 0, ReplaceFn := 0,
		DeleteFn := 0, AuthorizeFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return WriteTapHoldHold(KeyId, HoldOpt, WriterFn, ReplaceFn,
			DeleteFn, AuthorizeFn)
		finally Critical(InheritedCritical)
	}
	if !(KeyId is String) || KeyId == "" || !(HoldOpt is Map)
			|| !HoldOpt.Has("kind") || !HoldOpt.Has("id")
			|| !(HoldOpt["kind"] is String) || !(HoldOpt["id"] is String) {
		try LoggerError("TapHoldWriter", "Refusing an invalid tap-hold hold update.")
		return false
	}
	Kind := HoldOpt["kind"]
	Id := HoldOpt["id"]
	if (Kind != "modifier" && Kind != "layer" && Kind != "none")
			|| (Kind == "none" && Id != "") {
		try LoggerError("TapHoldWriter",
			"Refusing unknown hold option kind='{1}', id='{2}'.", Kind, Id)
		return false
	}
	try LoggerDebug("TapHoldWriter",
		"WriteTapHoldHold requested: key='{1}', kind='{2}', id='{3}'.",
		KeyId, Kind, Id)
	return _TH_CommitTapHoldMutation("hold",
		_TH_BuildHoldCandidate.Bind(KeyId, Kind, Id),
		WriterFn, ReplaceFn, DeleteFn, AuthorizeFn)
}

; Atomically switch one key back to native tap + no hold.  The tray's Disable
; action used to call WriteTapHoldTap then WriteTapHoldHold, which could persist
; only the first half if the second write failed.
WriteTapHoldNative(KeyId, WriterFn := 0, ReplaceFn := 0,
		DeleteFn := 0, AuthorizeFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return WriteTapHoldNative(KeyId, WriterFn, ReplaceFn,
			DeleteFn, AuthorizeFn)
		finally Critical(InheritedCritical)
	}
	if !(KeyId is String) || KeyId == "" {
		try LoggerError("TapHoldWriter", "Refusing an invalid native tap-hold update.")
		return false
	}
	return _TH_CommitTapHoldMutation("native",
		_TH_BuildNativeCandidate.Bind(KeyId),
		WriterFn, ReplaceFn, DeleteFn, AuthorizeFn)
}





; =======================================
; =======================================
; ======= 4/ tap_hold.toml writer =======
; =======================================
; =======================================

; Standalone tray action: persist first, then publish. Without
; ``inherit_defaults = false`` the loader would re-merge shipped defaults on
; the next reload, undoing « Tout désactiver ».
_TH_WriteTapHoldDisabled(WriterFn := 0, ReplaceFn := 0,
		DeleteFn := 0, AuthorizeFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _TH_WriteTapHoldDisabled(WriterFn, ReplaceFn,
			DeleteFn, AuthorizeFn)
		finally Critical(InheritedCritical)
	}
	Result := _TH_CommitTapHoldMutation("disable-all",
		_TH_BuildDisabledCandidate,
		WriterFn, ReplaceFn, DeleteFn, AuthorizeFn)
	if (Result is Integer) && Result == 1
		try LoggerInfo("TapHoldWriter", "All tap-hold mappings disabled and persisted.")
	return Result
}

; Resolve the exact physical target before acquiring its global configuration
; owner. A path relocation cannot redirect a transaction after its snapshot.
_TH_TapHoldConfigPath() {
	global _ConfigDir, _AhkSubDir
	if !IsSet(_ConfigDir) || !IsSet(_AhkSubDir)
			|| !(_ConfigDir is String) || _ConfigDir == ""
			|| !(_AhkSubDir is String)
		return false
	return _ConfigDir . _AhkSubDir . "tap_hold.toml"
}

; Return one mutable per-key entry from a detached candidate.
_TH_CandidateEntry(Candidate, KeyId, &EntryOut) {
	if !(Candidate is Map) || !(KeyId is String) || KeyId == ""
		return false
	if !Candidate.Has("keys")
		Candidate["keys"] := Map()
	if !(Candidate["keys"] is Map)
		return false
	if !Candidate["keys"].Has(KeyId)
		Candidate["keys"][KeyId] := Map()
	if !(Candidate["keys"][KeyId] is Map)
		return false
	EntryOut := Candidate["keys"][KeyId]
	return 1
}

_TH_BuildTapCandidate(KeyId, ActionId, Candidate) {
	if !_TH_CandidateEntry(Candidate, KeyId, &Entry)
		return false
	Entry["tap_action"] := ActionId
	return 1
}

_TH_BuildHoldCandidate(KeyId, Kind, Id, Candidate) {
	if !_TH_CandidateEntry(Candidate, KeyId, &Entry)
		return false
	if Entry.Has("hold_modifier")
		Entry.Delete("hold_modifier")
	if Entry.Has("hold_layer")
		Entry.Delete("hold_layer")
	if (Kind == "modifier")
		Entry["hold_modifier"] := Id
	else if (Kind == "layer")
		Entry["hold_layer"] := Id
	else if (Kind == "none")
		Entry["hold_modifier"] := ""
	else
		return false
	return 1
}

_TH_BuildNativeCandidate(KeyId, Candidate) {
	if !_TH_CandidateEntry(Candidate, KeyId, &Entry)
		return false
	Entry["tap_action"] := ""
	if Entry.Has("hold_modifier")
		Entry.Delete("hold_modifier")
	if Entry.Has("hold_layer")
		Entry.Delete("hold_layer")
	return 1
}

_TH_BuildDisabledCandidate(Candidate) {
	if !(Candidate is Map)
		return false
	Candidate["keys"] := Map()
	Candidate["inherit_defaults"] := false
	return 1
}

; Re-check every revocable fact after the complete stage exists. The optional
; callback is a deterministic test seam; its success is sampled strictly and
; all real authorities are checked again after it returns.
_TH_AuthorizeTapHoldCommit(OwnerToken, BoundPath, StartState,
		AuthorizeFn := 0) {
	global TapHold
	if !_ConfigWriteLeaseOwns(OwnerToken, BoundPath)
		return false
	CurrentPath := _TH_TapHoldConfigPath()
	if !(CurrentPath is String)
			|| _ConfigWriteLeaseKey(CurrentPath)
				!= _ConfigWriteLeaseKey(BoundPath)
		return false
	if !(TapHold is Map) || !(StartState is Map)
			|| ObjPtr(TapHold) != ObjPtr(StartState)
		return false
	if HasMethod(AuthorizeFn, "Call") {
		Result := AuthorizeFn.Call()
		if !(Result is Integer) || Result != 1
			return false
		if !_ConfigWriteLeaseOwns(OwnerToken, BoundPath)
			return false
		CurrentPath := _TH_TapHoldConfigPath()
		if !(CurrentPath is String)
				|| _ConfigWriteLeaseKey(CurrentPath)
					!= _ConfigWriteLeaseKey(BoundPath)
			return false
		if !(TapHold is Map) || !(StartState is Map)
				|| ObjPtr(TapHold) != ObjPtr(StartState)
			return false
	}
	return 1
}

; Publish only the detached candidate. The caller invokes this helper inside a
; short Critical span after the durable atomic replacement has completed.
_TH_PublishTapHoldCandidate(Candidate, RuntimeCandidate, EmptyKeys, OwnerToken, BoundPath, StartState) {
	global TapHold
	if !_TH_AuthorizeTapHoldCommit(OwnerToken, BoundPath, StartState)
		return false
	if MasterGateState()["initialized"] {
		if !IsCategoryGated("TapHolds")
			RuntimeCandidate["keys"] := EmptyKeys
		MasterGateState()["tap_hold"] := Candidate
	}
	TapHold := RuntimeCandidate
	return 1
}

; Acquire the global config admission gate before cloning live state. A
; terminal relocation/reload refuses this lease process-wide, and a re-entrant
; tap-hold writer on the same path cannot build from a stale snapshot.
_TH_CommitTapHoldMutation(ActionName, BuildFn, WriterFn := 0,
		ReplaceFn := 0, DeleteFn := 0, AuthorizeFn := 0) {
	global TapHold, ConfigurationFile
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _TH_CommitTapHoldMutation(ActionName, BuildFn, WriterFn,
			ReplaceFn, DeleteFn, AuthorizeFn)
		finally Critical(InheritedCritical)
	}
	if !HasMethod(BuildFn, "Call") {
		try LoggerError("TapHoldWriter", "Refusing a tap-hold update with no candidate builder.")
		return false
	}
	for Adapter in [WriterFn, ReplaceFn, DeleteFn, AuthorizeFn] {
		if !((Adapter is Integer) && Adapter == 0)
				&& !HasMethod(Adapter, "Call") {
			try LoggerError("TapHoldWriter", "Refusing a tap-hold update with an invalid transaction adapter.")
			return false
		}
	}
	if !(TapHold is Map) {
		try LoggerError("TapHoldWriter", "TapHold state is unavailable; the change was not persisted.")
		return false
	}
	BoundPath := _TH_TapHoldConfigPath()
	if !(BoundPath is String) || BoundPath == "" {
		try LoggerError("TapHoldWriter", "The tap-hold target path is unavailable; the change was not persisted.")
		return false
	}
	; The master lives in config.toml. Both files share admission before either
	; captures desired state, so a master projection cannot overwrite a newer edit.
	MasterOwner := _ConfigWriteLeaseTryAcquire(ConfigurationFile, "tap-hold-master")
	if !(MasterOwner is Object) {
		try LoggerError("TapHoldWriter", "Cannot edit tap-holds during another configuration transaction.")
		return false
	}
	OwnerToken := _ConfigWriteLeaseTryAcquire(BoundPath,
		"tap-hold-" . ActionName)
	if !(OwnerToken is Object) {
		if !_ConfigWriteLeaseRelease(MasterOwner)
			throw Error("The rejected tap-hold master owner could not be released.")
		try LoggerError("TapHoldWriter",
			"Cannot persist tap-hold change '{1}': another configuration transaction is in progress.",
			ActionName)
		return false
	}
	Result := false
	Released := false
	try {
		BuildError := ""
		Built := false
		try {
			StartState := TapHold
			Candidate := _TH_CloneData(MasterGateDesiredTapHold(StartState))
			Built := BuildFn.Call(Candidate)
		} catch as Err {
			BuildError := Err.Message
		}
		if (BuildError != "") {
			try LoggerError("TapHoldWriter",
				"Building tap-hold change '{1}' failed: {2}.",
				ActionName, BuildError)
		} else if !(Built is Integer) || Built != 1 {
			try LoggerError("TapHoldWriter",
				"Building tap-hold change '{1}' was refused.", ActionName)
		} else {
			PersistError := ""
			try Result := _TH_WriteTapHoldToml(Candidate, OwnerToken,
				BoundPath, StartState, WriterFn, ReplaceFn, DeleteFn,
				AuthorizeFn)
			catch as Err {
				Result := false
				PersistError := Err.Message
			}
			if (PersistError != "")
				try LoggerError("TapHoldWriter",
					"Persisting tap-hold change '{1}' failed: {2}.",
					ActionName, PersistError)
		}
	} finally {
		Released := _ConfigWriteLeaseRelease(OwnerToken)
		MasterReleased := _ConfigWriteLeaseRelease(MasterOwner)
	}
	if !(Released is Integer) || Released != 1 || !(MasterReleased is Integer) || MasterReleased != 1 {
		try LoggerError("TapHoldWriter",
			"The tap-hold write owner could not be released; later configuration changes may be refused.")
		return false
	}
	return (Result is Integer) && Result == 1 ? 1 : false
}

; Rewrite the captured tap_hold.toml target from one detached candidate. The
; caller owns BoundPath from before the snapshot through durable replacement
; and the final memory-only publication.
_TH_WriteTapHoldToml(Data, OwnerToken, BoundPath, StartState,
		WriterFn := 0, ReplaceFn := 0, DeleteFn := 0, AuthorizeFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _TH_WriteTapHoldToml(Data, OwnerToken, BoundPath,
			StartState, WriterFn, ReplaceFn, DeleteFn, AuthorizeFn)
		finally Critical(InheritedCritical)
	}
	if !(Data is Map) || !(BoundPath is String) || BoundPath == ""
			|| !_ConfigWriteLeaseOwns(OwnerToken, BoundPath) {
		try LoggerError("TapHoldWriter", "Refusing an incomplete tap-hold persistence transaction.")
		return false
	}
	if (Data.Has("keys") && !(Data["keys"] is Map)) {
		try LoggerError("TapHoldWriter",
			"Refusing malformed tap-hold state; keys must be a Map.")
		return false
	}
	; Refuse to rebuild a file the loader could not READ. Everything below is
	; serialized from the in-memory map, and when the load saw nothing that map
	; is the shipped defaults overlay — byte-for-byte what a user who customised
	; nothing produces. Rewriting from it erases their per-key overrides and
	; their explicit disable-all opt-out, and
	; every caller here re-publishes TapHold only on a true return, so refusing
	; leaves memory and disk consistent.
	if TOML_UnreadableFile(BoundPath) {
		try LoggerError("TapHoldWriter", "Refusing to rewrite '{1}': it could not be read at load, so the in-memory tap-hold map holds the shipped defaults rather than the user's configuration. Restart the driver once the file is readable.", BoundPath)
		return false
	}
	try LoggerDebug("TapHoldWriter", "Persisting tap-hold config to '{1}' (keys={2}, inherit_defaults={3}).",
		BoundPath, Data.Has("keys") ? Data["keys"].Count : 0,
                Data.Has("inherit_defaults") ? (Data["inherit_defaults"] ? "true" : "false") : "unset")

	RuntimeCandidate := _TH_CloneData(Data)
	EmptyKeys := Map()
	Lines := []
	Lines.Push("# Auto-generated by Ergopti+ tray-menu writes: the whole file is rewritten")
	Lines.Push("# from the in-memory tap-hold state on every toggle. What a held layer does")
	Lines.Push("# is set in layers.toml, not here.")
	Lines.Push("")

	; Root [tap_hold] section — emit inherit_defaults when it is false so
	; the loader does not re-merge shipped defaults on the next reload.
        if Data.Has("inherit_defaults") and !Data["inherit_defaults"] {
		Lines.Push("[tap_hold]")
		Lines.Push("inherit_defaults = false")
		Lines.Push("")
	}

	; Keys section.
        if Data.Has("keys") {
                for KeyId, Entry in Data["keys"] {
			if !(IsObject(Entry) and Type(Entry) == "Map") {
				continue
			}
			Lines.Push("[tap_hold.keys." . KeyId . "]")
			for K, V in Entry {
				Lines.Push(_TH_TomlFormatLine(K, V))
			}
			Lines.Push("")
		}
	}

	Content := ""
	for L in Lines {
		Content .= L . "`r`n"
	}

	static WriteSequence := 0
	PreviousCritical := Critical("On")
	try LocalSequence := ++WriteSequence
	finally Critical(PreviousCritical)
	StagePath := BoundPath . "." . A_ScriptHwnd . "-" . LocalSequence . ".tmp"

	Written := false
	WriteError := ""
	try Written := HasMethod(WriterFn, "Call")
		? WriterFn.Call(StagePath, Content)
		: FSWriteDurable(StagePath, Content)
	catch as Err {
		Written := false
		WriteError := Err.Message
	}
	Written := (Written is Integer) && Written == 1
	if !Written {
		if (WriteError != "") {
			try LoggerError("TapHoldWriter",
				"Writing staging file for '{1}' failed: {2}. The previous contents are intact.",
				BoundPath, WriteError)
		} else {
			try LoggerError("TapHoldWriter",
				"Writing staging file for '{1}' was refused. The previous contents are intact.",
				BoundPath)
		}
		_TH_CleanupTapHoldStage(StagePath, DeleteFn)
		return false
	}

	Authorized := false
	AuthorizeError := ""
	PreviousCritical := Critical("On")
	try {
		try Authorized := _TH_AuthorizeTapHoldCommit(OwnerToken,
			BoundPath, StartState, AuthorizeFn)
		catch as Err {
			Authorized := false
			AuthorizeError := Err.Message
		}
		Authorized := (Authorized is Integer) && Authorized == 1
	} finally Critical(PreviousCritical)
	if !Authorized {
		if (AuthorizeError != "") {
			try LoggerError("TapHoldWriter",
				"Authorization before publishing '{1}' failed: {2}. The previous contents are intact.",
				BoundPath, AuthorizeError)
		} else {
			try LoggerError("TapHoldWriter",
				"Authorization before publishing '{1}' was refused. The previous contents are intact.",
				BoundPath)
		}
		_TH_CleanupTapHoldStage(StagePath, DeleteFn)
		return false
	}

	Replaced := false
	ReplaceError := ""
	try Replaced := HasMethod(ReplaceFn, "Call")
		? ReplaceFn.Call(StagePath, BoundPath)
		: FSAtomicMoveReplace(StagePath, BoundPath)
	catch as Err {
		Replaced := false
		ReplaceError := Err.Message
	}
	Replaced := (Replaced is Integer) && Replaced == 1
	if !Replaced {
		if (ReplaceError != "") {
			try LoggerError("TapHoldWriter",
				"Atomic replacement of '{1}' failed: {2}. The previous contents are intact.",
				BoundPath, ReplaceError)
		} else {
			try LoggerError("TapHoldWriter",
				"Atomic replacement of '{1}' was refused. The previous contents are intact.",
				BoundPath)
		}
		_TH_CleanupTapHoldStage(StagePath, DeleteFn)
		return false
	}

	Published := false
	PublishError := ""
	PreviousCritical := Critical("On")
	try {
		try Published := _TH_PublishTapHoldCandidate(Data, RuntimeCandidate, EmptyKeys, OwnerToken,
			BoundPath, StartState)
		catch as Err {
			Published := false
			PublishError := Err.Message
		}
		Published := (Published is Integer) && Published == 1
	} finally Critical(PreviousCritical)
	if !Published {
		if (PublishError != "") {
			try LoggerError("TapHoldWriter",
				"Tap-hold state became durable at '{1}', but live publication failed: {2}. Reload is required.",
				BoundPath, PublishError)
		} else {
			try LoggerError("TapHoldWriter",
				"Tap-hold state became durable at '{1}', but live publication was refused. Reload is required.",
				BoundPath)
		}
		return false
	}

	try LoggerDebug("TapHoldWriter", "tap_hold.toml rewritten ({1} key(s)).",
		Data.Has("keys") ? Data["keys"].Count : 0)
	return 1
}

; A private stage never owns user data until atomic replacement succeeds.
_TH_CleanupTapHoldStage(StagePath, DeleteFn := 0) {
	Deleted := false
	DeleteError := ""
	try Deleted := HasMethod(DeleteFn, "Call")
		? DeleteFn.Call(StagePath) : FSDeleteStrict(StagePath)
	catch as Err {
		Deleted := false
		DeleteError := Err.Message
	}
	Deleted := (Deleted is Integer) && Deleted == 1
	if Deleted
		return 1
	if (DeleteError != "") {
		try LoggerError("TapHoldWriter",
			"Could not remove rejected staging file '{1}': {2}.",
			StagePath, DeleteError)
	} else {
		try LoggerError("TapHoldWriter",
			"Could not remove rejected staging file '{1}': the delete adapter refused it.",
			StagePath)
	}
	return false
}

_TH_CloneData(Value) {
        if Value is Map {
                Copy := Map()
                for K, V in Value
                        Copy[K] := _TH_CloneData(V)
                return Copy
        }
        if Value is Array {
                Copy := []
                for _, V in Value
                        Copy.Push(_TH_CloneData(V))
                return Copy
        }
        return Value
}





; =========================================================================
; =========================================================================
; ======= 5/ Legacy compat stubs (no longer called by the new menu) =======
; =========================================================================
; =========================================================================

; No-op stub kept so that path_translator.ahk routing code does not crash
; if reached by a stale caller. The new tray menu uses WriteTapHoldTap and
; WriteTapHoldHold directly via callbacks; WriteTapHoldBatch is dead code.
WriteTapHoldBatch(BatchEntries) {
	try LoggerDebug("TapHoldWriter", "WriteTapHoldBatch called — no-op in new menu architecture.")
	return 0
}

; Format a single ``key = value`` line for tap_hold.toml. Handles strings
; (quoted), booleans, and numbers; arrays and nested tables are not used
; in this schema.
_TH_TomlFormatLine(Key, Value) {
	; Check numeric types first — integer 0 satisfies (Value = false) in AHK v2,
	; so the Type() guard must come before any boolean comparison
	if (Type(Value) == "Integer" or Type(Value) == "Float") {
		return Key . " = " . Value
	}
	if (Value == true) {
		return Key . " = true"
	}
	if (Value == false) {
		return Key . " = false"
	}
	; String — quote, escape backslashes and quotes.
	S := String(Value)
	S := StrReplace(S, "\", "\\")
	S := StrReplace(S, Chr(0x22), "\" . Chr(0x22))
	return Key . ' = "' . S . '"'
}

/** Publishes the tap-hold preset and its config master in one terminal transition. */
TapHoldScopeApply(Mode, Options := unset) {
	global TapHold, _SharedDir
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return TapHoldScopeApply(Mode, IsSet(Options) ? Options : Map())
		finally Critical(InheritedCritical)
	}
	if !IsSet(TapHold) || !(TapHold is Map)
		throw Error("Tap-hold scope requires initialized runtime state.")
	CandidateOptions := IsSet(Options) ? Options.Clone() : Map()
	Path := CandidateOptions.Get("tap_hold_path", _TH_TapHoldConfigPath())
	Defaults := CandidateOptions.Get("tap_hold_defaults", _SharedDir . "\tap_hold\defaults.toml")
	CandidateOptions["preset_owner"] := TapHoldScopeOwner(Path, Defaults, Mode)
	return ConfigScopeApply("tap_holds", Mode,
		Map("parameters", ConfigScopeActionParameterPaths), CandidateOptions)
}

; This bounded owner is the only preset admitted by ConfigScopeApply. Its target
; participates in the same WAL, backup verification and terminal compensation.
class TapHoldScopeOwner {
	__New(Path, Defaults, Mode) {
		if !(Path is String) || Path == "" || !(Defaults is String) || Defaults == ""
			throw ValueError("Tap-hold scope requires explicit file paths.")
		this.path := Path
		this.paths := [Path]
		this.defaults := Defaults
		if !(Mode == "recommended" || Mode == "clear")
			throw ValueError("Unknown tap-hold preset operation.")
		this.mode := Mode
	}

	; The coordinator owns admission, backup, expected-old checks and publication.
	; This method only returns a detached candidate and cannot publish a file.
	Build() {
		Present := FileExist(this.path) ? 1 : 0
		Source := Present ? FSReadUtf8Exact(this.path) : ""
		if !(Source is String)
			throw Error("The tap-hold source cannot be read.")
		Existing := Present ? TOML_ParseFreshFile(this.path) : Map()
		Kinds := TapHoldFieldKinds()
		Rows := [{ Section: "tap_hold", Key: "inherit_defaults", Delete: true }]
		for Section, Fields in Existing {
			if !RegExMatch(Section, "^tap_hold\.keys\.[A-Za-z0-9_]+$")
				continue
			for Field in Fields {
				if Kinds.Has(Field)
					Rows.Push({ Section: Section, Key: Field, Delete: true })
			}
		}
		if this.mode == "recommended" {
			if !FileExist(this.defaults)
				throw Error("The canonical tap-hold preset is missing.")
			Preset := LoadTapHoldToml(this.defaults)
			if TOML_UnreadableFile(this.defaults) || Preset["keys"].Count == 0
				throw Error("The canonical tap-hold preset is unreadable or empty.")
			for KeyId, Fields in Preset["keys"] {
				for Field, Value in Fields {
					if !Kinds.Has(Field)
						throw Error("The canonical tap-hold preset contains an unknown field.")
					Serialized := Kinds[Field] == "boolean" ? TOML_Bool(Value) : Value
					Rows.Push({ Section: "tap_hold.keys." . KeyId, Key: Field, Value: Serialized })
				}
			}
		}
		Image := TOML_BuildUpdatedContent(this.path, Rows)
		if !(Image is Map) || Image.Get("status", "") != "ok" || Image.Get("kind", "") != "rendered"
				|| Image["source_present"] != Present || !(Image["source_content"] == Source)
			throw Error("The tap-hold source changed or its scoped image could not be rendered.")
		return [{ path: this.path, image: Image }]
	}
}
