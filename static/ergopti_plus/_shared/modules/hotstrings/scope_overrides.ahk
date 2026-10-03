; _shared/modules/hotstrings/scope_overrides.ahk

; ==============================================================================
; MODULE: Shared Hotstring Scope Delay Recommendations
; DESCRIPTION:
; The portable AHK half of hotstrings.scope_overrides measures corpus inheritance
; before deciding whether Restore Recommended needs an explicit timing override.
; Clear retains corpus inheritance; personal and extension content is not assigned
; a bundled recommendation. Common independent vectors pin both language owners.
; ==============================================================================

/**
 * Plans explicit recommended delays that cannot be obtained by deleting overrides.
 * @param {String} Mode The existing scope's recommended or clear action.
 * @param {Array} Features The generated shared manifest's actual feature rows.
 * @param {Array} Groups Runtime-owned groups with id, sections and bundled fields.
 * @param {Func} Inherited Returns corpus inheritance for (group, section).
 * @returns {Array} Detached group, section, seconds and inherited recommendations.
 */
HotstringsScopeDelayRecommendations(Mode, Features, Groups, Inherited) {
	if !(Mode == "recommended" || Mode == "clear") || !(Features is Array)
			|| !(Groups is Array) || !HasMethod(Inherited, "Call")
		throw TypeError("Hotstring scope delay planning requires its actual owners.")
	Recommendations := [], Seen := Map()
	Seen.CaseSense := "On"
	for Group in Groups {
		if !(Group is Map) || !(Group.Get("id", 0) is String) || Group["id"] == ""
				|| !(Group.Get("sections", 0) is Array)
				|| !(Group.Get("bundled", -1) is Integer)
				|| !(Group["bundled"] == 0 || Group["bundled"] == 1)
			throw TypeError("Hotstring scope delay group is malformed.")
		Id := Group["id"]
		if Seen.Has(Id)
			throw ValueError("Hotstring scope delay group is duplicated.")
		Seen[Id] := true
		for Section in Group["sections"] {
			if !(Section is String) || Section == ""
				throw TypeError("Hotstring scope delay section is malformed.")
			if Mode != "recommended" || !Group["bundled"]
				continue
			Entry := _HotstringsScopeSectionFeature(Features, Id, Section)
			if !(Entry is Map) || !(Entry.Get("recommended", 0) is Map)
					|| !Entry["recommended"].Has("time_activation_seconds")
				continue
			Seconds := Entry["recommended"]["time_activation_seconds"]
			if !(Seconds is Integer || Seconds is Float) || Seconds < 0
				throw TypeError("The manifest's recommended hotstring delay is invalid.")
			Baseline := Inherited.Call(Id, Section)
			if !(Baseline is Integer || Baseline is Float)
				throw TypeError("The hotstring corpus inheritance is unavailable.")
			if Baseline != Seconds
				Recommendations.Push(Map("group", Id, "section", Section,
					"seconds", Seconds, "inherited", Baseline))
		}
	}
	return Recommendations
}

/** Matches the same bundled section identity as shared hotstrings.languages. */
_HotstringsScopeSectionFeature(Features, Group, Section) {
	Wanted := StrReplace(Group, "_")
	for Entry in Features {
		if !(Entry is Map) || !(Entry.Get("section", 0) is String)
			continue
		Path := Entry["section"]
		if SubStr(Path, 1, StrLen("hotstrings.")) == "hotstrings."
				&& StrReplace(SubStr(Path, StrLen("hotstrings.") + 1), "_") == Wanted
				&& Entry.Get("id", "") == Section && Entry.Get("default", 0) is Map
			return Entry
	}
	return 0
}
