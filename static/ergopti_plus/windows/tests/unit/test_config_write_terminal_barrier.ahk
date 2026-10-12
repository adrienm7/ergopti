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

_CWTB_GenuineOwnerGetter(Name, Terminal := false, BundleField := false) {
	global ConfigurationFile
	OldPath := IsSet(ConfigurationFile) ? ConfigurationFile : unset
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml", Source := _CMJ_CurrentSource()
	Hits := { count: 0 }, Publication := { build: 0, publish: 0, runtime: "@" }
	Issued := 0, Owner := 0
	try {
		ConfigurationFile := Path
		AssertTrue(FSWriteDurable(Path, Source))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Issued := Terminal ? _ConfigWriteTerminalTryAcquire([Path]) : _ConfigWriteLeaseTryAcquire(Path, "genuine getter subject")
		AssertTrue(Issued is Object, "the actual native issuer creates the subject")
		Token := Terminal ? Issued.tokens[1] : Issued
		Owner := BundleField ? Issued : Token
		Descriptor := Object.Prototype.GetOwnPropDesc.Call(Owner, Name)
		Original := Descriptor.Value
		Owner.DefineProp(Name, { Get: (*) => (Hits.count += 1, Original) })
		AssertFalse(_ConfigWriteLeaseOwns(Token, Path), "an original issued object with a getter is no longer pure authority")
		AssertFalse(FSNativeAcknowledge(() => _ConfigWriteLeaseOwns(Token, Path)),
			"the actual native final noop invokes no public owner getter")
		if Terminal
			AssertFalse(_ConfigWriteTerminalOwnsExact(Issued, Path))
		AssertFalse(_CMJ_PurityNativeGateway(Path, Publication, Issued),
			"the actual borrowed gateway refuses before candidate construction/runtime publication")
		AssertEqual(0, Hits.count, "no getter executes before exact private owner refusal")
		AssertEqual(0, Publication.build), AssertEqual(0, Publication.publish), AssertEqual("@", Publication.runtime)
		AssertTrue(FSUtf8ExactMatches(Path, Source))
		Owner.DefineProp(Name, Descriptor)
		AssertTrue(_ConfigWriteLeaseOwns(Token, Path), "exact original data-descriptor repair restores the genuine lease")
		AssertTrue(FSNativeAcknowledge(() => _ConfigWriteLeaseOwns(Token, Path)))
		AssertTrue(_CMJ_PurityNativeGateway(Path, Publication, Issued), "the same actual borrowed default native writer remains live after repair")
		AssertEqual(1, Publication.build), AssertEqual(1, Publication.publish), AssertEqual("!", Publication.runtime)
		AssertEqual("!", TOML_ParseDocument(FSReadUtf8Exact(Path))["hotstrings"]["trigger_char"])
		AssertEqual(0, Hits.count)
	} finally {
		if Owner is Object
			Owner.DefineProp(Name, Descriptor)
		if Issued is Object {
			if Terminal
				AssertTrue(_ConfigWriteTerminalRelease(Issued))
			else
				AssertTrue(_ConfigWriteLeaseRelease(Issued))
		}
		ConfigurationFile := IsSet(OldPath) ? OldPath : unset
		_CMJ_Cleanup(Dir, Path)
	}
}
for Name in ["key", "id", "kind"] {
	Test("config lease: actual ordinary token data getter refuses without invocation " . Name,
		_CWTB_GenuineOwnerGetter.Bind(Name))
	Test("config lease: actual terminal token data getter refuses without invocation " . Name,
		_CWTB_GenuineOwnerGetter.Bind(Name, true))
}
for Name in ["id", "kind", "tokens", "authorized", "shutdown_claimed"]
	Test("config lease: actual terminal bundle data getter refuses without invocation " . Name,
		_CWTB_GenuineOwnerGetter.Bind(Name, true, true))

