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
; 3. The per-key delay picker uses one typed physical TOML leaf owner inside
;    the existing transaction. Existing Boolean spelling, future records and
;    comments remain user data; hand-edited thresholds also survive writes.
; 4. The layer comes with its key: an absent layers.toml binds no key, so the
;    first-run wizard's import of a key whose recommended hold enters the
;    navigation layer, and the Tap-Holds « Restore recommended values », also
;    create layers.toml from Ergopti's recommended layer in the same
;    transition. An existing layers.toml is the user's and is never replaced.
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

/**
 * Persists a known physical key's threshold through the existing transaction owner.
 * @param {String} KeyId Shared physical-key identifier.
 * @param {Number} Seconds Positive finite threshold within the runtime limit.
 * @returns {Integer|Boolean} Strict1 after publication, or false after refusal.
 */
WriteTapHoldDuration(KeyId, Seconds, WriterFn := 0, ReplaceFn := 0,
		DeleteFn := 0, AuthorizeFn := 0, ExpectedSource := 0) {
	global ConfigurationFile
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return WriteTapHoldDuration(KeyId, Seconds, WriterFn, ReplaceFn,
			DeleteFn, AuthorizeFn, ExpectedSource)
		finally Critical(InheritedCritical)
	}
	if !(KeyId is String) || !_TH_DurationValueValid(Seconds) {
		try LoggerError("TapHoldWriter", "Refusing an invalid tap-hold duration update.")
		return false
	}
	if !_TH_DurationKeyKnown(KeyId) {
		try LoggerError("TapHoldWriter", "Refusing duration for unknown physical key '{1}'.", KeyId)
		return false
	}
	return _TH_CommitTapHoldMutation("duration",
		_TH_BuildDurationCandidate.Bind(KeyId, Seconds),
		WriterFn, ReplaceFn, DeleteFn, AuthorizeFn,
		_TH_BuildDurationContent.Bind(KeyId, Seconds, ExpectedSource, ConfigurationFile))
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

_TH_DurationValueValid(Seconds) {
	global TAPHOLD_MAX_ACTIVATION_SECONDS
	if !((Seconds is Integer) || (Seconds is Float))
		return false
	if Seconds is Float {
		try {
			if !DllCall("msvcrt\_finite", "double", Seconds, "cdecl int")
				return false
		} catch {
			return false
		}
	}
	return Seconds > 0 && Seconds <= TAPHOLD_MAX_ACTIVATION_SECONDS
}

_TH_DurationKeyKnown(KeyId) {
	if !(KeyId is String)
		return false
	for KeyDef in TapHoldKeyDefs() {
		if KeyDef["id"] == KeyId
			return true
	}
	return false
}

; A duration edit owns one semantic leaf. Its physical source remains authority
; for every other record, including Boolean spelling and future namespaces.
_TH_CaptureDurationSource(Path) {
	Present := FileExist(Path) ? 1 : 0
	Source := Present ? FSReadUtf8Exact(Path) : ""
	if !(Source is String)
		return false
	return Map("path", Path, "source_present", Present, "source_content", Source)
}

_TH_DurationSourceValid(Source, Path) {
	return (Source is Map) && Source.Has("path") && (Source["path"] is String)
		&& Source["path"] == Path && Source.Has("source_present")
		&& (Source["source_present"] is Integer)
		&& (Source["source_present"] == 0 || Source["source_present"] == 1)
		&& Source.Has("source_content") && (Source["source_content"] is String)
}

_TH_DurationSourceMatches(Source, Path) {
	return _TH_DurationSourceValid(Source, Path)
		&& (!Source.Has("key") || _TH_DurationContextMatches(Source))
		&& _TOML_WriteSourceMatches(Path, Source["source_present"], Source["source_content"])
		&& (!Source.Has("key") || _TH_DurationContextMatches(Source))
}

