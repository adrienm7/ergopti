; infra/config_write_lease.ahk

; ==============================================================================
; MODULE: Configuration Write Lease
; DESCRIPTION:
; Serializes logical configuration transactions by normalized physical path.
; The lease is shared by config.toml writers and independent configuration
; stores such as hotstrings overrides, so a re-entrant AHK thread cannot build
; from stale live state and later overwrite a sibling transaction it interrupted.
;
; FEATURES & RATIONALE:
; 1. Path-scoped ownership lets unrelated configuration files progress.
; 2. Opaque generation tokens prevent stale owners from releasing a newer lease.
; 3. Tiny Critical sections protect ownership metadata without wrapping I/O.
; 4. A terminal bundle atomically closes admission process-wide while owning
;    every declared transition target through reload/exit authorization.
; ==============================================================================





; ==============================
; ==============================
; ======= 1/ Write lease =======
; ==============================
; ==============================

; One logical owner per physical config path. The map itself is private to this
; accessor so no caller can delete another thread's owner. Path normalization is
; lexical and Windows-aware; slash/case aliases share ownership.
_ConfigWriteLeaseState() {
	static State := { owners: Map(), terminal: false, next_id: 0 }
	return State
}

_ConfigWriteLeaseOwners() {
	return _ConfigWriteLeaseState().owners
}