_CWTB_GenuineTokenArrayObserver(Name) {
	Path := "C:\ergopti-tests\actual-array-observer\config.toml"
	Bundle := _ConfigWriteTerminalTryAcquire([Path])
	AssertTrue(Bundle is Object)
	Tokens := Bundle.tokens, Hits := { count: 0 }
	try {
		if Name == "__Enum"
			Tokens.DefineProp(Name, { Call: (This, Arity) =>
				(Hits.count += 1, Array.Prototype.__Enum.Call(This, Arity)) })
		else {
			Length := Tokens.Length
			Tokens.DefineProp(Name, { Get: (*) => (Hits.count += 1, Length) })
		}
		AssertFalse(_ConfigWriteTerminalOwnsExact(Bundle, Path))
		AssertFalse(FSNativeAcknowledge(() => _ConfigWriteTerminalOwnsExact(Bundle, Path)))
		AssertEqual(0, Hits.count, "the genuine issued token array cannot run public iterator/length observers")
		Tokens.DeleteProp(Name)
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path), "the same original array remains usable after exact repair")
		AssertTrue(FSNativeAcknowledge(() => _ConfigWriteTerminalOwnsExact(Bundle, Path)))
		AssertEqual(0, Hits.count)
	} finally {
		if Object.Prototype.HasOwnProp.Call(Tokens, Name)
			Tokens.DeleteProp(Name)
		AssertTrue(_ConfigWriteTerminalRelease(Bundle))
	}
}
for Name in ["__Enum", "Length"]
	Test("config lease: genuine token array observer cannot run inside final native guard " . Name,
		_CWTB_GenuineTokenArrayObserver.Bind(Name))

_CWTB_RetiredOriginalCannotResurrect(Terminal := false) {
	global ConfigurationFile
	OldPath := IsSet(ConfigurationFile) ? ConfigurationFile : unset
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml", Source := _CMJ_CurrentSource()
	Publication := { build: 0, publish: 0, runtime: "@" }, Issued := 0
	try {
		ConfigurationFile := Path
		AssertTrue(FSWriteDurable(Path, Source))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Issued := Terminal ? _ConfigWriteTerminalTryAcquire([Path]) : _ConfigWriteLeaseTryAcquire(Path, "retirement subject")
		AssertTrue(Issued is Object)
		Token := Terminal ? Issued.tokens[1] : Issued, Key := Token.key
		State := _ConfigWriteLeaseState()
		AssertTrue(Terminal ? _ConfigWriteTerminalRelease(Issued) : _ConfigWriteLeaseRelease(Issued),
			"actual native release must retire its private issuance")
		State.owners[Key] := Token
		if Terminal
			State.terminal := Issued
		AssertFalse(_ConfigWriteLeaseOwns(Token, Path), "reinserting the SAME retired original cannot resurrect private issuance")
		AssertFalse(FSNativeAcknowledge(() => _ConfigWriteLeaseOwns(Token, Path)))
		AssertFalse(_CMJ_PurityNativeGateway(Path, Publication, Issued), "retired originals refuse the actual borrowed native writer")
		AssertEqual(0, Publication.build), AssertEqual(0, Publication.publish), AssertEqual("@", Publication.runtime)
		AssertTrue(FSUtf8ExactMatches(Path, Source))
		if Terminal {
			AssertFalse(_ConfigWriteTerminalOwnsExact(Issued, Path))
			AssertFalse(_ConfigWriteTerminalAuthorize(Issued)), AssertFalse(_ConfigWriteTerminalClaimShutdown(Issued))
			State.terminal := false
		}
		State.owners.Delete(Key)
		Fresh := _ConfigWriteLeaseTryAcquire(Path, "genuine successor after retired original")
		AssertTrue(Fresh is Object), AssertFalse(Fresh == Token)
		try {
			AssertTrue(_ConfigWriteLeaseOwns(Fresh, Path))
			AssertTrue(_CMJ_PurityNativeGateway(Path, Publication, Fresh), "a genuinely new issuance remains usable after exact cleanup")
			AssertEqual(1, Publication.publish), AssertEqual("!", Publication.runtime)
		} finally AssertTrue(_ConfigWriteLeaseRelease(Fresh))
	} finally {
		if IsSet(State) && IsSet(Key) {
			if State.owners.Has(Key) && State.owners[Key] == Token
				State.owners.Delete(Key)
			if Terminal && State.terminal == Issued
				State.terminal := false
		}
		ConfigurationFile := IsSet(OldPath) ? OldPath : unset
		_CMJ_Cleanup(Dir, Path)
	}
}
Test("config lease: reinserting the same retired ordinary original never resurrects authority",
	_CWTB_RetiredOriginalCannotResurrect)