_TH_CaptureDurationContext(Source, KeyId) {
	global TapHold, ConfigurationFile
	if !(Source is Map) || !(TapHold is Map)
		return false
	Desired := MasterGateDesiredTapHold(TapHold)
	if !(Desired is Map) || !Desired.Has("keys") || !(Desired["keys"] is Map)
		return false
	Keys := Desired["keys"]
	Entry := Keys.Get(KeyId, 0)
	if Keys.Has(KeyId) && !(Entry is Map)
		return false
	Source["master_path"] := ConfigurationFile
	Source["state"] := TapHold
	Source["desired"] := Desired
	Source["keys"] := Keys
	Source["key"] := KeyId
	Source["entry"] := Entry
	Source["entry_snapshot"] := _TH_CloneData(Entry)
	return Source
}

_TH_DurationContextMatches(Source) {
	global TapHold, ConfigurationFile
	try {
		if !(ConfigurationFile == Source["master_path"])
			return false
		if !(TapHold is Map) || ObjPtr(TapHold) != ObjPtr(Source["state"])
			return false
		Desired := MasterGateDesiredTapHold(TapHold)
		if !(Desired is Map) || ObjPtr(Desired) != ObjPtr(Source["desired"])
				|| !Desired.Has("keys") || !(Desired["keys"] is Map)
				|| ObjPtr(Desired["keys"]) != ObjPtr(Source["keys"])
			return false
		Entry := Desired["keys"].Get(Source["key"], 0)
		if Source["entry"] is Map {
			return (Entry is Map) && ObjPtr(Entry) == ObjPtr(Source["entry"])
				&& TOML_SameValue(Entry, Source["entry_snapshot"])
		}
		return !Desired["keys"].Has(Source["key"])
	} catch {
		return false
	}
}

; Called only while the existing commit owns the master and physical target.
_TH_BuildDurationContent(KeyId, Seconds, ExpectedSource, ExpectedMasterPath, Path, Data) {
	global ConfigurationFile
	if !(ConfigurationFile == ExpectedMasterPath)
		return false
	if ExpectedSource is Map {
		if !ExpectedSource.Has("key") || !(ExpectedSource["key"] == KeyId)
				|| !_TH_DurationSourceMatches(ExpectedSource, Path)
			return false
		Source := ExpectedSource.Clone()
		Source["receipt_target"] := ExpectedSource
	} else {
		if !(ExpectedSource is Integer) || ExpectedSource != 0
			return false
		Source := _TH_CaptureDurationContext(Map("path", Path), KeyId)
		Physical := _TH_CaptureDurationSource(Path)
		if !(Source is Map) || !(Physical is Map)
			return false
		Source["source_present"] := Physical["source_present"]
		Source["source_content"] := Physical["source_content"]
	}
	if !(ConfigurationFile == ExpectedMasterPath)
		return false
	if !_TH_DurationSourceValid(Source, Path)
		return false
	if Source["source_present"] {
		Source["content"] := _TH_DurationLeafImage(Source["source_content"], KeyId, Seconds)
	} else {
		; There is no physical file to retain. Preserve every modeled key so a
		; first write cannot discard its taps/holds when the loader restarts.
		Source["content"] := _TH_DurationInitialImage(Data)
	}
	return Source
}

_TH_DurationInitialImage(Data) {
	if !(Data is Map) || !Data.Has("keys") || !(Data["keys"] is Map)
		throw ValueError("Duration persistence needs a complete detached keys model")
	Kinds := TapHoldFieldKinds()
	InheritDefaults := Data.Get("inherit_defaults", false)
	if !(InheritDefaults is Integer) || (InheritDefaults != 0 && InheritDefaults != 1)
		throw ValueError("The inheritance flag needs strict Boolean intent")
	Content := Chr(0xFEFF) . "[tap_hold]`n"
	Content .= "inherit_defaults = " . TOML_RenderValue(TOML_Bool(InheritDefaults)) . "`n"
	for KeyId, Entry in Data["keys"] {
		if !(KeyId is String) || !(Entry is Map)
			throw ValueError("Duration persistence cannot serialize an invalid key model")
		Content .= "`n[tap_hold.keys." . TOML_RenderKey(KeyId) . "]`n"
		for Field, Value in Entry {
			if !(Field is String)
				throw ValueError("Duration persistence cannot serialize a non-string field")
			if Kinds.Get(Field, "") == "boolean" {
				if !(Value is Integer) || (Value != 0 && Value != 1)
					throw ValueError("A known Boolean field needs strict Boolean intent")
				Value := TOML_Bool(Value)
			}
			Content .= TOML_RenderKey(Field) . " = " . TOML_RenderValue(Value) . "`n"
		}
	}
	TOML_ParseDocument(Content)
	return Content
}

