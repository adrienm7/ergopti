; tests/unit/test_config_write_terminal_barrier.ahk

; ==============================================================================
; MODULE: Process-wide configuration terminal barrier
; DESCRIPTION:
; Proves that a relocation/reload owner excludes every sibling configuration
; path, owns each declared target exactly, and cannot be dismantled through an
; ordinary path-token release. Ordinary in-flight writers also prevent entry.
; ==============================================================================

#Requires AutoHotkey v2.0

_CWTB_TerminalExcludesEverySiblingPath() {
	ConfigPath := "C:\ergopti-tests\terminal\config.toml"
	CandidatePath := "C:/ergopti-tests/candidate/config.toml"
	SiblingPath := "C:\ergopti-tests\terminal\hotstrings_overrides.toml"
	Bundle := _ConfigWriteTerminalTryAcquire(
		[ConfigPath, CandidatePath, StrUpper(ConfigPath)])
	AssertTrue(Bundle is Object)
	try {
		AssertEqual(2, Bundle.tokens.Length,
			"case and slash aliases must not create two physical owners")
		ConfigOwner := _ConfigWriteLeaseSelectOwner(Bundle, ConfigPath)
		CandidateOwner := _ConfigWriteLeaseSelectOwner(Bundle, CandidatePath)
		AssertTrue(ConfigOwner is Object)
		AssertTrue(CandidateOwner is Object)
		AssertFalse(_ConfigWriteLeaseSelectOwner(Bundle, SiblingPath) is Object,
			"a bundle may borrow only paths it explicitly owns")
		AssertFalse(_ConfigWriteLeaseTryAcquire(SiblingPath,
			"interrupted-writer") is Object,
			"the terminal barrier must exclude even an unrelated sibling path")
		AssertFalse(_ConfigWriteLeaseRelease(ConfigOwner),
			"an ordinary token release must not dismantle one member of a live bundle")
		AssertTrue(_ConfigWriteLeaseOwns(ConfigOwner, ConfigPath))
	} finally {
		AssertTrue(_ConfigWriteTerminalRelease(Bundle))
	}
	Sibling := _ConfigWriteLeaseTryAcquire(SiblingPath, "after-terminal")
	AssertTrue(Sibling is Object,
		"ordinary writers must become admissible after exact terminal release")
	AssertTrue(_ConfigWriteLeaseRelease(Sibling))
}
Test("config lease: terminal barrier excludes every sibling path "
	. "(config-write-terminal-barrier)",
	_CWTB_TerminalExcludesEverySiblingPath)

_CWTB_ExistingWriterBlocksTerminalEntry() {
	OwnedPath := "C:\ergopti-tests\ordinary\config.toml"
	OtherPath := "C:\ergopti-tests\relocation\config.toml"
	Owner := _ConfigWriteLeaseTryAcquire(OwnedPath, "ordinary")
	AssertTrue(Owner is Object)
	try {
		AssertFalse(_ConfigWriteTerminalTryAcquire([OtherPath]) is Object,
			"terminal entry must never leapfrog an already-admitted writer")
		AssertTrue(_ConfigWriteLeaseOwns(Owner, OwnedPath),
			"a refused terminal attempt must not disturb the existing writer")
	} finally {
		AssertTrue(_ConfigWriteLeaseRelease(Owner))
	}
	Bundle := _ConfigWriteTerminalTryAcquire([OtherPath])
	AssertTrue(Bundle is Object)
	AssertTrue(_ConfigWriteTerminalRelease(Bundle))
}
Test("config lease: an admitted writer blocks terminal entry "
	. "(config-write-terminal-barrier-existing-owner)",
	_CWTB_ExistingWriterBlocksTerminalEntry)

_CWTB_ShutdownClaimNeedsExactAuthorization() {
	Path := "C:\ergopti-tests\terminal\authorized.toml"
	Bundle := _ConfigWriteTerminalTryAcquire([Path])
	AssertTrue(Bundle is Object)
	try {
		AssertFalse(_ConfigWriteTerminalClaimShutdown(Bundle),
			"shutdown cannot borrow an unannounced transition")
		AssertTrue(_ConfigWriteTerminalAuthorize(Bundle))
		AssertTrue(_ConfigWriteTerminalClaimShutdown(Bundle))
		AssertFalse(_ConfigWriteTerminalClaimShutdown(Bundle),
			"the exact terminal authority may be claimed only once")
	} finally {
		AssertTrue(_ConfigWriteTerminalRelease(Bundle))
	}
}
Test("config lease: terminal shutdown authority is explicit and single-use "
	. "(config-write-terminal-barrier-authorized-claim)",
	_CWTB_ShutdownClaimNeedsExactAuthorization)

