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
