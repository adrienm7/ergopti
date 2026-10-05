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
