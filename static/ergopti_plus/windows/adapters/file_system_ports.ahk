; adapters/file_system_ports.ahk

; ==============================================================================
; MODULE: FileSystem Port Spec
; DESCRIPTION:
; The Windows reader of _shared/lua/file_system/ports.lua: what a file-system owner
; must offer besides the five plain operations. An owner is a Map from the spec's
; method names to callables; adapters/file_system.ahk checks its own when it loads,
; so a missing method fails at boot rather than inside a publication.
;
; FEATURES & RATIONALE:
; 1. The names are generated from the Lua spec; the messages are its own, and
;    _shared/tests/corpus/file_system/port_vectors.json pins them on every driver.
; 2. A capability offered by halves is refused: a caller that finds its first
;    method assumes the second.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include %A_LineFile%\..\..\_generated\file_system_ports.ahk

; The names of Contract that Owner does not offer as a callable, in Contract's order.
_FSPortsMissing(Contract, Owner) {
	Missing := []
	for Method in Contract
		if !Owner.Has(Method) || !HasMethod(Owner[Method], "Call")
			Missing.Push(Method)
	return Missing
}

_FSPortsJoin(Names) {
	Text := ""
	for Index, Name in Names
		Text .= (Index > 1 ? ", " : "") . Name
	return Text
}

; Checks that an owner offers every required method.
; @param Owner {Map} Method name -> callable.
; @returns {Map} The same owner.
FSPortsCheck(Owner) {
	if !(Owner is Map)
		throw TypeError("FileSystem must be a Map")
	Missing := _FSPortsMissing(FILE_SYSTEM_PORT_CONTRACT, Owner)
	if Missing.Length
		throw ValueError("FileSystem lacks: " . _FSPortsJoin(Missing))
	return Owner
}

; Names the optional capabilities an owner offers completely, and refuses one it
; offers by halves.
; @param Owner {Map} Method name -> callable.
; @returns {Array} Sorted capability names.
FSPortsCheckCapabilities(Owner) {
	if !(Owner is Map)
		throw TypeError("FileSystem must be a Map")
	Offered := []
	; A Map enumerates its string keys in sorted order.
	for Name, Contract in FILE_SYSTEM_PORT_CAPABILITIES {
		Missing := _FSPortsMissing(Contract, Owner)
		if !Missing.Length
			Offered.Push(Name)
		else if (Missing.Length < Contract.Length)
			throw ValueError(Name . " is offered by halves, it lacks: " . _FSPortsJoin(Missing))
	}
	return Offered
}

; Checks an owner completely: required methods, then capabilities.
; @param Owner {Map} Method name -> callable.
; @returns {Array} The capabilities it offers.
FSPortsCheckOwner(Owner) {
	FSPortsCheck(Owner)
	return FSPortsCheckCapabilities(Owner)
}