_TH_DurationLeafImage(Source, KeyId, Seconds) {
	Section := "tap_hold.keys." . TOML_RenderKey(KeyId)
	Admitted := TOML_BuildConfigDocumentCandidate(Source,
		[{ Section: Section, Key: "time_activation_seconds", Value: Seconds }], [])
	if !(Admitted is Map) || !Admitted.Has("content") || !(Admitted["content"] is String)
		throw ValueError("The semantic TOML owner refused the duration image")
	return Admitted["content"]
}

_TH_DurationWasPublished(KeyId, Seconds) {
	global TapHold
	try {
		Desired := MasterGateDesiredTapHold(TapHold)
		return (TapHold is Map) && (Desired is Map) && Desired.Has("keys")
			&& (Desired["keys"] is Map) && Desired["keys"].Has(KeyId)
			&& (Desired["keys"][KeyId] is Map)
			&& Desired["keys"][KeyId].Has("time_activation_seconds")
			&& _TH_DurationValueValid(Desired["keys"][KeyId]["time_activation_seconds"])
			&& Desired["keys"][KeyId]["time_activation_seconds"] == Seconds
	} catch {
		return false
	}
}

_TH_DurationReceiptMatches(Source, Path, KeyId, Seconds, PhysicalMatchFn := 0) {
	try {
		if !((PhysicalMatchFn is Integer) && PhysicalMatchFn == 0)
				&& !HasMethod(PhysicalMatchFn, "Call")
			return false
		if !(Source is Map) || !Source.Has("key") || !(Source["key"] == KeyId)
				|| !Source.Has("path") || !(Source["path"] == Path)
				|| !Source.Has("published_context") || !(Source["published_context"] is Map)
			return false
		Receipt := Source["published_context"]
		if !_TH_DurationSourceValid(Receipt, Path) || !(Receipt["key"] == KeyId)
				|| !_TH_DurationContextMatches(Receipt) || !_TH_DurationWasPublished(KeyId, Seconds)
				|| !Receipt.Has("physical") || !(Receipt["physical"] is Integer)
				|| (Receipt["physical"] != 0 && Receipt["physical"] != 1)
			return false
		if Receipt["physical"] {
			PhysicalMatched := HasMethod(PhysicalMatchFn, "Call")
				? PhysicalMatchFn.Call(Receipt, Path) : _TH_DurationSourceMatches(Receipt, Path)
			if !(PhysicalMatched is Integer) || PhysicalMatched != 1
				return false
		}
		; Physical admission may yield to another native thread. Repeat only the
		; pure exact-publication checks after that I/O, before granting Reload.
		return _TH_DurationContextMatches(Receipt) && _TH_DurationWasPublished(KeyId, Seconds)
	} catch {
		return false
	}
}

