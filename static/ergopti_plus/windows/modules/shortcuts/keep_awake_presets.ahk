; modules/shortcuts/keep_awake_presets.ahk

; ==============================================================================
; MODULE: Anti-Sleep Presets (AutoHotkey port)
; DESCRIPTION:
; Port of _shared/shortcuts/engine/keep_awake_presets.lua: the presets of the
; anti-sleep mode (Ctrl+M), their edits and what Windows runs for the active
; one. modules/shortcuts/auto_click.ahk keeps the user's document through it.
;
; FEATURES & RATIONALE:
; 1. Same document and same refusals as the shared module: every edit
;    validates first and changes nothing on a refusal, which it returns as a
;    reason of the shared vocabulary.
; 2. A document is the decoded JSON: Maps and Arrays, booleans as 1 and 0.
;
; Pinned by _shared/tests/corpus/keep_awake/keep_awake_presets_vectors.json,
; which tests/unit/modules/shortcuts/test_keep_awake_presets.ahk replays.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================
; ==================================
; ======= 1/ Validation ============
; ==================================
; ==================================

; The OS names a preset's allowed apps are keyed by.
KeepAwakePresetsOses() {
	static Oses := ["macos", "windows", "linux"]
	return Oses
}

; A deep copy of decoded JSON.
KeepAwakePresetsCopy(Value) {
	if Value is Map {
		Out := Map()
		for Key, Item in Value
			Out[Key] := KeepAwakePresetsCopy(Item)
		return Out
	}
	if Value is Array {
		Out := []
		for Item in Value
			Out.Push(KeepAwakePresetsCopy(Item))
		return Out
	}
	return Value
}

_KeepAwakeValidId(Id) {
	return (Id is String) && StrLen(Id) <= 64 && RegExMatch(Id, "^[A-Za-z0-9_\-]+$")
}

_KeepAwakeIsBool(Value) {
	return (Value is Integer) && (Value = 0 || Value = 1)
}

_KeepAwakeField(MapValue, Key) {
	return (MapValue is Map) && MapValue.Has(Key) ? MapValue[Key] : ""
}

; Why a preset is invalid, or "" when it is valid.
KeepAwakePresetInvalid(Preset) {
	if !(Preset is Map) || !_KeepAwakeValidId(_KeepAwakeField(Preset, "id"))
		return "preset_invalid_id"
	if !(_KeepAwakeField(Preset, "name") is String && _KeepAwakeField(Preset, "name") != "")
		&& !(_KeepAwakeField(Preset, "name_key") is String && _KeepAwakeField(Preset, "name_key") != "")
		return "preset_invalid_name"
	if !_KeepAwakeIsBool(_KeepAwakeField(Preset, "keep_awake")) || !_KeepAwakeIsBool(_KeepAwakeField(Preset, "auto_click"))
		return "preset_invalid_switch"
	Apps := _KeepAwakeField(Preset, "allowed_apps")
	if !(Apps is Map)
		return "preset_invalid_apps"
	for OsName in KeepAwakePresetsOses() {
		if !Apps.Has(OsName) || !(Apps[OsName] is Array)
			return "preset_invalid_apps"
		for App in Apps[OsName] {
			if !(App is String) || App = ""
				return "preset_invalid_apps"
		}
	}
	Images := _KeepAwakeField(Preset, "images"), Texts := _KeepAwakeField(Preset, "texts")
	if !(Images is Array) || !(Texts is Array)
		return "preset_invalid_targets"
	Seen := Map()
	for Image in Images {
		Id := _KeepAwakeField(Image, "id"), ImageFile := _KeepAwakeField(Image, "file")
		Threshold := _KeepAwakeField(Image, "threshold")
		if !_KeepAwakeValidId(Id) || Seen.Has(Id) || !(ImageFile is String) || !RegExMatch(ImageFile, "^[A-Za-z0-9_\-]+\.png$")
			|| !_KeepAwakeIsBool(_KeepAwakeField(Image, "enabled"))
			|| (Image.Has("threshold") && (!IsNumber(Threshold) || Threshold <= 0 || Threshold > 1))
			return "preset_invalid_targets"
		Seen[Id] := true
	}
	for Text in Texts {
		Id := _KeepAwakeField(Text, "id"), Variants := _KeepAwakeField(Text, "variants")
		Distance := _KeepAwakeField(Text, "max_distance")
		if !_KeepAwakeValidId(Id) || Seen.Has(Id) || !(Variants is Array) || Variants.Length = 0
			|| !IsInteger(Distance) || Distance < 0 || !_KeepAwakeIsBool(_KeepAwakeField(Text, "enabled"))
			return "preset_invalid_targets"
		for Variant in Variants {
			if !(Variant is String) || Variant = ""
				return "preset_invalid_targets"
		}
		Seen[Id] := true
	}
	return ""
}

