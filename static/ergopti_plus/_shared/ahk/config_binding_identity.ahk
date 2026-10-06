; _shared/ahk/config_binding_identity.ahk

; ==============================================================================
; MODULE: Configuration Binding Identity (shared rule)
; DESCRIPTION:
; Judges only gesture bindings against a complete catalogue published by their
; native owner. Replays the same config_binding_identity JSON corpus as Lua:
; unavailable or another domain is unjudged; a missing published slot is retired.
; The owner reports retirement and preserves source until explicit cleanup.
; ==============================================================================

#Requires AutoHotkey v2.0

; Judges the native identity against its explicitly published gesture domain.
; Catalogue is Map("prefix", nativePrefix, "slots", completeNativeSlotSet), or
; omitted when unavailable. An explicitly malformed value still fails fast.
; Native Boolean set members are AHK's integer true value.
; @param {Any} BindingId Native binding id.
; @param {Map} Catalogue Complete publication, omitted when unavailable.
; @return {String} "current", "retired", or "unjudged".
ConfigBindingIdentityGestureStatus(BindingId, Catalogue?) {
	if !IsSet(Catalogue)
		return "unjudged"
	if !(Catalogue is Map) || !Catalogue.Has("prefix") || !Catalogue.Has("slots")
		|| Type(Catalogue["prefix"]) != "String" || !(Catalogue["slots"] is Map)
		throw ValueError("config_binding_identity: invalid published catalogue")
	Slots := Catalogue["slots"]
	for Slot, Present in Slots {
		if Type(Slot) != "String" || Slot == "" || InStr(Slot, "__", true)
			|| Type(Present) != "Integer" || Present != true
			throw ValueError("config_binding_identity: invalid published slot set")
	}
	if Type(BindingId) != "String"
		return "unjudged"
	Prefix := Catalogue["prefix"]
	if Prefix == "" {
		if InStr(BindingId, "__", true)
			return "unjudged"
		Slot := BindingId
	} else {
		if SubStr(BindingId, 1, StrLen(Prefix)) !== Prefix
			return "unjudged"
		Slot := SubStr(BindingId, StrLen(Prefix) + 1)
	}
	for PublishedSlot in Slots {
		if PublishedSlot == Slot
			return "current"
	}
	return "retired"
}

; Judges only a complete acknowledged script-domain publication.
; Omitted publication remains unjudged, without reading or initializing an owner.
ConfigBindingIdentityScriptStatus(BindingId, Catalogue?) {
	if !IsSet(Catalogue)
		return "unjudged"
	if !(Catalogue is Map) || !Catalogue.Has("prefix") || Catalogue["prefix"] !== "script__"
		|| !Catalogue.Has("slots") || !(Catalogue["slots"] is Map) || Catalogue["slots"].Count == 0
		throw ValueError("config_binding_identity: invalid published script catalogue")
	return ConfigBindingIdentityGestureStatus(BindingId, Catalogue)
}

; Exact reason shared by native readers and cleanup; other domains are unchanged.
ConfigBindingIdentityScriptRetiredReason() {
	return "no script chord slot of this build has this name"
}

; Builds only the complete native script-slot declaration publication.
; This compiled source owner performs no file IO and does not use assignments.
ConfigBindingIdentityScriptPublication(Ids) {
	if !(Ids is Array) || Ids.Length == 0
		throw ValueError("script chords: invalid published slot catalogue")
	Slots := Map()
	Slots.CaseSense := "On"
	Count := 0
	for Index, Slot in Ids {
		if Type(Slot) != "String" || Slot == "" || InStr(Slot, "__", true) || Slots.Has(Slot)
			throw ValueError("script chords: invalid published slot catalogue")
		Slots[Slot] := true
		Count += 1
	}
	if Count != Ids.Length
		throw ValueError("script chords: invalid published slot catalogue")
	return { Source: Ids, Catalogue: Map("prefix", "script__", "slots", Slots) }
}

; Judges only the complete acknowledged tap-key domain.
ConfigBindingIdentityTapStatus(BindingId, Catalogue?) {
	if !IsSet(Catalogue)
		return "unjudged"
	if !(Catalogue is Map) || !Catalogue.Has("prefix") || Catalogue["prefix"] !== "tap_key__"
		|| !Catalogue.Has("slots") || !(Catalogue["slots"] is Map) || Catalogue["slots"].Count == 0
		throw ValueError("config_binding_identity: invalid published tap-key catalogue")
	return ConfigBindingIdentityGestureStatus(BindingId, Catalogue)
}

; Actual compiled order and scan declarations jointly prove a complete domain.
; No assignment, native input, file IO or copied ID list participates.
ConfigBindingIdentityTapPublication(Ids, Scans) {
	if !(Ids is Array) || Ids.Length == 0 || !(Scans is Map)
		throw ValueError("tap keys: invalid published slot catalogue")
	Slots := Map()
	Slots.CaseSense := "On"
	ScanSnapshot := Map()
	ScanSnapshot.CaseSense := "On"
	SeenScans := Map()
	Count := 0
	for Index, Slot in Ids {
		if Type(Slot) != "String" || Slot == "" || InStr(Slot, "__", true) || Slots.Has(Slot)
			throw ValueError("tap keys: invalid published slot catalogue")
		Slots[Slot] := true
		Count += 1
	}
	if Count != Ids.Length || Scans.Count != Count
		throw ValueError("tap keys: incomplete published scan catalogue")
	for Slot, Scan in Scans {
		if Type(Slot) != "String" || !Slots.Has(Slot) || Type(Scan) != "Integer"
			|| Scan <= 0 || SeenScans.Has(Scan)
			throw ValueError("tap keys: invalid published scan catalogue")
		ScanSnapshot[Slot] := Scan
		SeenScans[Scan] := true
	}
	return { Source: Ids, ScanSource: Scans, Scans: ScanSnapshot,
		Catalogue: Map("prefix", "tap_key__", "slots", Slots) }
}

; Shared warning detail for the published tap-key parameter owner.
ConfigBindingIdentityTapRetiredReason() {
	return "no number-row tap key of this build has this name"
}