_CWTB_RefusedShutdownCanRearmOnlyExactLiveBundle() {
	Path := "C:\ergopti-tests\terminal\rearmed.toml"
	Bundle := _ConfigWriteTerminalTryAcquire([Path])
	AssertTrue(Bundle is Object)
	try {
		AssertTrue(_ConfigWriteTerminalAuthorize(Bundle))
		AssertTrue(_ConfigWriteTerminalClaimShutdown(Bundle))
		Lookalike := { kind: "terminal_bundle", id: Bundle.id,
			tokens: Bundle.tokens, authorized: true, shutdown_claimed: true }
		AssertFalse(_ConfigWriteTerminalCancelShutdown(Lookalike),
			"a same-id lookalike must not rearm the live shutdown authority")
		AssertTrue(Bundle.shutdown_claimed,
			"a refused lookalike must leave the genuine claim latched")
		AssertTrue(_ConfigWriteTerminalCancelShutdown(Bundle))
		AssertFalse(Bundle.authorized,
			"cancel must require the next handoff to authorize explicitly")
		AssertFalse(Bundle.shutdown_claimed,
			"cancel must make the retained terminal bundle claimable again")
		AssertTrue(_ConfigWriteTerminalAuthorize(Bundle))
		AssertTrue(_ConfigWriteTerminalClaimShutdown(Bundle),
			"the exact retained bundle must support a later Reload attempt")
	} finally _ConfigWriteTerminalRelease(Bundle)
}
Test("config lease: refusal rearms only the exact live terminal bundle "
	. "(config-write-terminal-barrier-rearm-exact)",
	_CWTB_RefusedShutdownCanRearmOnlyExactLiveBundle)


_CWTB_CopiedTokensNeverOwnOrRelease() {
	Path := "C:\ergopti-tests\identity\config.toml"
	Token := _ConfigWriteLeaseTryAcquire(Path, "identity-subject")
	AssertTrue(Token is Object)
	try {
		Clone := { key: Token.key, id: Token.id, kind: Token.kind }
		AssertFalse(_ConfigWriteLeaseOwns(Clone, Path), "same key/id never authenticates a copied token")
		AssertFalse(_ConfigWriteLeaseSelectOwner(Clone, Path) is Object)
		AssertFalse(_ConfigWriteLeaseRelease(Clone), "a copied token cannot release the actual transaction")
		AssertTrue(_ConfigWriteLeaseOwns(Token, Path))
	} finally AssertTrue(_ConfigWriteLeaseRelease(Token))
}
Test("config lease: copied ordinary tokens cannot acquire or release native ownership", _CWTB_CopiedTokensNeverOwnOrRelease)

_CWTB_CopiedBundleNeverOwnsOrAuthorizes() {
	Path := "C:\ergopti-tests\identity\terminal.toml"
	Bundle := _ConfigWriteTerminalTryAcquire([Path])
	AssertTrue(Bundle is Object)
	try {
		Clone := { kind: Bundle.kind, id: Bundle.id, tokens: Bundle.tokens,
			authorized: false, shutdown_claimed: false }
		AssertFalse(_ConfigWriteTerminalOwnsExact(Clone, Path))
		AssertFalse(_ConfigWriteLeaseSelectOwner(Clone, Path) is Object)
		AssertFalse(_ConfigWriteTerminalAuthorize(Clone))
		AssertFalse(_ConfigWriteTerminalClaimShutdown(Clone))
		AssertFalse(_ConfigWriteTerminalRelease(Clone))
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path))
		AssertTrue(_ConfigWriteTerminalAuthorize(Bundle))
		AssertTrue(_ConfigWriteTerminalClaimShutdown(Bundle))
	} finally AssertTrue(_ConfigWriteTerminalRelease(Bundle))
}
Test("config lease: copied terminal bundles cannot own authorize claim or release", _CWTB_CopiedBundleNeverOwnsOrAuthorizes)