_KeepAwakeIndexOf(Doc, Id) {
	for Index, Preset in Doc["presets"] {
		if Preset["id"] == Id
			return Index
	}
	return 0
}




; ==================================
; ==================================
; ======= 2/ Document ==============
; ==================================
; ==================================

; The user's document, or a copy of the starters when Saved is "".
; @param Reason {VarRef} "presets_document_invalid" for a broken saved document.
; @returns {Map|String} The document, or "".
KeepAwakePresetsLoad(Starters, Saved, &Reason := "") {
	Reason := ""
	for Preset in Starters["presets"] {
		if KeepAwakePresetInvalid(Preset) != ""
			throw ValueError("A starter preset is invalid: " . Preset["id"])
	}
	if !IsObject(Saved)
		return Map("version", Starters["version"], "active", Starters["default_active"],
			"presets", KeepAwakePresetsCopy(Starters["presets"]))
	if !(Saved is Map) || _KeepAwakeField(Saved, "version") != Starters["version"]
		|| !(_KeepAwakeField(Saved, "presets") is Array) || Saved["presets"].Length = 0 {
		Reason := "presets_document_invalid"
		return ""
	}
	Seen := Map()
	for Preset in Saved["presets"] {
		if KeepAwakePresetInvalid(Preset) != "" || Seen.Has(Preset["id"]) {
			Reason := "presets_document_invalid"
			return ""
		}
		Seen[Preset["id"]] := true
	}
	Doc := KeepAwakePresetsCopy(Saved)
	if !Doc.Has("active") || !_KeepAwakeIndexOf(Doc, Doc["active"])
		Doc["active"] := Doc["presets"][1]["id"]
	return Doc
}

KeepAwakePresetsActive(Doc) {
	return Doc["presets"][_KeepAwakeIndexOf(Doc, Doc["active"])]
}

KeepAwakePresetsGet(Doc, Id) {
	Index := _KeepAwakeIndexOf(Doc, Id)
	return Index ? Doc["presets"][Index] : ""
}

; Each edit returns true, or false with its reason in Reason.
KeepAwakePresetsSetActive(Doc, Id, &Reason := "") {
	if !_KeepAwakeIndexOf(Doc, Id)
		return (Reason := "preset_unknown") && false
	Doc["active"] := Id
	return true
}

KeepAwakePresetsSetSwitch(Doc, Id, SwitchName, Value, &Reason := "") {
	Preset := KeepAwakePresetsGet(Doc, Id)
	if !IsObject(Preset)
		return (Reason := "preset_unknown") && false
	if (SwitchName != "keep_awake" && SwitchName != "auto_click") || !_KeepAwakeIsBool(Value)
		return (Reason := "preset_invalid_switch") && false
	Preset[SwitchName] := Value
	return true
}

KeepAwakePresetsDuplicate(Doc, Id, NewId, Name, &Reason := "") {
	Preset := KeepAwakePresetsGet(Doc, Id)
	if !IsObject(Preset)
		return (Reason := "preset_unknown") && false
	if !_KeepAwakeValidId(NewId)
		return (Reason := "preset_invalid_id") && false
	if _KeepAwakeIndexOf(Doc, NewId)
		return (Reason := "preset_id_taken") && false
	if !(Name is String) || Name = ""
		return (Reason := "preset_invalid_name") && false
	Clone := KeepAwakePresetsCopy(Preset)
	Clone["id"] := NewId, Clone["name"] := Name
	if Clone.Has("name_key")
		Clone.Delete("name_key")
	Doc["presets"].Push(Clone)
	return true
}

; Adds a preset (an imported one), validated first.
KeepAwakePresetsAdd(Doc, Preset, &Reason := "") {
	Reason := KeepAwakePresetInvalid(Preset)
	if Reason != ""
		return false
	if _KeepAwakeIndexOf(Doc, Preset["id"])
		return (Reason := "preset_id_taken") && false
	Doc["presets"].Push(KeepAwakePresetsCopy(Preset))
	return true
}