Test("config lease: reinserting the same retired terminal original never resurrects authority",
	_CWTB_RetiredOriginalCannotResurrect.Bind(true))

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


; ==============================================================================
; Direct native selector guards
; ==============================================================================
; The optimized scan must preserve the original fallback and whole-bundle
; authority. These controls use genuine memory-only issuance and exact release;
; late-boundary fault instrumentation remains separate receiving evidence.

_CWTS_Bundle() {
	return _ConfigWriteTerminalTryAcquire([A_Temp . "\sop-first.toml",
		A_Temp . "\sop-middle.toml", A_Temp . "\sop-last.toml"])
}
_CWTS_Positions() {
	CWTSBundle := _CWTS_Bundle()
	AssertTrue(CWTSBundle is Object)
	try {
		for CWTSToken in CWTSBundle.tokens
			AssertTrue(_ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSToken.key) == CWTSToken,
				"each real first/middle/last member preserves exact identity")
		AssertFalse(_ConfigWriteLeaseSelectOwner(CWTSBundle, A_Temp . "\sop-missing.toml"))
		CWTSToken := CWTSBundle.tokens[3]
		AssertTrue(_ConfigWriteLeaseSelectOwner(CWTSToken, CWTSToken.key) == CWTSToken,
			"a genuine member stays an original fallback target, not a bundle")
	} finally AssertTrue(_ConfigWriteTerminalRelease(CWTSBundle))
	AssertFalse(_ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSToken.key))
	CWTSOrdinary := _ConfigWriteLeaseTryAcquire(A_Temp . "\sop-ordinary.toml", "actual ordinary fallback")
	AssertTrue(CWTSOrdinary is Object)
	try AssertTrue(_ConfigWriteLeaseSelectOwner(CWTSOrdinary, A_Temp . "\sop-ordinary.toml") == CWTSOrdinary)
	finally AssertTrue(_ConfigWriteLeaseRelease(CWTSOrdinary))
}
_CWTS_Sibling(CWTSField) {
	CWTSBundle := _CWTS_Bundle(), CWTSHits := {count: 0}
	AssertTrue(CWTSBundle is Object)
	CWTSSibling := false, CWTSTarget := false, CWTSKey := "", CWTSDescriptor := false, CWTSChanged := false
	try {
		CWTSSibling := CWTSBundle.tokens[1], CWTSTarget := CWTSBundle.tokens[3], CWTSKey := CWTSSibling.key
		if CWTSField != "owners" && CWTSField != "extra"
			CWTSDescriptor := Object.Prototype.GetOwnPropDesc.Call(CWTSSibling, CWTSField)
		if CWTSField == "owners"
			_ConfigWriteLeaseState().owners.Delete(CWTSKey)
		else if CWTSField == "extra"
			CWTSSibling.extra := true
		else
			CWTSSibling.DefineProp(CWTSField, {Get: (*) => (CWTSHits.count += 1, "foreign observed value")})
		CWTSChanged := true
		AssertFalse(_ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSTarget.key),
			"a nonmatching sibling withdraws the entire actual bundle")
		AssertEqual(0, CWTSHits.count, "descriptor rejection precedes every untrusted sibling getter")
	} finally {
		try {
			if CWTSChanged {
				if CWTSField == "owners"
					_ConfigWriteLeaseState().owners[CWTSKey] := CWTSSibling
				else if CWTSField == "extra"
					CWTSSibling.DeleteProp("extra")
				else
					CWTSSibling.DefineProp(CWTSField, CWTSDescriptor)
				AssertTrue(_ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSTarget.key) == CWTSTarget,
					"exact sibling repair restores this same original bundle")
			}
		} finally AssertTrue(_ConfigWriteTerminalRelease(CWTSBundle))
	}
}
_CWTS_Array(CWTSMode) {
	CWTSBundle := _CWTS_Bundle(), CWTSHits := {count: 0}
	AssertTrue(CWTSBundle is Object)
	CWTSOriginal := false, CWTSTarget := false, CWTSChanged := false
	try {
		CWTSOriginal := CWTSBundle.tokens, CWTSTarget := CWTSOriginal[3]
		if CWTSMode == "clone"
			CWTSBundle.tokens := CWTSOriginal.Clone()
		else if CWTSMode == "Length"
			CWTSOriginal.DefineProp("Length", {Get: (*) => (CWTSHits.count += 1, 3)})
		else
			CWTSOriginal.DefineProp("__Enum", {Call: (*) => (CWTSHits.count += 1, false)})
		CWTSChanged := true
		AssertFalse(_ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSTarget.key),
			"equal contents do not replace the privately issued array or its intrinsic interface")
		AssertEqual(0, CWTSHits.count, "array rejection invokes no observer")
	} finally {
		try {
			if CWTSChanged {
				if CWTSMode != "clone"
					CWTSOriginal.DeleteProp(CWTSMode)
				CWTSBundle.tokens := CWTSOriginal
				AssertTrue(_ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSTarget.key) == CWTSTarget)
			}
		} finally AssertTrue(_ConfigWriteTerminalRelease(CWTSBundle))
	}
}
_CWTS_ObjectPath() {
	CWTSBundle := _CWTS_Bundle(), CWTSHits := {count: 0}
	AssertTrue(CWTSBundle is Object)
	try {
		CWTSTarget := CWTSBundle.tokens[3], CWTSPath := {}
		CWTSPath.DefineProp("ToString", {Call: (*) => (CWTSHits.count += 1, CWTSTarget.key)})
		AssertTrue(_ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSPath) == CWTSTarget)
		AssertEqual(3, CWTSHits.count,
			"object conversion preserves the original per-candidate order and count")
		CWTSPath.DefineProp("ToString", {Call: (*) => (CWTSHits.count += 1, _CWTS_ConversionThrow())})
		AssertThrows(() => _ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSPath))
		AssertEqual(4, CWTSHits.count, "the original first conversion exception propagates")
	} finally AssertTrue(_ConfigWriteTerminalRelease(CWTSBundle))
}
_CWTS_ConversionThrow() {
	throw Error("Owned object path conversion refused.")
}
_CWTS_Critical(CWTSSetting) {
	CWTSBundle := _CWTS_Bundle()
	AssertTrue(CWTSBundle is Object)
	CWTSOldCritical := A_IsCritical
	try {
		Critical(CWTSSetting)
		CWTSTarget := CWTSBundle.tokens[3]
		CWTSIncoming := A_IsCritical
		AssertTrue(_ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSTarget.key) == CWTSTarget)
		AssertEqual(CWTSIncoming, A_IsCritical, "success preserves incoming Critical")
		AssertFalse(_ConfigWriteLeaseSelectOwner(CWTSBundle, A_Temp . "\sop-no-match.toml"))
		AssertEqual(CWTSIncoming, A_IsCritical, "no match preserves incoming Critical")
		CWTSSavedId := CWTSBundle.tokens[1].id
		CWTSBundle.tokens[1].id += 1
		try {
			AssertFalse(_ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSTarget.key))
			AssertEqual(CWTSIncoming, A_IsCritical, "refusal preserves incoming Critical")
		} finally CWTSBundle.tokens[1].id := CWTSSavedId
		CWTSPath := {}
		CWTSPath.DefineProp("ToString", {Call: (*) => _CWTS_ConversionThrow()})
		AssertThrows(() => _ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSPath))
		AssertEqual(CWTSIncoming, A_IsCritical, "throw preserves incoming Critical")
	} finally {
		try AssertTrue(_ConfigWriteTerminalRelease(CWTSBundle))
		finally Critical(CWTSOldCritical)
	}
}
Test("Select actual issuer: first middle last missing and ordinary member retired fallback", _CWTS_Positions)
Test("Select actual issuer: nonmatching key getter refuses without invocation", _CWTS_Sibling.Bind("key"))
Test("Select actual issuer: nonmatching id getter refuses without invocation", _CWTS_Sibling.Bind("id"))
Test("Select actual issuer: nonmatching kind getter refuses without invocation", _CWTS_Sibling.Bind("kind"))
Test("Select actual issuer: nonmatching extra metadata refuses", _CWTS_Sibling.Bind("extra"))
Test("Select actual issuer: nonmatching owner membership withdrawal refuses", _CWTS_Sibling.Bind("owners"))
Test("Select actual issuer: equal-content token array replacement refuses", _CWTS_Array.Bind("clone"))
Test("Select actual issuer: token array Length observer refuses without invocation", _CWTS_Array.Bind("Length"))
Test("Select actual issuer: token array enumeration observer refuses without invocation", _CWTS_Array.Bind("__Enum"))
Test("Select actual issuer: object path fallback preserves conversion count and exception", _CWTS_ObjectPath)
Test("Select actual issuer: Critical off restoration on success miss refusal and throw", _CWTS_Critical.Bind(0))
Test("Select actual issuer: Critical nonzero restoration on success miss refusal and throw", _CWTS_Critical.Bind(10))