_ConfigWriteLeaseKey(Path) {
	return StrLower(StrReplace(String(Path), "/", "\"))
}

_ConfigWriteLeaseTryAcquire(Path, Kind := "targeted") {
	State := _ConfigWriteLeaseState()
	Owners := State.owners
	Key := _ConfigWriteLeaseKey(Path)
	PreviousCritical := Critical("On")
	try {
		; A path relocation/reload is a machine-wide config transition. Blocking
		; only config.toml still lets sibling writers (hotstring overrides, prompt
		; stores, metrics) commit to the directory the next boot is abandoning.
		if (State.terminal is Object) || Owners.Has(Key)
			return false
		State.next_id += 1
		Token := { key: Key, id: State.next_id, kind: Kind }
		Owners[Key] := Token
		return Token
	} finally {
		Critical(PreviousCritical)
	}
}

_ConfigWriteLeaseRelease(Token) {
	if !(Token is Object) || !Token.HasOwnProp("key") || !Token.HasOwnProp("id")
		return false
	Owners := _ConfigWriteLeaseOwners()
	PreviousCritical := Critical("On")
	try {
		State := _ConfigWriteLeaseState()
		if (State.terminal is Object) {
			for TerminalToken in State.terminal.tokens {
				if (TerminalToken is Object) && TerminalToken.id = Token.id
					return false
			}
		}
		if !Owners.Has(Token.key)
			return false
		Current := Owners[Token.key]
		if !(Current is Object) || !Current.HasOwnProp("id") || Current.id != Token.id
			return false
		Owners.Delete(Token.key)
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

; Acquires a process-wide transition barrier plus exact path owners in one
; Critical section. It succeeds only from a dry lease table; from that point no
; ordinary config writer can enter on any sibling path until the whole bundle
; is released. Paths may be a String or an Array and are de-duplicated by their
; normalized physical key.
_ConfigWriteTerminalTryAcquire(Paths) {
	State := _ConfigWriteLeaseState()
	PathList := (Paths is Array) ? Paths : [Paths]
	Keys := Map()
	for Path in PathList {
		Key := _ConfigWriteLeaseKey(Path)
		if (Key = "")
			return false
		Keys[Key] := true
	}
	if (Keys.Count = 0)
		return false
	PreviousCritical := Critical("On")
	try {
		if (State.terminal is Object) || State.owners.Count > 0
			return false
		Tokens := []
		for Key, _ in Keys {
			State.next_id += 1
			Token := { key: Key, id: State.next_id, kind: "terminal" }
			State.owners[Key] := Token
			Tokens.Push(Token)
		}
		State.next_id += 1
		Bundle := { kind: "terminal_bundle", id: State.next_id,
			tokens: Tokens, authorized: false, shutdown_claimed: false }
		State.terminal := Bundle
		return Bundle
	} finally Critical(PreviousCritical)
}

_ConfigWriteTerminalIsActive() {
	State := _ConfigWriteLeaseState()
	PreviousCritical := Critical("On")
	try return State.terminal is Object
	finally Critical(PreviousCritical)
}

_ConfigWriteTerminalRelease(Bundle) {
	if !(Bundle is Object) || !Bundle.HasOwnProp("id")
		return false
	State := _ConfigWriteLeaseState()
	PreviousCritical := Critical("On")
	try {
		if !(State.terminal is Object) || State.terminal.id != Bundle.id
			return false
		for Token in State.terminal.tokens {
			if State.owners.Has(Token.key) {
				Current := State.owners[Token.key]
				if (Current is Object) && Current.id = Token.id
					State.owners.Delete(Token.key)
			}
		}
		State.terminal := false
		return true
	} finally Critical(PreviousCritical)
}

_ConfigWriteLeaseSelectOwner(OwnerOrBundle, Path) {
	if !(OwnerOrBundle is Object)
		return false
	if OwnerOrBundle.HasOwnProp("kind")
			&& OwnerOrBundle.kind = "terminal_bundle"
			&& OwnerOrBundle.HasOwnProp("tokens") {
		for Token in OwnerOrBundle.tokens {
			if _ConfigWriteLeaseOwns(Token, Path)
				return Token
		}
		return false
	}
	return _ConfigWriteLeaseOwns(OwnerOrBundle, Path)
		? OwnerOrBundle : false
}

_ConfigWriteTerminalAuthorize(Bundle) {
	if !(Bundle is Object) || !Bundle.HasOwnProp("id")
		return false
	State := _ConfigWriteLeaseState()
	PreviousCritical := Critical("On")
	try {
		if !(State.terminal is Object) || State.terminal.id != Bundle.id
			return false
		for Token in Bundle.tokens {
			if !_ConfigWriteLeaseOwns(Token)
				return false
		}
		Bundle.authorized := true
		return true
	} finally Critical(PreviousCritical)
}

_ConfigWriteTerminalClaimShutdown(Bundle) {
	if !(Bundle is Object) || !Bundle.HasOwnProp("id")
		return false
	State := _ConfigWriteLeaseState()
	PreviousCritical := Critical("On")
	try {
		if !(State.terminal is Object) || State.terminal.id != Bundle.id
			return false
		if !Bundle.authorized || Bundle.shutdown_claimed
			return false
		for Token in Bundle.tokens {
			if !_ConfigWriteLeaseOwns(Token)
				return false
		}
		Bundle.shutdown_claimed := true
		return true
	} finally Critical(PreviousCritical)
}

; Revokes one refused Reload claim without releasing the process-wide barrier.
; Only the exact currently-live bundle may be rearmed; a lookalike id or stale
; object cannot make shutdown authority reusable.
_ConfigWriteTerminalCancelShutdown(Bundle) {
	if !(Bundle is Object) || !Bundle.HasOwnProp("id")
		return false
	State := _ConfigWriteLeaseState()
	PreviousCritical := Critical("On")
	try {
		if !(State.terminal is Object) || State.terminal != Bundle
			return false
		for Token in Bundle.tokens {
			if !_ConfigWriteLeaseOwns(Token)
				return false
		}
		; A later attempt must pass through HandoffPrepare authorization again.
		Bundle.authorized := false
		Bundle.shutdown_claimed := false
		return true
	} finally Critical(PreviousCritical)
}

_ConfigWriteLeaseOwns(Token, Path := unset) {
	if !(Token is Object) || !Token.HasOwnProp("key") || !Token.HasOwnProp("id")
		return false
	if IsSet(Path) && Token.key != _ConfigWriteLeaseKey(Path)
		return false
	Owners := _ConfigWriteLeaseOwners()
	PreviousCritical := Critical("On")
	try {
		if !Owners.Has(Token.key)
			return false
		Current := Owners[Token.key]
		return (Current is Object) && Current.HasOwnProp("id")
			&& Current.id = Token.id
	} finally {
		Critical(PreviousCritical)
	}
}

_ConfigWriteLeaseCurrent(Path) {
	Owners := _ConfigWriteLeaseOwners()
	Key := _ConfigWriteLeaseKey(Path)
	PreviousCritical := Critical("On")
	try return Owners.Has(Key) ? Owners[Key] : false
	finally Critical(PreviousCritical)
}