KeepAwakePresetsRename(Doc, Id, Name, &Reason := "") {
	Preset := KeepAwakePresetsGet(Doc, Id)
	if !IsObject(Preset)
		return (Reason := "preset_unknown") && false
	if !(Name is String) || Name = ""
		return (Reason := "preset_invalid_name") && false
	Preset["name"] := Name
	if Preset.Has("name_key")
		Preset.Delete("name_key")
	return true
}

KeepAwakePresetsRemove(Doc, Id, &Reason := "") {
	Index := _KeepAwakeIndexOf(Doc, Id)
	if !Index
		return (Reason := "preset_unknown") && false
	if Doc["presets"].Length = 1
		return (Reason := "preset_last") && false
	Doc["presets"].RemoveAt(Index)
	if Doc["active"] == Id
		Doc["active"] := Doc["presets"][1]["id"]
	return true
}

KeepAwakePresetsSetApps(Doc, Id, OsName, Apps, &Reason := "") {
	Preset := KeepAwakePresetsGet(Doc, Id)
	if !IsObject(Preset)
		return (Reason := "preset_unknown") && false
	if !Preset["allowed_apps"].Has(OsName)
		return (Reason := "preset_invalid_apps") && false
	Trial := KeepAwakePresetsCopy(Preset)
	Trial["allowed_apps"][OsName] := KeepAwakePresetsCopy(Apps)
	Reason := KeepAwakePresetInvalid(Trial)
	if Reason != ""
		return false
	Preset["allowed_apps"][OsName] := KeepAwakePresetsCopy(Apps)
	return true
}

KeepAwakePresetsPutTarget(Doc, Id, Kind, Target, &Reason := "") {
	Preset := KeepAwakePresetsGet(Doc, Id)
	if !IsObject(Preset)
		return (Reason := "preset_unknown") && false
	if Kind != "images" && Kind != "texts"
		return (Reason := "preset_invalid_targets") && false
	Trial := KeepAwakePresetsCopy(Preset)
	List := Trial[Kind], Replaced := false
	for Index, Existing in List {
		if (Target is Map) && Target.Has("id") && Existing["id"] == Target["id"] {
			List[Index] := KeepAwakePresetsCopy(Target)
			Replaced := true
		}
	}
	if !Replaced
		List.Push(KeepAwakePresetsCopy(Target))
	Reason := KeepAwakePresetInvalid(Trial)
	if Reason != ""
		return false
	Preset[Kind] := Trial[Kind]
	return true
}

KeepAwakePresetsRemoveTarget(Doc, Id, TargetId, &Reason := "") {
	Preset := KeepAwakePresetsGet(Doc, Id)
	if !IsObject(Preset)
		return (Reason := "preset_unknown") && false
	for Kind in ["images", "texts"] {
		for Index, Target in Preset[Kind] {
			if Target["id"] == TargetId {
				Preset[Kind].RemoveAt(Index)
				return true
			}
		}
	}
	return (Reason := "target_unknown") && false
}

; What Windows runs for a preset: Map keep_awake, auto_click, allowed_apps,
; templates (id, path, threshold) and text_targets (id, variants, max_distance).
KeepAwakePresetsPlan(Preset, OsName, ImagesDir, Separator, Defaults) {
	if KeepAwakePresetInvalid(Preset) != ""
		throw ValueError("A plan needs a valid preset.")
	Templates := [], TextTargets := []
	for Image in Preset["images"] {
		if Image["enabled"]
			Templates.Push(Map("id", Image["id"], "path", ImagesDir . Separator . Image["file"],
				"threshold", Image.Has("threshold") ? Image["threshold"] : Defaults["threshold"]))
	}
	for Text in Preset["texts"] {
		if Text["enabled"]
			TextTargets.Push(Map("id", Text["id"], "variants", KeepAwakePresetsCopy(Text["variants"]),
				"max_distance", Text["max_distance"]))
	}
	return Map("keep_awake", Preset["keep_awake"], "auto_click", Preset["auto_click"],
		"allowed_apps", KeepAwakePresetsCopy(Preset["allowed_apps"][OsName]),
		"templates", Templates, "text_targets", TextTargets)
}