_CWTS_SiblingScalar(CWTSField, CWTSValue) {
	CWTSBundle := _CWTS_Bundle()
	AssertTrue(CWTSBundle is Object)
	CWTSSibling := false, CWTSTarget := false, CWTSDescriptor := false, CWTSChanged := false
	try {
		CWTSSibling := CWTSBundle.tokens[1], CWTSTarget := CWTSBundle.tokens[3]
		CWTSDescriptor := Object.Prototype.GetOwnPropDesc.Call(CWTSSibling, CWTSField)
		CWTSSibling.DefineProp(CWTSField, {Value: CWTSValue})
		CWTSChanged := true
		AssertFalse(_ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSTarget.key),
			"nonmatching scalar mutation or type substitution invalidates complete private custody")
	} finally {
		try {
			if CWTSChanged {
				CWTSSibling.DefineProp(CWTSField, CWTSDescriptor)
				AssertTrue(_ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSTarget.key) == CWTSTarget)
			}
		} finally AssertTrue(_ConfigWriteTerminalRelease(CWTSBundle))
	}
}
_CWTS_SiblingCase() {
	CWTSBundle := _CWTS_Bundle()
	AssertTrue(CWTSBundle is Object)
	CWTSSibling := false, CWTSTarget := false, CWTSBefore := "", CWTSChanged := false
	try {
		CWTSSibling := CWTSBundle.tokens[1], CWTSTarget := CWTSBundle.tokens[3], CWTSBefore := CWTSSibling.key
		AssertTrue(!(StrUpper(CWTSBefore) == CWTSBefore), "the real key has a distinct uppercase spelling")
		CWTSSibling.key := StrUpper(CWTSBefore)
		CWTSChanged := true
		AssertFalse(_ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSTarget.key),
			"receipt case identity stays strict even when normalized aliases match")
	} finally {
		try {
			if CWTSChanged {
				CWTSSibling.key := CWTSBefore
				AssertTrue(_ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSTarget.key) == CWTSTarget)
			}
		} finally AssertTrue(_ConfigWriteTerminalRelease(CWTSBundle))
	}
}
_CWTS_ForgedShape() {
	CWTSBundle := _CWTS_Bundle()
	AssertTrue(CWTSBundle is Object)
	try {
		CWTSTarget := CWTSBundle.tokens[3]
		CWTSClone := {id: CWTSBundle.id, kind: CWTSBundle.kind, tokens: CWTSBundle.tokens,
			authorized: CWTSBundle.authorized, shutdown_claimed: CWTSBundle.shutdown_claimed}
		AssertTrue(_ConfigWriteLeaseDataObject(CWTSClone,
			["id", "kind", "tokens", "authorized", "shutdown_claimed"]))
		AssertFalse(_ConfigWriteLeaseSelectOwner(CWTSClone, CWTSTarget.key),
			"pure five-field eligibility never grants the original issuer's authority")
		AssertTrue(_ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSTarget.key) == CWTSTarget)
	} finally AssertTrue(_ConfigWriteTerminalRelease(CWTSBundle))
}
_CWTS_Ledger() {
	CWTSState := _ConfigWriteLeaseState(), CWTSReads := _FileReadActivityState()
	AssertFalse(_ConfigWriteTerminalTryAcquire([], 0), "the genuine private terminal issuer is naturally retired")
	AssertFalse(_ConfigWriteLeaseTryAcquire("", "", 0), "the genuine private ordinary issuer is naturally retired")
	AssertEqual(0, CWTSState.owners.Count, "no public owner remains after actual release")
	AssertFalse(CWTSState.terminal is Object)
	AssertEqual(0, CWTSReads.owners.Count)
	AssertEqual(0, CWTSReads.paths.Count)
}
Test("Select actual issuer: nonmatching key scalar mutation refuses", _CWTS_SiblingScalar.Bind("key", "foreign-key"))
Test("Select actual issuer: nonmatching id scalar mutation refuses", _CWTS_SiblingScalar.Bind("id", 0))
Test("Select actual issuer: nonmatching kind scalar mutation refuses", _CWTS_SiblingScalar.Bind("kind", "ordinary"))
Test("Select actual issuer: nonmatching key object type refuses", _CWTS_SiblingScalar.Bind("key", {}))
Test("Select actual issuer: nonmatching id string type refuses", _CWTS_SiblingScalar.Bind("id", "1"))
Test("Select actual issuer: nonmatching kind integer type refuses", _CWTS_SiblingScalar.Bind("kind", 0))
Test("Select actual issuer: nonmatching key case mutation refuses", _CWTS_SiblingCase)
Test("Select actual issuer: forged five-field shape cannot manufacture native issuance", _CWTS_ForgedShape)