_CWTB_TokenSubstitutionAndMutationRefuse() {
	Path := "C:\ergopti-tests\identity\substitute.toml"
	Bundle := _ConfigWriteTerminalTryAcquire([Path])
	AssertTrue(Bundle is Object)
	Original := Bundle.tokens[1], OriginalArray := Bundle.tokens, OriginalId := Original.id
	try {
		Clone := { key: Original.key, id: Original.id, kind: Original.kind }
		Bundle.tokens[1] := Clone
		AssertFalse(_ConfigWriteTerminalOwnsExact(Bundle, Path), "a same-value token cannot replace the actual native-issued object")
		Bundle.tokens[1] := Original
		Bundle.tokens := [Original]
		AssertFalse(_ConfigWriteTerminalOwnsExact(Bundle, Path), "the original token array is captured by the constructor")
		Bundle.tokens := OriginalArray
		Original.id := OriginalId + 1
		AssertFalse(_ConfigWriteTerminalOwnsExact(Bundle, Path), "mutating an issued scalar does not mutate its private receipt")
		Original.id := OriginalId
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path), "exact restoration leaves the genuine owner live")
	} finally {
		Original.id := OriginalId
		OriginalArray[1] := Original
		Bundle.tokens := OriginalArray
		AssertTrue(_ConfigWriteTerminalRelease(Bundle))
	}
}
Test("config lease: private terminal issuance retains complete object and scalar identity", _CWTB_TokenSubstitutionAndMutationRefuse)

_CWTB_PublicTableReplacementCannotForgeIssuance() {
	Path := "C:\ergopti-tests\identity\public-state.toml"
	Token := _ConfigWriteLeaseTryAcquire(Path, "identity-subject")
	AssertTrue(Token is Object)
	State := _ConfigWriteLeaseState()
	try {
		Clone := { key: Token.key, id: Token.id, kind: Token.kind }
		State.owners[Token.key] := Clone
		AssertFalse(_ConfigWriteLeaseOwns(Clone, Path), "public table replacement is not actual constructor issuance")
		AssertFalse(_ConfigWriteLeaseOwns(Token, Path), "a withdrawn original object cannot retain path ownership")
		State.owners[Token.key] := Token
		AssertTrue(_ConfigWriteLeaseOwns(Token, Path))
	} finally {
		State.owners[Token.key] := Token
		AssertTrue(_ConfigWriteLeaseRelease(Token))
	}
}
Test("config lease: replacing the public owner table cannot manufacture private issuance", _CWTB_PublicTableReplacementCannotForgeIssuance)

_CWTB_PublicWithdrawalDoesNotRetireActualIssuer(Terminal := false) {
	Path := "C:\ergopti-tests\actual-retained-issuer\config.toml"
	Sibling := "C:\ergopti-tests\actual-retained-issuer\sibling.toml"
	Issued := Terminal ? _ConfigWriteTerminalTryAcquire([Path]) : _ConfigWriteLeaseTryAcquire(Path, "retained native source owner")
	AssertTrue(Issued is Object)
	State := _ConfigWriteLeaseState(), Token := Terminal ? Issued.tokens[1] : Issued, Key := Token.key
	try {
		State.owners.Delete(Key)
		if Terminal {
			State.terminal := false
			AssertTrue(_ConfigWriteTerminalIsActive(), "withdrawing public metadata does not retire the actual private barrier")
			AssertFalse(_ConfigWriteLeaseTryAcquire(Sibling, "cannot bypass genuine barrier") is Object)
			AssertFalse(_ConfigWriteTerminalTryAcquire([Sibling]) is Object)
		} else {
			AssertFalse(_ConfigWriteLeaseTryAcquire(Path, "cannot overtake genuine owner") is Object,
				"withdrawing the table entry cannot issue a newer writer around a retained original receipt")
			AssertFalse(_ConfigWriteTerminalTryAcquire([Path]) is Object,
				"a terminal constructor cannot overtake a privately active ordinary issuer after public withdrawal")
		}
		AssertFalse(_ConfigWriteLeaseOwns(Token, Path), "the withdrawn public membership grants no native write permission")
		State.owners[Key] := Token
		if Terminal
			State.terminal := Issued
		AssertTrue(_ConfigWriteLeaseOwns(Token, Path), "repair restores the exact still-issued original, not a fabricated owner")
	} finally {
		State.owners[Key] := Token
		if Terminal {
			State.terminal := Issued
			AssertTrue(_ConfigWriteTerminalRelease(Issued))
		} else
			AssertTrue(_ConfigWriteLeaseRelease(Issued))
	}
}
Test("config lease: withdrawing the public path entry cannot retire an actual native writer",
	_CWTB_PublicWithdrawalDoesNotRetireActualIssuer)
