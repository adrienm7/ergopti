; _shared/ahk/config_obsolete_parents.ahk

; ==============================================================================
; MODULE: Obsolete Configuration Collision Policy
; DESCRIPTION:
; Preserves classified obsolete leaves and neutral scalar/array descendants
; until explicit cleanup. Native owners supply exact paths and neutral intent;
; this pure policy has no catalogue, source reader or publication authority.
; ==============================================================================

#Requires AutoHotkey v2.0

; Exact semantic paths never fold case, literal dots or empty user segments.
_ConfigObsoleteParentsPath(Parts) {
	if !(Parts is Array) || !Parts.Length
		throw TypeError("Obsolete configuration paths must be nonempty dense arrays.")
	loop Parts.Length {
		if !Parts.Has(A_Index) || !(Parts[A_Index] is String)
			throw TypeError("Obsolete configuration paths require exact string segments.")
	}
}

_ConfigObsoleteParentsUnder(Parts, Prefix) {
	if Parts.Length < Prefix.Length
		return false
	for Index, Part in Prefix {
		if StrCompare(Parts[Index], Part, true) != 0
			return false
	}
	return true
}

/**
 * Filters only proved neutral collisions, retaining the original writer rows.
 * Whole ancestors, nonneutral replacements and descendants of obsolete maps
 * refuse; omitting an operation never grants authority to repair source shape.
 * @param {Array} Operations Dense records: parts, neutral Boolean, row.
 * @param {Array} Obsolete Dense classified records: parts, descendants Boolean.
 * @returns {Array} Original rows outside preserved obsolete collisions.
 */
ConfigObsoleteParentsPreserve(Operations, Obsolete) {
	if !(Operations is Array) || !(Obsolete is Array)
		throw TypeError("Obsolete configuration preparation requires dense arrays.")
	loop Obsolete.Length {
		if !Obsolete.Has(A_Index) || !IsObject(Obsolete[A_Index])
			throw TypeError("Obsolete configuration entries must be dense records.")
		Entry := Obsolete[A_Index]
		_ConfigObsoleteParentsPath(Entry.parts)
		if !(Entry.descendants is Integer) || (Entry.descendants != 0 && Entry.descendants != 1)
			throw TypeError("Obsolete configuration descendant policy must be Boolean.")
	}
	Prepared := [], Seen := []
	loop Operations.Length {
		if !Operations.Has(A_Index) || !IsObject(Operations[A_Index])
			throw TypeError("Obsolete configuration operations must be dense records.")
		Operation := Operations[A_Index]
		_ConfigObsoleteParentsPath(Operation.parts)
		if !(Operation.neutral is Integer) || (Operation.neutral != 0 && Operation.neutral != 1)
				|| !IsObject(Operation.row)
			throw TypeError("Obsolete configuration operations require native neutral intent and a writer row.")
		for Previous in Seen {
			if Previous.Length == Operation.parts.Length && _ConfigObsoleteParentsUnder(Operation.parts, Previous)
				throw ValueError("Obsolete configuration preparation cannot hide duplicate effects.")
		}
		Seen.Push(Operation.parts)
		Preserve := false
		for Entry in Obsolete {
			Under := _ConfigObsoleteParentsUnder(Operation.parts, Entry.parts)
			if !Under && !_ConfigObsoleteParentsUnder(Entry.parts, Operation.parts)
				continue
			if !Under || !Operation.neutral
					|| (Operation.parts.Length > Entry.parts.Length && !Entry.descendants)
				throw ValueError("Configuration scope collides with retained obsolete source; repair or clean it explicitly first.")
			Preserve := true
		}
		if !Preserve
			Prepared.Push(Operation.row)
	}
	return Prepared
}
