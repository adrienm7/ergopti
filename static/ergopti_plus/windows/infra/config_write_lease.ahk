; infra/config_write_lease.ahk

#Include %A_LineFile%\..\file_read_activity.ahk

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
	return FileReadActivityKey(Path)
}

; Intrinsic inspection precedes any virtual method, getter or container read.
; These helpers validate data shape only; private issuer receipts still own
; authority, including retirement of the exact originally issued object.
_ConfigWriteLeasePlainContainer(Value, Prototype) {
	if !IsObject(Value) || ObjGetBase(Value) != Prototype
		return false
	for Name in ObjOwnProps(Value)
		return false
	return true
}

_ConfigWriteLeaseDataObject(Owner, Fields) {
	if !IsObject(Owner) || ObjGetBase(Owner) != Object.Prototype
		return false
	Names := Map()
	Names.CaseSense := "On"
	for Name in ObjOwnProps(Owner) {
		Descriptor := Object.Prototype.GetOwnPropDesc.Call(Owner, Name)
		if !Descriptor.HasOwnProp("Value")
			return false
		Names[Name] := true
	}
	if Names.Count != Fields.Length
		return false
	for Name in Fields {
		if !Names.Has(Name)
			return false
	}
	return true
}

_ConfigWriteLeaseStateIsData(State) {
	return _ConfigWriteLeaseDataObject(State, ["owners", "terminal", "next_id"])
		&& _ConfigWriteLeasePlainContainer(State.owners, Map.Prototype)
		&& (State.next_id is Integer) && State.next_id >= 0
		&& (IsObject(State.terminal) || ((State.terminal is Integer) && State.terminal == 0))
}

_ConfigWriteLeaseTryAcquire(Path, Kind := "targeted", InspectToken := unset, Retire := false) {
	static StateOwner := _ConfigWriteLeaseState
	static DataOwner := _ConfigWriteLeaseDataObject, ContainerOwner := _ConfigWriteLeasePlainContainer
	static StateDataOwner := _ConfigWriteLeaseStateIsData
	if StateOwner != _ConfigWriteLeaseState || DataOwner != _ConfigWriteLeaseDataObject
			|| ContainerOwner != _ConfigWriteLeasePlainContainer || StateDataOwner != _ConfigWriteLeaseStateIsData
		return false
	static Issued := Map(), ActiveKeys := Map()
	if IsSet(InspectToken) {
		PreviousCritical := Critical("On")
		try {
			if (InspectToken is Integer) && InspectToken == 0
				return ActiveKeys.Count > 0
			if !Issued.Has(InspectToken)
					|| !DataOwner.Call(InspectToken, ["key", "id", "kind"])
				return false
			Receipt := Issued[InspectToken]
			State := StateOwner.Call()
			if !StateDataOwner.Call(State) || State.terminal is Object
					|| !(InspectToken.key is String) || !(InspectToken.kind is String)
					|| !(InspectToken.id is Integer) || InspectToken.id != Receipt.id
					|| StrCompare(InspectToken.kind, Receipt.kind, true) != 0
					|| StrCompare(InspectToken.key, Receipt.key, true) != 0
					|| !ActiveKeys.Has(Receipt.key) || ActiveKeys[Receipt.key] != InspectToken
					|| !State.owners.Has(Receipt.key) || State.owners[Receipt.key] != Receipt.token
				return false
			if Retire {
				ActiveKeys.Delete(Receipt.key)
				Issued.Delete(InspectToken)
			}
			return true
		} finally Critical(PreviousCritical)
	}
	State := StateOwner.Call()
	if !StateDataOwner.Call(State)
		return false
	Owners := State.owners
	Key := _ConfigWriteLeaseKey(Path)
	PreviousCritical := Critical("On")
	try {
		; A path relocation/reload is a machine-wide config transition. Blocking
		; only config.toml still lets sibling writers (hotstring overrides, prompt
		; stores, metrics) commit to the directory the next boot is abandoning.
		if !StateDataOwner.Call(State) || State != StateOwner.Call()
				|| Owners != State.owners || !ContainerOwner.Call(Owners, Map.Prototype)
				|| _ConfigWriteTerminalTryAcquire([], 0)
				|| (State.terminal is Object) || ActiveKeys.Has(Key) || Owners.Has(Key) || FileReadActivityBusy(Path)
			return false
		State.next_id += 1
		Token := { key: Key, id: State.next_id, kind: Kind }
		Owners[Key] := Token
		Issued[Token] := { token: Token, key: Key, id: Token.id, kind: Kind }
		ActiveKeys[Key] := Token
		return Token
	} finally {
		Critical(PreviousCritical)
	}
}

; Whether a configuration write is in progress that a new thread can only have
; interrupted: some path is owned and no terminal transition holds the table.
; A hotkey or a tray click that sees this cannot get a lease before it returns
; and lets the owner finish, so it defers its work instead of failing. A
; terminal transition owns every path until the process ends: waiting for it
; would only delay the refusal.
; @returns {Boolean}
ConfigWriteLeaseBusy() {
	State := _ConfigWriteLeaseState()
	PreviousCritical := Critical("On")
	try {
		if !_ConfigWriteLeaseStateIsData(State)
			return true
		return !(State.terminal is Object) && State.owners.Count > 0
	} finally Critical(PreviousCritical)
}