Test("config lease: withdrawing public terminal metadata cannot open an actual native barrier",
	_CWTB_PublicWithdrawalDoesNotRetireActualIssuer.Bind(true))


; Internal active-issuance queries are useful for exclusivity but cannot be
; mistaken for an exact token or bundle by any public ownership predicate.
_CWT_ActivityQueryDoesNotOwn(Terminal := false) {
	static Sequence := 0
	Sequence += 1
	Path := A_Temp . "\ergopti-native-issuer-query-" . A_ScriptHwnd . "-" . Sequence . ".toml"
	Owner := false
	AssertFalse(_ConfigWriteTerminalIsActive(), "this native subject must not borrow a previous terminal owner")
	AssertFalse(_ConfigWriteLeaseTryAcquire("", "", 0), "this native subject must not borrow a previous private ordinary owner")
	try {
		Owner := Terminal ? _ConfigWriteTerminalTryAcquire([Path]) : _ConfigWriteLeaseTryAcquire(Path)
		AssertTrue(Owner is Object, "the actual native issuer must acquire this independent path")
		Token := Terminal ? Owner.tokens[1] : Owner
		AssertTrue(_ConfigWriteLeaseOwns(Token, Path), "the exact actual target retains native authority")
		AssertTrue(Terminal ? _ConfigWriteTerminalTryAcquire([], 0) : _ConfigWriteLeaseTryAcquire("", "", 0),
			"the genuine live private issuance makes its internal activity query true")
		AssertFalse(_ConfigWriteLeaseOwns(0), "a true private activity query is not an issued token")
		AssertFalse(_ConfigWriteLeaseOwns(0, Path), "zero cannot reach a target key dereference")
		AssertFalse(_ConfigWriteTerminalOwnsExact(0, Path), "a true activity query is not an exact terminal bundle")
		AssertFalse(_ConfigWriteTerminalOwnsExact(Token, Path), "a genuine target token does not acquire bundle authority")
		AssertTrue(_ConfigWriteLeaseSelectOwner(Token, Path) == Token,
			"selection preserves an actual ordinary or terminal-member target without treating it as a bundle")
		if Terminal {
			AssertFalse(_ConfigWriteLeaseOwns(Owner, Path), "the exact bundle is distinct from its target token")
			AssertTrue(_ConfigWriteTerminalOwnsExact(Owner, Path), "the real exact bundle retains native authority")
			AssertTrue(_ConfigWriteLeaseSelectOwner(Owner, Path) == Token, "selection resolves the real bundle's exact target")
		}
	} finally {
		if Owner is Object {
			if Terminal
				AssertTrue(_ConfigWriteTerminalRelease(Owner), "the actual bundle must retire through its native release owner")
			else
				AssertTrue(_ConfigWriteLeaseRelease(Owner), "the actual target must retire through its native release owner")
		}
	}
	AssertFalse(_ConfigWriteTerminalIsActive(), "the completed subject cannot leak a native terminal barrier")
	AssertFalse(_ConfigWriteLeaseTryAcquire("", "", 0), "the completed subject cannot leak a private ordinary owner")
}
Test("config issuer: actual ordinary activity query never acquires target or bundle authority", _CWT_ActivityQueryDoesNotOwn)
Test("config issuer: actual terminal activity query and member token never acquire bundle authority", _CWT_ActivityQueryDoesNotOwn.Bind(true))





; ====================================================
; ====================================================
; ======= Issuer-only private custody controls =======
; ====================================================
; ====================================================

_CWTB_IssuerOnlyPath(Tag) {
	static Sequence := 0
	Sequence += 1
	return A_Temp . "\ergopti-issuer-only-" . A_ScriptHwnd . "-" . Sequence . "-" . Tag . ".toml"
}

