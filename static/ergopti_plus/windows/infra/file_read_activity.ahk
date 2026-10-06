; infra/file_read_activity.ahk

; ==============================================================================
; MODULE: Exact File Read Activity
; DESCRIPTION:
; Tracks synchronous Win32 read attempts before native opening can pump a timer.
; Metadata ownership keeps interrupted config writers from replacing a file
; while its exact reader denies deletion. Native I/O stays interruptible.
; ==============================================================================

#Requires AutoHotkey v2.0

/** Returns the shared lexical Windows path key, preserving slash/case aliases. */
FileReadActivityKey(Path) {
	return StrLower(StrReplace(String(Path), "/", "\"))
}

_FileReadActivityState() {
	static State := {owners: Map(), paths: Map()}
	return State
}

/** Publishes an opaque opening owner before the native acquisition starts. */
FileReadActivityEnter(Path) {
	Key := FileReadActivityKey(Path)
	if Key == ""
		throw ValueError("An exact reader requires a nonempty path.")
	Token := {}
	State := _FileReadActivityState()
	PreviousCritical := Critical("On")
	try {
		State.owners[ObjPtr(Token)] := {token: Token, key: Key, path: String(Path), handle: -1}
		State.paths[Key] := State.paths.Get(Key, 0) + 1
	} finally Critical(PreviousCritical)
	return Token
}

/** Retains the acquired handle for diagnostics if native close is refused. */
FileReadActivityBind(Token, Handle) {
	State := _FileReadActivityState()
	PreviousCritical := Critical("On")
	try {
		if !(Token is Object) || !State.owners.Has(ObjPtr(Token))
			throw ValueError("The exact reader no longer owns its activity.")
		Row := State.owners[ObjPtr(Token)]
		if Row.token != Token || Row.handle != -1 || Handle == -1
			throw ValueError("An exact reader handle can only be bound once.")
		Row.handle := Handle
	} finally Critical(PreviousCritical)
}

/** Releases only this attempt after failed opening or acknowledged native close. */
FileReadActivityLeave(Token) {
	if !(Token is Object)
		return false
	State := _FileReadActivityState()
	PreviousCritical := Critical("On")
	try {
		if !State.owners.Has(ObjPtr(Token))
			return false
		Row := State.owners[ObjPtr(Token)]
		if Row.token != Token
			return false
		State.owners.Delete(ObjPtr(Token))
		Remaining := State.paths[Row.key] - 1
		if Remaining
			State.paths[Row.key] := Remaining
		else
			State.paths.Delete(Row.key)
		return true
	} finally Critical(PreviousCritical)
}

/** Reports opening, acquired and unacknowledged-close readers without waiting. */
FileReadActivityBusy(Path := unset) {
	Key := IsSet(Path) ? FileReadActivityKey(Path) : ""
	State := _FileReadActivityState()
	PreviousCritical := Critical("On")
	try return IsSet(Path) ? State.paths.Has(Key) : State.owners.Count > 0
	finally Critical(PreviousCritical)
}