_TH_BuildDurationCandidate(KeyId, Seconds, Candidate) {
	if !_TH_CandidateEntry(Candidate, KeyId, &Entry)
		return false
	Entry["time_activation_seconds"] := Seconds
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
		ReplaceFn := 0, DeleteFn := 0, AuthorizeFn := 0, ContentFn := 0) {
	global TapHold, ConfigurationFile
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _TH_CommitTapHoldMutation(ActionName, BuildFn, WriterFn,
			ReplaceFn, DeleteFn, AuthorizeFn, ContentFn)
		finally Critical(InheritedCritical)
	}
	if !HasMethod(BuildFn, "Call") {
		try LoggerError("TapHoldWriter", "Refusing a tap-hold update with no candidate builder.")
		return false
	}
	for Adapter in [WriterFn, ReplaceFn, DeleteFn, AuthorizeFn, ContentFn] {
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
				AuthorizeFn, ContentFn)
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
		WriterFn := 0, ReplaceFn := 0, DeleteFn := 0, AuthorizeFn := 0, ContentFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _TH_WriteTapHoldToml(Data, OwnerToken, BoundPath,
			StartState, WriterFn, ReplaceFn, DeleteFn, AuthorizeFn, ContentFn)
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
	SourceWitness := 0
	if HasMethod(ContentFn, "Call") {
		try SourceWitness := ContentFn.Call(BoundPath, Data)
		catch as Err {
			try LoggerError("TapHoldWriter", "Preparing the duration image failed: {1}.", Err.Message)
			return false
		}
		if !_TH_DurationSourceValid(SourceWitness, BoundPath)
				|| !SourceWitness.Has("content") || !(SourceWitness["content"] is String)
				|| !_TH_DurationSourceMatches(SourceWitness, BoundPath)
			return false
		Content := SourceWitness["content"]
	} else {
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

	; The duration owner captured exact physical bytes before staging. A foreign
	; writer, create or delete cannot turn that image into authority over a successor.
	if SourceWitness is Map && !_TH_DurationSourceMatches(SourceWitness, BoundPath) {
		try LoggerError("TapHoldWriter", "The tap-hold source changed before duration publication.")
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
		if Published && (SourceWitness is Map) {
			global _TomlFileCache, _ParseTomlCache, _ConfigTomlSnapshots
			for Cache in [_TomlFileCache, _ParseTomlCache, _ConfigTomlSnapshots] {
				if Cache.Has(BoundPath)
					Cache.Delete(BoundPath)
			}
		}
		if Published && (SourceWitness is Map) && SourceWitness.Has("receipt_target") {
			Receipt := _TH_CaptureDurationContext(Map("path", BoundPath), SourceWitness["key"])
			if !(Receipt is Map) {
				Published := false
				PublishError := "The exact published duration owner could not be captured."
			} else {
				Receipt["physical"] := !HasMethod(WriterFn, "Call") && !HasMethod(ReplaceFn, "Call")
				Receipt["source_present"] := 1
				Receipt["source_content"] := Content
				SourceWitness["receipt_target"]["published_context"] := Receipt
			}
		}
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

/**
 * Publishes the tap-hold preset and its config master in one terminal transition.
 * Options "layers_config_dir" names the configuration folder whose layers.toml
 * a restore creates from the recommended layer when it has none; without it
 * no layer file is touched.
 */
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
	CandidateOptions["preset_owner"] := TapHoldScopeOwner(Path, Defaults, Mode,
		CandidateOptions.Get("layers_config_dir", ""))
	return ConfigScopeApply("tap_holds", Mode,
		Map("parameters", ConfigScopeActionParameterPaths), CandidateOptions)
}

; This bounded owner is the only preset admitted by ConfigScopeApply. Its target
; participates in the same WAL, backup verification and terminal compensation.
; A restore given the configuration folder also owns that folder's layers.toml:
; it is created from the recommended layer when absent, in the same cohort, and
; an existing one is returned unchanged, so no transition writes it.
class TapHoldScopeOwner {
	__New(Path, Defaults, Mode, LayersConfigDir := "") {
		global _SharedDir
		if !(Path is String) || Path == "" || !(Defaults is String) || Defaults == ""
			throw ValueError("Tap-hold scope requires explicit file paths.")
		if !(LayersConfigDir is String)
			throw ValueError("Tap-hold scope requires the layers folder as a path or an empty string.")
		this.path := Path
		this.paths := [Path]
		this.defaults := Defaults
		if !(Mode == "recommended" || Mode == "clear")
			throw ValueError("Unknown tap-hold preset operation.")
		this.mode := Mode
		this.layers := ""
		if (Mode == "recommended" && LayersConfigDir != "") {
			this.layers := KeymapLayers_UserFilePathFromVocabulary(_SharedDir, LayersConfigDir)
			this.paths.Push(this.layers)
		}
	}

	; The coordinator owns admission, backup, expected-old checks and publication.
	; This method only returns a detached candidate and cannot publish a file.
	Build() {
		global _SharedDir
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
		Candidates := [{ path: this.path, image: Image }]
		if (this.layers != "")
			Candidates.Push({ path: this.layers, image: TapHoldLayerImportImage(_SharedDir, this.layers) })
		return Candidates
	}
}





; ==========================================
; ==========================================
; ======= 6/ First-run wizard import =======
; ==========================================
; ==========================================

; The tap_hold.toml of the configuration folder whose config.toml is ConfigPath:
; both live in the driver's folder of the configuration directory.
; @param ConfigPath string A config.toml path.
; @returns {String}
TapHoldConfigPathBeside(ConfigPath) {
	SplitPath(ConfigPath, , &Folder)
	return Folder . "\tap_hold.toml"
}

; Whether a loaded or parsed TOML value is true.
; @param Value any
; @returns {Boolean}
_TH_TomlTrue(Value) => (Value is TOML_Bool) ? Value.Value : ((Value is Integer) && Value == 1)

; Same type and value; strings compare case-sensitively, TOML Booleans by value.
; @returns {Boolean}
_TH_SameValue(Left, Right) {
	if (Left is TOML_Bool) || (Right is TOML_Bool)
		return (Left is TOML_Bool) && (Right is TOML_Bool) && Left.Value == Right.Value
	return Type(Left) == Type(Right) && Left == Right
}

; Whether two key entries hold the same owned fields with the same values.
; @param Left Map
; @param Right Map
; @returns {Boolean}
_TH_SameOwnedFields(Left, Right) {
	Kinds := TapHoldFieldKinds()
	for Field in Kinds {
		if (Left.Has(Field) != Right.Has(Field))
			return false
		if Left.Has(Field) && !_TH_SameValue(Left[Field], Right[Field])
			return false
	}
	return true
}

; The owned fields of every [tap_hold.keys.<id>] section of a parsed file.
; @param Sections Map From TOML_ParseFreshFileTyped.
; @returns {Map} Key id -> Map of owned fields.
_TH_OwnedKeySections(Sections) {
	Kinds := TapHoldFieldKinds()
	Keys := Map()
	for Section, Fields in Sections {
		if !RegExMatch(Section, "^tap_hold\.keys\.([A-Za-z0-9_]+)$", &Match)
			continue
		Owned := Map()
		for Field, Value in Fields {
			if Kinds.Has(Field)
				Owned[Field] := Value
		}
		Keys[Match[1]] := Owned
	}
	return Keys
}

; The first-run wizard's view of a tap_hold.toml, read fresh from disk: each
; key the file configures (its owned fields, over the shipped preset when the
; file inherits it) is "recommended" when those fields are exactly the preset's
; and "customised" for any other setting. A key the file leaves to the keyboard
; is absent, so the wizard may import it; it never imports over another one.
; @param Path string A tap_hold.toml.
; @param Defaults string The shared defaults.toml holding the preset.
; @returns {Map|String} Key id -> state, or why the file could not be read.
TapHoldKeyReport(Path, Defaults) {
	if !FileExist(Path)
		return Map()
	Sections := TOML_ParseFreshFileTyped(Path, &DiscardedArrays)
	if TOML_ReadFailed(Path) || DiscardedArrays
		return "the tap-hold file '" . Path . "' could not be read"
	Preset := LoadTapHoldToml(Defaults)["keys"]
	Keys := Map()
	Root := Sections.Get("tap_hold", Map())
	if Root.Has("inherit_defaults") && _TH_TomlTrue(Root["inherit_defaults"]) {
		for KeyId, Fields in Preset
			Keys[KeyId] := _TH_CloneData(Fields)
	}
	for KeyId, Fields in _TH_OwnedKeySections(Sections) {
		if !Keys.Has(KeyId)
			Keys[KeyId] := Map()
		; A modifier hold and a layer hold exclude each other, as in the loader.
		if Fields.Has("hold_modifier") && Keys[KeyId].Has("hold_layer")
			Keys[KeyId].Delete("hold_layer")
		if Fields.Has("hold_layer") && Keys[KeyId].Has("hold_modifier")
			Keys[KeyId].Delete("hold_modifier")
		for Field, Value in Fields
			Keys[KeyId][Field] := Value
	}
	Report := Map()
	for KeyId, Fields in Keys {
		if (Fields.Count == 0)
			continue
		if Preset.Has(KeyId) && _TH_SameOwnedFields(Fields, Preset[KeyId])
			Report[KeyId] := "recommended"
		else
			Report[KeyId] := "customised"
	}
	return Report
}

; Backs up the tap_hold.toml a wizard import replaces, as a configuration scope
; backs up its files, and verifies the copy.
; @param Path string The tap_hold.toml.
; @param Image Map Its rendered import, from TapHoldImportImage.
; @returns {String} The backup path, "" for a file the import creates.
; Throws when the backup cannot be made and verified.
TapHoldImportBackup(Path, Image) {
	if !Image["source_present"]
		return ""
	Backup := ConfigUnusedKeysBackupPath(Path, FormatTime(A_Now, "yyyyMMdd-HHmmss") . "-" . A_TickCount)
	Written := FSWriteCreateDurable(Backup, Image["source_content"])
	if !(Written is Integer) || Written != 1 || !FSUtf8ExactMatches(Backup, Image["source_content"])
		throw Error("The tap-hold file '" . Path . "' could not be backed up.")
	return Backup
}

; Renders the first-run wizard's Tap-Holds answer into a tap_hold.toml image
; without publishing it: each key named takes exactly the shipped preset's
; fields and nothing else in the file changes, so a key the user left
; unchecked keeps whatever it had. It only adds keys: a key holding the user's
; own setting refuses the whole import. The wizard publishes the image in its
; own configuration transition, beside the config.toml whose category switch
; turns the Tap-Holds on.
; @param Path string The tap_hold.toml of the folder being set up.
; @param Defaults string The shared defaults.toml holding the preset.
; @param KeyIds Array Key ids of this driver's catalogue column, at least one.
; @returns {Map} The rendered image of TOML_BuildUpdatedContent.
; Throws when a key has no recommendation or a source cannot be read.
TapHoldImportImage(Path, Defaults, KeyIds) {
	if !(Path is String) || Path == "" || !(Defaults is String) || Defaults == ""
			|| !(KeyIds is Array) || KeyIds.Length == 0
		throw ValueError("The tap-hold import requires its file, the preset and at least one key.")
	if !FileExist(Defaults)
		throw Error("The canonical tap-hold preset is missing.")
	Preset := LoadTapHoldToml(Defaults)
	if TOML_UnreadableFile(Defaults) || Preset["keys"].Count == 0
		throw Error("The canonical tap-hold preset is unreadable or empty.")
	Present := FileExist(Path) ? 1 : 0
	Existing := Present ? TOML_ParseFreshFile(Path) : Map()
	Report := TapHoldKeyReport(Path, Defaults)
	if (Report is String)
		throw Error(Report)
	Kinds := TapHoldFieldKinds()
	Rows := []
	Imported := Map()
	for KeyId in KeyIds {
		if !(KeyId is String) || !Preset["keys"].Has(KeyId)
			throw ValueError("The shipped preset recommends nothing for tap-hold key '" . String(KeyId) . "'.")
		if Imported.Has(KeyId)
			throw ValueError("Tap-hold key '" . KeyId . "' is imported twice.")
		if (Report.Get(KeyId, "") == "customised")
			throw ValueError("Tap-hold key '" . KeyId . "' holds the user's own setting.")
		Imported[KeyId] := true
		Section := "tap_hold.keys." . KeyId
		if Existing.Has(Section) {
			for Field in Existing[Section] {
				if Kinds.Has(Field)
					Rows.Push({ Section: Section, Key: Field, Delete: true })
			}
		}
		for Field, Value in Preset["keys"][KeyId] {
			if !Kinds.Has(Field)
				throw Error("The canonical tap-hold preset contains an unknown field.")
			Serialized := Kinds[Field] == "boolean" ? TOML_Bool(Value) : Value
			Rows.Push({ Section: Section, Key: Field, Value: Serialized })
		}
	}
	Image := TOML_BuildUpdatedContent(Path, Rows)
	if !(Image is Map) || Image.Get("status", "") != "ok" || Image.Get("kind", "") != "rendered"
			|| Image["source_present"] != Present
		throw Error("The tap-hold file '" . Path . "' could not be read or rendered.")
	return Image
}





; ===============================================
; ===============================================
; ======= 7/ Recommended navigation layer =======
; ===============================================
; ===============================================

; Reads Ergopti's recommended layer file (_shared/keymap/layers.recommended.toml):
; its exact bytes and the one layer it binds, the layer a recommended key's
; hold_layer names.
; @param SharedDir string The _shared folder.
; @returns {Map} Map("text", String, "layer_id", String).
; Throws when the shipped file is missing, empty or does not bind one layer.
TapHoldRecommendedLayer(SharedDir) {
	Path := RTrim(SharedDir, "\/") . "\keymap\layers.recommended.toml"
	Text := FSReadUtf8Exact(Path)
	if !(Text is String) || Text == ""
		throw Error("The recommended navigation layer '" . Path . "' cannot be read.")
	LayerIds := Map()
	Pos := 1
	while (Pos := RegExMatch(Text, "m)^\[layers\.([a-z][a-z0-9_]*)\.", &Found, Pos)) {
		LayerIds[Found[1]] := true
		Pos += Found.Len
	}
	if (LayerIds.Count != 1)
		throw Error("The recommended navigation layer '" . Path . "' must bind exactly one layer.")
	for LayerId in LayerIds
		return Map("text", Text, "layer_id", LayerId)
}

; Whether the shipped recommendation of one of the keys holds the layer.
; @param Defaults string The shared defaults.toml holding the preset.
; @param KeyIds Array Key ids of this driver's catalogue column.
; @param LayerId string The layer the recommended layer file binds.
; @returns {Boolean}
TapHoldPresetEntersLayer(Defaults, KeyIds, LayerId) {
	Preset := LoadTapHoldToml(Defaults)
	for KeyId in KeyIds {
		if (KeyId is String) && Preset["keys"].Has(KeyId)
				&& Preset["keys"][KeyId].Get("hold_layer", "") == LayerId
			return true
	}
	return false
}

; The image that brings Ergopti's recommended layer into a configuration
; folder, in TOML_BuildUpdatedContent's shape: the preset's bytes over an
; absent layers.toml. An existing layers.toml is the user's: its image is
; unchanged (content equals source), so no transition writes it.
; @param SharedDir string The _shared folder.
; @param LayersPath string The user's layers.toml.
; @returns {Map}
; Throws when the shipped layer file cannot be read.
TapHoldLayerImportImage(SharedDir, LayersPath) {
	if FileExist(LayersPath) {
		Source := FSReadUtf8Exact(LayersPath)
		if !(Source is String)
			Source := ""
		return Map("status", "ok", "kind", "rendered", "source_present", 1,
			"source_content", Source, "content", Source)
	}
	return Map("status", "ok", "kind", "rendered", "source_present", 0,
		"source_content", "", "content", TapHoldRecommendedLayer(SharedDir)["text"])
}





; ================================================
; ================================================
; ======= 7/ The layer a hold brings along =======
; ================================================
; ================================================

; The hold picker's write: the layer a key's hold enters comes with the key.
; A layer that binds no key only lights CapsLock while it is held, so a key
; set to hold the navigation layer in a folder with no layers.toml typed
; capitals and read as Shift.
; @param KeyId string The key whose hold is set.
; @param HoldOpt Map One hold option (kind, id).
; @param LayersConfigDir string The configuration folder whose layers.toml the
;   layer needs; "" touches no layer file.
; @param WriteFn Func The key writer; injectable for tests.
; @returns {Integer} 1 when the key is written, false otherwise.
TapHoldSetHold(KeyId, HoldOpt, LayersConfigDir, WriteFn := WriteTapHoldHold) {
	if !(HoldOpt is Map) || !HoldOpt.Has("kind") || !HoldOpt.Has("id") || !(LayersConfigDir is String) {
		try LoggerError("TapHoldWriter", "Refusing an invalid tap-hold hold update.")
		return false
	}
	Import := TapHoldHoldLayerImport(HoldOpt, LayersConfigDir)
	if !(Import is Map)
		return false
	Written := WriteFn.Call(KeyId, HoldOpt)
	if (Written is Integer) && Written == 1
		return 1
	TapHoldHoldLayerImportUndo(Import)
	return false
}

; Creates the configuration folder's layers.toml from Ergopti's recommended
; layer when a hold option enters that layer and the folder has none. An
; existing file is the user's and is kept as it is; a hold that does not enter
; that layer, or no folder, brings nothing.
; @param HoldOpt Map One hold option (kind, id).
; @param LayersConfigDir string The configuration folder; "" brings nothing.
; @returns {Map|Integer} Map("path", String, "created", Boolean, "content",
;   String), or false when the absent file could not be created.
TapHoldHoldLayerImport(HoldOpt, LayersConfigDir) {
	global _SharedDir
	Import := Map("path", "", "created", false, "content", "")
	if (LayersConfigDir == "" || !(HoldOpt["kind"] == "layer"))
		return Import
	try {
		Preset := TapHoldRecommendedLayer(_SharedDir)
		if !(HoldOpt["id"] == Preset["layer_id"])
			return Import
		Path := KeymapLayers_UserFilePathFromVocabulary(_SharedDir, LayersConfigDir)
	} catch as Err {
		try LoggerError("TapHoldWriter",
			"The recommended navigation layer cannot be read: {1}. The hold was not changed.", Err.Message)
		return false
	}
	Import["path"] := Path
	if FileExist(Path)
		return Import
	Owner := _ConfigWriteLeaseTryAcquire(Path, "nav-layer-import")
	if !(Owner is Object) {
		try LoggerError("TapHoldWriter",
			"Cannot create '{1}': another configuration transaction owns it. The hold was not changed.", Path)
		return false
	}
	Created := false
	try Created := FSWriteCreateDurable(Path, Preset["text"])
	finally Released := _ConfigWriteLeaseRelease(Owner)
	if !(Released is Integer) || Released != 1 {
		try LoggerError("TapHoldWriter",
			"The owner of '{1}' could not be released; later configuration changes may be refused.", Path)
	}
	if !(Created is Integer) || Created != 1 {
		; CREATE_NEW refuses a file that appeared since the probe: it is the user's.
		if FileExist(Path)
			return Import
		try LoggerError("TapHoldWriter",
			"The recommended navigation layer could not be written to '{1}'. The hold was not changed.", Path)
		return false
	}
	Import["created"] := true
	Import["content"] := Preset["text"]
	try LoggerInfo("TapHoldWriter", "Recommended navigation layer imported into '{1}'.", Path)
	return Import
}

; Removes the layers.toml TapHoldHoldLayerImport created, while it still holds
; the recommended layer's exact bytes. A kept file, or one edited since, stays.
; @param Import Map What TapHoldHoldLayerImport returned.
; @returns {Boolean} True when no file of the import's own is left.
TapHoldHoldLayerImportUndo(Import) {
	if !(Import is Map) || !Import["created"]
		return true
	Path := Import["path"]
	if !FileExist(Path) || !FSUtf8ExactMatches(Path, Import["content"])
		return true
	Deleted := false
	try Deleted := FSDeleteStrict(Path)
	if (Deleted is Integer) && Deleted == 1
		return true
	try LoggerError("TapHoldWriter",
		"The navigation layer '{1}' a refused hold change created could not be removed.", Path)
	return false
}