_CWTB_IssuerOnlyShape() {
	Path := _CWTB_IssuerOnlyPath("shape")
	Bundle := _ConfigWriteTerminalTryAcquire([Path])
	AssertTrue(Bundle is Object)
	try {
		Names := Map()
		Names.CaseSense := "On"
		for Name in ObjOwnProps(Bundle)
			Names[Name] := true
		AssertEqual(5, Names.Count, "the actual native bundle has exactly five own data fields")
		for Name in ["kind", "id", "tokens", "authorized", "shutdown_claimed"] {
			AssertTrue(Names.Has(Name), "the independent native bundle field is present: " . Name)
			AssertTrue(Object.Prototype.GetOwnPropDesc.Call(Bundle, Name).HasOwnProp("Value"))
		}
		AssertTrue(ObjGetBase(Bundle) == Object.Prototype)
		AssertTrue(ObjGetBase(Bundle.tokens) == Array.Prototype)
		AssertEqual(1, Bundle.tokens.Length)
		Token := Bundle.tokens[1]
		TokenNames := Map()
		TokenNames.CaseSense := "On"
		for Name in ObjOwnProps(Token)
			TokenNames[Name] := true
		AssertEqual(3, TokenNames.Count, "the actual native target has exactly three own data fields")
		for Name in ["key", "id", "kind"]
			AssertTrue(TokenNames.Has(Name), "the independent native target field is present: " . Name)
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path))
		AssertTrue(_ConfigWriteLeaseSelectOwner(Bundle, Path) == Token)
	} finally AssertTrue(_ConfigWriteTerminalRelease(Bundle))
	AssertFalse(_ConfigWriteTerminalRelease(Bundle), "native acknowledgment retires the exact bundle once")
}
Test("config issuer only: genuine bundle preserves the independent five-field native ABI", _CWTB_IssuerOnlyShape)

_CWTB_IssuerOnlyGetter(Name, Terminal := false, BundleField := false) {
	Path := _CWTB_IssuerOnlyPath("getter")
	Issued := Terminal ? _ConfigWriteTerminalTryAcquire([Path]) : _ConfigWriteLeaseTryAcquire(Path, "issuer-only getter")
	AssertTrue(Issued is Object)
	Token := Terminal ? Issued.tokens[1] : Issued
	Subject := BundleField ? Issued : Token
	Descriptor := Object.Prototype.GetOwnPropDesc.Call(Subject, Name)
	Original := Descriptor.Value
	Hits := { count: 0 }
	PreviousCritical := Critical("On")
	try {
		Subject.DefineProp(Name, { Get: (*) => (Hits.count += 1, Original) })
		AssertFalse(_ConfigWriteLeaseOwns(Token, Path), "a getter on the originally issued object withdraws native authority")
		AssertFalse(_ConfigWriteLeaseSelectOwner(Issued, Path) is Object)
		if Terminal {
			AssertFalse(_ConfigWriteTerminalOwnsExact(Issued, Path))
			AssertFalse(_ConfigWriteTerminalAuthorize(Issued))
			AssertFalse(_ConfigWriteTerminalClaimShutdown(Issued))
			AssertFalse(_ConfigWriteTerminalCancelShutdown(Issued))
			AssertFalse(_ConfigWriteTerminalRelease(Issued), "failed release cannot retire the private original issuer")
			AssertTrue(_ConfigWriteTerminalIsActive())
		} else {
			AssertFalse(_ConfigWriteLeaseRelease(Issued), "failed release cannot retire the private original token")
			AssertTrue(_ConfigWriteLeaseTryAcquire("", "", 0))
		}
		AssertEqual(0, Hits.count, "intrinsic descriptor refusal must precede every public getter")
		Subject.DefineProp(Name, Descriptor)
		AssertTrue(_ConfigWriteLeaseOwns(Token, Path), "exact same-object data repair restores the still-issued token")
		AssertTrue(_ConfigWriteLeaseSelectOwner(Issued, Path) == Token)
		if Terminal {
			AssertTrue(_ConfigWriteTerminalOwnsExact(Issued, Path))
			AssertTrue(_ConfigWriteTerminalAuthorize(Issued))
			AssertTrue(_ConfigWriteTerminalClaimShutdown(Issued))
			AssertTrue(_ConfigWriteTerminalCancelShutdown(Issued))
		}
		AssertEqual(0, Hits.count)
	} finally {
		Subject.DefineProp(Name, Descriptor)
		try {
			if Terminal
				AssertTrue(_ConfigWriteTerminalRelease(Issued))
			else
				AssertTrue(_ConfigWriteLeaseRelease(Issued))
		} finally Critical(PreviousCritical)
	}
}
for Name in ["key", "id", "kind"] {
	Test("config issuer only: actual ordinary getter refuses before invocation " . Name,
		_CWTB_IssuerOnlyGetter.Bind(Name))
	Test("config issuer only: actual terminal target getter refuses before invocation " . Name,
		_CWTB_IssuerOnlyGetter.Bind(Name, true))
}
for Name in ["kind", "id", "tokens", "authorized", "shutdown_claimed"]
	Test("config issuer only: actual whole bundle getter refuses before invocation " . Name,
		_CWTB_IssuerOnlyGetter.Bind(Name, true, true))