_CWTS_Producer(CWTSProducer, CWTSExpectedCalls, CWTSReturnsOriginal) {
	CWTSBundle := _CWTS_Bundle(), CWTSHits := {count: 0}
	AssertTrue(CWTSBundle is Object)
	CWTSTarget := false, CWTSPath := "", CWTSHadCall := false, CWTSSavedCall := false, CWTSChanged := false
	try {
		CWTSTarget := CWTSBundle.tokens[3], CWTSPath := CWTSTarget.key
		AssertTrue(_ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSPath) == CWTSTarget,
			"every producer control starts with genuine native authority")
		CWTSIncoming := A_IsCritical
		CWTSHadCall := Object.Prototype.HasOwnProp.Call(CWTSProducer, "Call")
		CWTSSavedCall := CWTSHadCall ? Object.Prototype.GetOwnPropDesc.Call(CWTSProducer, "Call") : false
		CWTSProducer.DefineProp("Call", {Call: (*) => (CWTSHits.count += 1, false)})
		CWTSChanged := true
		CWTSReturned := _ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSPath)
		AssertEqual(CWTSExpectedCalls, CWTSHits.count,
			"pre-call withdrawal preserves the original fallback dispatch count")
		if CWTSReturnsOriginal
			AssertTrue(CWTSReturned == CWTSTarget, "an unused ordinary issuer preserves this terminal owner")
		else
			AssertFalse(CWTSReturned, "a used producer refuses without inventing an owner")
		AssertEqual(CWTSIncoming, A_IsCritical, "producer fallback preserves incoming Critical")
	} finally {
		try {
			if CWTSChanged {
				if CWTSHadCall
					CWTSProducer.DefineProp("Call", CWTSSavedCall)
				else
					CWTSProducer.DeleteProp("Call")
				AssertTrue(_ConfigWriteLeaseSelectOwner(CWTSBundle, CWTSPath) == CWTSTarget,
					"exact producer repair restores the same native authority")
			}
		} finally AssertTrue(_ConfigWriteTerminalRelease(CWTSBundle))
	}
}
Test("Select actual producer: eligibility own Call owns",
	_CWTS_Producer.Bind(_ConfigWriteLeaseOwns, 3, false))
Test("Select actual producer: eligibility own Call issuer",
	_CWTS_Producer.Bind(_ConfigWriteTerminalTryAcquire, 1, false))
Test("Select actual producer: eligibility own Call target",
	_CWTS_Producer.Bind(_ConfigWriteLeaseTryAcquire, 0, true))
Test("Select actual producer: eligibility own Call state",
	_CWTS_Producer.Bind(_ConfigWriteLeaseState, 1, false))
Test("Select actual producer: eligibility own Call data",
	_CWTS_Producer.Bind(_ConfigWriteLeaseDataObject, 2, false))
Test("Select actual producer: eligibility own Call container",
	_CWTS_Producer.Bind(_ConfigWriteLeasePlainContainer, 1, false))
Test("Select actual producer: eligibility own Call state_data",
	_CWTS_Producer.Bind(_ConfigWriteLeaseStateIsData, 1, false))
Test("Select actual producer: eligibility own Call key",
	_CWTS_Producer.Bind(_ConfigWriteLeaseKey, 3, false))
Test("Select actual producer: eligibility own Call read_key",
	_CWTS_Producer.Bind(FileReadActivityKey, 3, false))
Test("Select actual issuer: genuine release naturally retires all lease and read state", _CWTS_Ledger)