/** Defers mutation commands without invalidating concurrent source readers. */
ConfigMutationBusy() {
	PreviousCritical := Critical("On")
	try return ConfigWriteLeaseBusy() || FileReadActivityBusy()
	finally Critical(PreviousCritical)
}

_ConfigWriteLeaseRelease(Token) {
	if !_ConfigWriteLeaseOwns(Token)
		return false
	Owners := _ConfigWriteLeaseOwners()
	PreviousCritical := Critical("On")
	try {
		State := _ConfigWriteLeaseState()
		if !_ConfigWriteLeaseStateIsData(State) || !_ConfigWriteLeaseOwns(Token)
				|| Owners != State.owners
			return false
		if (State.terminal is Object) {
			if !_ConfigWriteTerminalTryAcquire([], State.terminal)
				return false
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
		if !_ConfigWriteLeaseTryAcquire("", "", Token, true)
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
_ConfigWriteTerminalTryAcquire(Paths, InspectOwner := unset, Retire := false) {
	static StateOwner := _ConfigWriteLeaseState
	static OrdinaryIssuer := _ConfigWriteLeaseTryAcquire
	static DataOwner := _ConfigWriteLeaseDataObject, ContainerOwner := _ConfigWriteLeasePlainContainer
	static StateDataOwner := _ConfigWriteLeaseStateIsData
	if StateOwner != _ConfigWriteLeaseState || DataOwner != _ConfigWriteLeaseDataObject
			|| ContainerOwner != _ConfigWriteLeasePlainContainer || StateDataOwner != _ConfigWriteLeaseStateIsData
		return false
	static Issued := false
	if IsSet(InspectOwner) {
		PreviousCritical := Critical("On")
		try {
			if (InspectOwner is Integer) && InspectOwner == 0
				return Issued is Object
			if !(Issued is Object) || !IsObject(InspectOwner)
				return false
			Bundle := Issued.bundle
			State := StateOwner.Call()
			if !StateDataOwner.Call(State) || State.terminal != Bundle
					|| !DataOwner.Call(Bundle, ["id", "kind", "tokens", "authorized", "shutdown_claimed"])
					|| !(Bundle.kind is String)
					|| !(Bundle.id is Integer) || Bundle.id != Issued.id || StrCompare(Bundle.kind, "terminal_bundle", true) != 0
					|| !(Bundle.authorized is Integer) || (Bundle.authorized != 0 && Bundle.authorized != 1)
					|| !(Bundle.shutdown_claimed is Integer) || (Bundle.shutdown_claimed != 0 && Bundle.shutdown_claimed != 1)
					|| Bundle.tokens != Issued.token_array
					|| !ContainerOwner.Call(Bundle.tokens, Array.Prototype)
					|| Bundle.tokens.Length != Issued.tokens.Length
				return false
			Found := InspectOwner == Bundle
			for Index, Receipt in Issued.tokens {
				Token := Receipt.token
				if !Bundle.tokens.Has(Index) || Bundle.tokens[Index] != Token
						|| !DataOwner.Call(Token, ["key", "id", "kind"])
						|| !(Token.key is String) || !(Token.kind is String)
						|| StrCompare(Token.key, Receipt.key, true) != 0 || !(Token.id is Integer) || Token.id != Receipt.id
						|| StrCompare(Token.kind, "terminal", true) != 0 || !State.owners.Has(Receipt.key) || State.owners[Receipt.key] != Token
					return false
				if InspectOwner == Token
					Found := true
			}
			if Retire && Found && InspectOwner == Bundle
				Issued := false
			return Found
		} finally Critical(PreviousCritical)
	}
	if Issued is Object || OrdinaryIssuer != _ConfigWriteLeaseTryAcquire
			|| OrdinaryIssuer.Call("", "", 0)
		return false
	State := StateOwner.Call()
	if !StateDataOwner.Call(State)
		return false
	PathList := (Paths is Array) ? Paths : [Paths]
	if !ContainerOwner.Call(PathList, Array.Prototype)
		return false
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
		if !StateDataOwner.Call(State) || State != StateOwner.Call()
				|| Issued is Object || OrdinaryIssuer != _ConfigWriteLeaseTryAcquire
				|| OrdinaryIssuer.Call("", "", 0)
				|| (State.terminal is Object) || State.owners.Count > 0 || FileReadActivityBusy()
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
		Receipts := []
		for Token in Tokens
			Receipts.Push({ token: Token, key: Token.key, id: Token.id })
		Issued := { bundle: Bundle, id: Bundle.id, token_array: Tokens, tokens: Receipts }
		return Bundle
	} finally Critical(PreviousCritical)
}

; Builds the dry terminal barrier an ordinary reload, exit or configuration
; transition needs: the active config.toml plus the caller's declared targets
; (a path or an array of paths; 0 for none). It fails closed during
; Bundle_Init's parse-time #HotIf message pump, before ConfigurationFile exists.
ConfigWriteAcquireLifecycleBundle(AdditionalPaths := 0) {
	global ConfigurationFile
	if !IsSet(ConfigurationFile)
		return false
	Paths := [ConfigurationFile]
	if (AdditionalPaths is Array) {
		for Path in AdditionalPaths
			Paths.Push(Path)
	} else if (AdditionalPaths is String) && AdditionalPaths != "" {
		Paths.Push(AdditionalPaths)
	} else if !((AdditionalPaths is Integer) && AdditionalPaths == 0) {
		return false
	}
	return _ConfigWriteTerminalTryAcquire(Paths)
}

_ConfigWriteTerminalIsActive() {
	; Public table withdrawal cannot retire an actual native barrier.
	return _ConfigWriteTerminalTryAcquire([], 0)
}

_ConfigWriteTerminalRelease(Bundle) {
	if !IsObject(Bundle)
		return false
	State := _ConfigWriteLeaseState()
	PreviousCritical := Critical("On")
	try {
		if !_ConfigWriteTerminalTryAcquire([], Bundle) || !(State.terminal is Object) || State.terminal != Bundle
			return false
		if !_ConfigWriteTerminalTryAcquire([], Bundle, true)
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
	if !IsObject(OwnerOrBundle)
		return false
	if _ConfigWriteTerminalTryAcquire([], OwnerOrBundle)
			&& _ConfigWriteLeaseDataObject(OwnerOrBundle, ["id", "kind", "tokens", "authorized", "shutdown_claimed"]) {
		for Token in OwnerOrBundle.tokens {
			if _ConfigWriteLeaseOwns(Token, Path)
				return Token
		}
		return false
	}
	return _ConfigWriteLeaseOwns(OwnerOrBundle, Path) ? OwnerOrBundle : false
}

_ConfigWriteTerminalAuthorize(Bundle) {
	if !IsObject(Bundle)
		return false
	State := _ConfigWriteLeaseState()
	PreviousCritical := Critical("On")
	try {
		if !_ConfigWriteTerminalTryAcquire([], Bundle) || !(State.terminal is Object) || State.terminal != Bundle || FileReadActivityBusy()
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
	if !IsObject(Bundle)
		return false
	State := _ConfigWriteLeaseState()
	PreviousCritical := Critical("On")
	try {
		if !_ConfigWriteTerminalTryAcquire([], Bundle) || !(State.terminal is Object) || State.terminal != Bundle || FileReadActivityBusy()
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
	if !IsObject(Bundle)
		return false
	State := _ConfigWriteLeaseState()
	PreviousCritical := Critical("On")
	try {
		if !_ConfigWriteTerminalTryAcquire([], Bundle) || !(State.terminal is Object) || State.terminal != Bundle
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
	static TargetIssuer := _ConfigWriteLeaseTryAcquire, TerminalIssuer := _ConfigWriteTerminalTryAcquire
	static StateOwner := _ConfigWriteLeaseState, DataOwner := _ConfigWriteLeaseDataObject
	if TargetIssuer != _ConfigWriteLeaseTryAcquire || TerminalIssuer != _ConfigWriteTerminalTryAcquire
			|| StateOwner != _ConfigWriteLeaseState || DataOwner != _ConfigWriteLeaseDataObject
		return false
	; Integer zero is an internal activity query, not an issued target token.
	; An actual bundle is also distinct from its admitted three-field targets.
	if !DataOwner.Call(Token, ["key", "id", "kind"])
		return false
	PreviousCritical := Critical("On")
	try {
		; Both issuers prove intrinsic data descriptors before exposing any field.
		if !TerminalIssuer.Call([], Token) && !TargetIssuer.Call("", "", Token)
			return false
		return !IsSet(Path) || Token.key == _ConfigWriteLeaseKey(Path)
	} finally Critical(PreviousCritical)
}

_ConfigWriteLeaseCurrent(Path) {
	Owners := _ConfigWriteLeaseOwners()
	Key := _ConfigWriteLeaseKey(Path)
	PreviousCritical := Critical("On")
	try return Owners.Has(Key) ? Owners[Key] : false
	finally Critical(PreviousCritical)
}


/** Checks an actual native-issued terminal bundle and its exact target token. */
_ConfigWriteTerminalOwnsExact(Bundle, Path) {
	static Issuer := _ConfigWriteTerminalTryAcquire, Select := _ConfigWriteLeaseSelectOwner
	static DataOwner := _ConfigWriteLeaseDataObject
	if Issuer != _ConfigWriteTerminalTryAcquire || Select != _ConfigWriteLeaseSelectOwner
			|| DataOwner != _ConfigWriteLeaseDataObject
		return false
	; The issuer's private activity query/member-token result is not a bundle.
	if !DataOwner.Call(Bundle, ["id", "kind", "tokens", "authorized", "shutdown_claimed"])
		return false
	PreviousCritical := Critical("On")
	try {
		if !_ConfigWriteTerminalTryAcquire([], Bundle)
			return false
		return _ConfigWriteLeaseSelectOwner(Bundle, Path) is Object
	} finally Critical(PreviousCritical)
}