_CWTB_IssuerOnlyExtraField(Terminal := false, BundleField := false) {
	Path := _CWTB_IssuerOnlyPath("extra-field")
	Issued := Terminal ? _ConfigWriteTerminalTryAcquire([Path]) : _ConfigWriteLeaseTryAcquire(Path, "issuer-only extra field")
	AssertTrue(Issued is Object)
	Token := Terminal ? Issued.tokens[1] : Issued
	Subject := BundleField ? Issued : Token
	PreviousCritical := Critical("On")
	try {
		Subject.UnexpectedIssuerMetadata := true
		AssertFalse(_ConfigWriteLeaseOwns(Token, Path), "extra own metadata cannot decorate a genuine native capability")
		AssertFalse(_ConfigWriteLeaseSelectOwner(Issued, Path) is Object)
		if Terminal {
			AssertFalse(_ConfigWriteTerminalOwnsExact(Issued, Path))
			AssertFalse(_ConfigWriteTerminalAuthorize(Issued))
			AssertFalse(_ConfigWriteTerminalClaimShutdown(Issued))
			AssertFalse(_ConfigWriteTerminalRelease(Issued))
			AssertTrue(_ConfigWriteTerminalIsActive(), "refused decorated release leaves the actual issuer active")
		} else {
			AssertFalse(_ConfigWriteLeaseRelease(Issued))
			AssertTrue(_ConfigWriteLeaseTryAcquire("", "", 0))
		}
		Subject.DeleteProp("UnexpectedIssuerMetadata")
		AssertTrue(_ConfigWriteLeaseOwns(Token, Path), "exact metadata removal repairs the same still-issued owner")
	} finally {
		if Object.Prototype.HasOwnProp.Call(Subject, "UnexpectedIssuerMetadata")
			Subject.DeleteProp("UnexpectedIssuerMetadata")
		try {
			if Terminal
				AssertTrue(_ConfigWriteTerminalRelease(Issued))
			else
				AssertTrue(_ConfigWriteLeaseRelease(Issued))
		} finally Critical(PreviousCritical)
	}
}
Test("config issuer only: extra ordinary metadata refuses without retiring debt", _CWTB_IssuerOnlyExtraField)
Test("config issuer only: extra terminal target metadata refuses without retiring debt", _CWTB_IssuerOnlyExtraField.Bind(true))
Test("config issuer only: extra whole bundle metadata refuses without retiring debt", _CWTB_IssuerOnlyExtraField.Bind(true, true))

_CWTB_IssuerOnlyRetiredOriginal(Terminal := false) {
	Path := _CWTB_IssuerOnlyPath("retired-original")
	Issued := Terminal ? _ConfigWriteTerminalTryAcquire([Path]) : _ConfigWriteLeaseTryAcquire(Path, "issuer-only retirement")
	AssertTrue(Issued is Object)
	Token := Terminal ? Issued.tokens[1] : Issued
	Key := Token.key
	State := _ConfigWriteLeaseState()
	Released := false
	Fresh := 0
	PreviousCritical := Critical("On")
	try {
		AssertTrue(Terminal ? _ConfigWriteTerminalRelease(Issued) : _ConfigWriteLeaseRelease(Issued))
		Released := true
		AssertFalse(Terminal ? _ConfigWriteTerminalRelease(Issued) : _ConfigWriteLeaseRelease(Issued),
			"repeated native release never acknowledges a retired issuer")
		AssertFalse(State.owners.Has(Key), "the native acknowledgment removes this exact public path membership")
		State.owners[Key] := Token
		if Terminal
			State.terminal := Issued
		AssertFalse(_ConfigWriteLeaseOwns(Token, Path), "public reinsertion of the same original never restores private issuance")
		AssertFalse(_ConfigWriteLeaseSelectOwner(Issued, Path) is Object)
		if Terminal {
			AssertFalse(_ConfigWriteTerminalOwnsExact(Issued, Path))
			AssertFalse(_ConfigWriteTerminalAuthorize(Issued))
			AssertFalse(_ConfigWriteTerminalClaimShutdown(Issued))
			AssertFalse(_ConfigWriteTerminalCancelShutdown(Issued))
			AssertFalse(_ConfigWriteTerminalRelease(Issued))
			AssertFalse(_ConfigWriteTerminalIsActive(), "public reinsertion cannot revive the private terminal receipt")
			State.terminal := false
		} else {
			AssertFalse(_ConfigWriteLeaseRelease(Issued))
			AssertFalse(_ConfigWriteLeaseTryAcquire("", "", 0), "retired ordinary receipts do not remain privately active")
		}
		State.owners.Delete(Key)
		Fresh := Terminal ? _ConfigWriteTerminalTryAcquire([Path]) : _ConfigWriteLeaseTryAcquire(Path, "issuer-only fresh successor")
		AssertTrue(Fresh is Object, "a genuine new issuer follows exact test-owned public cleanup")
		AssertFalse(Fresh == Issued)
		FreshToken := Terminal ? Fresh.tokens[1] : Fresh
		AssertTrue(_ConfigWriteLeaseOwns(FreshToken, Path))
		AssertFalse(_ConfigWriteLeaseOwns(Token, Path), "new issuance cannot resurrect the retired predecessor")
		AssertFalse(Terminal ? _ConfigWriteTerminalRelease(Issued) : _ConfigWriteLeaseRelease(Issued),
			"late predecessor release cannot retire the new genuine owner")
		AssertTrue(_ConfigWriteLeaseOwns(FreshToken, Path))
	} finally {
		try {
			if Released {
				if State.owners.Has(Key) && State.owners[Key] == Token
					State.owners.Delete(Key)
				if Terminal && State.terminal == Issued
					State.terminal := false
			} else {
				if Terminal
					AssertTrue(_ConfigWriteTerminalRelease(Issued))
				else
					AssertTrue(_ConfigWriteLeaseRelease(Issued))
			}
			if Fresh is Object {
				if Terminal
					AssertTrue(_ConfigWriteTerminalRelease(Fresh))
				else
					AssertTrue(_ConfigWriteLeaseRelease(Fresh))
			}
		} finally Critical(PreviousCritical)
	}
}
Test("config issuer only: retired ordinary original cannot regain authority or retire its successor", _CWTB_IssuerOnlyRetiredOriginal)
Test("config issuer only: retired terminal original cannot regain authority or retire its successor", _CWTB_IssuerOnlyRetiredOriginal.Bind(true))

_CWTB_IssuerOnlyReleaseRetry(Terminal := false) {
	Path := _CWTB_IssuerOnlyPath("release-retry")
	Sibling := _CWTB_IssuerOnlyPath("release-retry-sibling")
	Issued := Terminal ? _ConfigWriteTerminalTryAcquire([Path]) : _ConfigWriteLeaseTryAcquire(Path, "issuer-only failed release")
	AssertTrue(Issued is Object)
	Token := Terminal ? Issued.tokens[1] : Issued
	Key := Token.key
	State := _ConfigWriteLeaseState()
	Released := false
	PreviousCritical := Critical("On")
	try {
		State.owners.Delete(Key)
		if Terminal
			State.terminal := false
		AssertFalse(Terminal ? _ConfigWriteTerminalRelease(Issued) : _ConfigWriteLeaseRelease(Issued),
			"withdrawn public custody must refuse instead of acknowledging release")
		AssertFalse(_ConfigWriteLeaseOwns(Token, Path))
		if Terminal {
			AssertTrue(_ConfigWriteTerminalIsActive(), "failed release keeps actual private terminal debt")
			AssertFalse(_ConfigWriteLeaseTryAcquire(Sibling) is Object)
		} else {
			AssertTrue(_ConfigWriteLeaseTryAcquire("", "", 0), "failed release keeps actual private ordinary debt")
			AssertFalse(_ConfigWriteLeaseTryAcquire(Path) is Object)
		}
		AssertFalse(_ConfigWriteTerminalTryAcquire([Sibling]) is Object)
		State.owners[Key] := Token
		if Terminal
			State.terminal := Issued
		AssertTrue(_ConfigWriteLeaseOwns(Token, Path), "only the exact still-issued repair can discharge debt")
		AssertTrue(Terminal ? _ConfigWriteTerminalRelease(Issued) : _ConfigWriteLeaseRelease(Issued))
		Released := true
		AssertFalse(State.owners.Has(Key))
		AssertFalse(Terminal ? _ConfigWriteTerminalRelease(Issued) : _ConfigWriteLeaseRelease(Issued))
		AssertFalse(_ConfigWriteTerminalIsActive())
		AssertFalse(_ConfigWriteLeaseTryAcquire("", "", 0), "successful retry removes private active path debt")
	} finally {
		try {
			if !Released {
				State.owners[Key] := Token
				if Terminal
					State.terminal := Issued
				if Terminal
					AssertTrue(_ConfigWriteTerminalRelease(Issued))
				else
					AssertTrue(_ConfigWriteLeaseRelease(Issued))
			}
		} finally Critical(PreviousCritical)
	}
}
Test("config issuer only: failed ordinary release retains debt until the exact genuine retry", _CWTB_IssuerOnlyReleaseRetry)
Test("config issuer only: failed terminal release retains debt until the exact genuine retry", _CWTB_IssuerOnlyReleaseRetry.Bind(true))

_CWTB_IssuerOnlyArrayObserver(Name) {
	Path := _CWTB_IssuerOnlyPath("array-observer")
	Bundle := _ConfigWriteTerminalTryAcquire([Path])
	AssertTrue(Bundle is Object)
	Tokens := Bundle.tokens
	Length := Tokens.Length
	Hits := { count: 0 }
	PreviousCritical := Critical("On")
	try {
		if Name == "__Enum"
			Tokens.DefineProp(Name, { Call: (This, Arity) =>
				(Hits.count += 1, Array.Prototype.__Enum.Call(This, Arity)) })
		else Tokens.DefineProp(Name, { Get: (*) => (Hits.count += 1, Length) })
		AssertFalse(_ConfigWriteTerminalOwnsExact(Bundle, Path))
		AssertFalse(_ConfigWriteLeaseSelectOwner(Bundle, Path) is Object)
		AssertFalse(_ConfigWriteTerminalAuthorize(Bundle))
		AssertFalse(_ConfigWriteTerminalClaimShutdown(Bundle))
		AssertFalse(_ConfigWriteTerminalRelease(Bundle), "a public token-array observer cannot retire the private issuer")
		AssertTrue(_ConfigWriteTerminalIsActive())
		AssertEqual(0, Hits.count, "intrinsic token-array refusal precedes public enumeration or length")
		Tokens.DeleteProp(Name)
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path), "exact original array repair restores the same native bundle")
		AssertTrue(_ConfigWriteTerminalAuthorize(Bundle))
		AssertTrue(_ConfigWriteTerminalClaimShutdown(Bundle))
		AssertTrue(_ConfigWriteTerminalCancelShutdown(Bundle))
		AssertEqual(0, Hits.count)
	} finally {
		if Object.Prototype.HasOwnProp.Call(Tokens, Name)
			Tokens.DeleteProp(Name)
		try AssertTrue(_ConfigWriteTerminalRelease(Bundle))
		finally Critical(PreviousCritical)
	}
}
for Name in ["__Enum", "Length"]
	Test("config issuer only: original token array observer refuses before invocation " . Name,
		_CWTB_IssuerOnlyArrayObserver.Bind(Name))
