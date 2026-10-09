; tests/meta/test_config_boot_read_failure_blocks_persist.ahk

; ==============================================================================
; MODULE: Regression — a transiently unreadable config.toml must never be
;         overwritten with defaults (config-boot-read-failed)
; DESCRIPTION:
; The whole feature configuration could be destroyed by a lock that lasted a few
; hundred milliseconds. Start the driver while config.toml is briefly held by a
; sync client, an AV real-time scan or a backup job, and:
;
;   1. ApplyConfigToml called ReadTomlFile, which caught the sharing violation
;      and returned "";
;   2. `loop parse, ""` applied ZERO overrides, so Features stayed at
;      ManifestBuildFeaturesMap() defaults — and the apply still logged
;      SUCCESS "0 value(s)", indistinguishable from a genuinely fresh config;
;   3. the lock cleared before the -500 ms boot timer fired SaveFullConfig,
;      which re-collected that DEFAULT tree and wrote it out successfully,
;      replacing every one of the user's settings with factory values.
;
; ROOT CAUSE ENCODED: ReadTomlFile collapsed "unreadable" into "empty" and
; exposed no signal to later writers. TOML_BatchWrite's own TOML_ReadFailed
; guard structurally cannot catch this case — it re-parses at WRITE time, and by
; then the lock has cleared, so the write looks safe while the payload it was
; handed is already defaults. The distinction therefore has to be latched at
; READ time and survive until the process restarts.
;
; The three assertions below are the three links of that chain: the sentinel is
; raised, the apply refuses to pretend it succeeded, and the persist declines.
; Breaking any single link re-opens the data loss, so each is asserted
; separately rather than through one end-to-end scenario.
;
; SCOPE: behavioural throughout — the failure is provoked with a real exclusive
; file lock, which is exactly the mechanism the field failure used.
; ==============================================================================

#Requires AutoHotkey v2.0

; Deny every sharing mode so a concurrent FileRead fails with OS error 32, the
; same sharing violation a sync client or an AV scanner produces.
global _CBRF_EXCLUSIVE_LOCK_FLAGS := "r-rwd"





; =======================================================================
; =======================================================================
; ======= 1/ An unreadable existing file raises a sticky sentinel =======
; =======================================================================
; =======================================================================

; ReadTomlFile must keep returning "" (no caller may be made to throw), but it
; has to record that "" meant "could not read" rather than "was empty". The flag
; must be STICKY: the whole point is that the file is readable again by the time
; the write happens, so a flag cleared by the next successful read of ANY path
; would be gone exactly when it is needed.
_CBRF_UnreadableExistingFileIsFlagged() {
	Path := A_Temp . "\ergopti_test_cbrf_locked_" . A_TickCount . ".toml"
	try FileDelete(Path)
	FileAppend("[layout]`nenabled = false`n", Path, "UTF-8")

	Lock := FileOpen(Path, _CBRF_EXCLUSIVE_LOCK_FLAGS)
	Assert(Lock != "" and IsObject(Lock), "the test could not take an exclusive lock — it would otherwise assert nothing")
	Content := ReadTomlFile(Path)
	Flagged := TOML_UnreadableFile(Path)
	Lock.Close()

	Assert(Content == "",
		"ReadTomlFile must stay non-throwing and return empty on a sharing violation")
	Assert(Flagged,
		"an EXISTING file that could not be read must be flagged unreadable — returning an empty string with no signal is what let the caller apply defaults and the next writer persist them over the user's real config")

	; A file that is genuinely absent reads empty too, but that is not a failure:
	; flagging it would block the very first save on a fresh install.
	Missing := A_Temp . "\ergopti_test_cbrf_absent_" . A_TickCount . ".toml"
	try FileDelete(Missing)
	ReadTomlFile(Missing)
	Assert(!TOML_UnreadableFile(Missing),
		"a MISSING file must not be flagged — it legitimately reads as empty, and flagging it would block the first save of a fresh install")

	; Only a successful read of the same path may clear it: that read is the
	; proof that anything derived from the file is now trustworthy again.
	Recovered := ReadTomlFile(Path)
	try FileDelete(Path)
	Assert(InStr(Recovered, "enabled = false") > 0, "the file must read back once unlocked")
	Assert(!TOML_UnreadableFile(Path),
		"a later successful read of the same path must clear the flag, or one transient lock would block every save for the rest of the session")
}





; ====================================================================
; ====================================================================
; ======= 2/ The boot apply refuses to report a silent success =======
; ====================================================================
; ====================================================================

; The destructive step needs TWO things to be true: the tree in memory is
; defaults, and something later serializes it. This asserts the first — the
; apply must neither claim success nor leave the caller unable to tell.
_CBRF_ApplyRefusesUnreadableConfig() {
	global _ConfigBootReadFailed
	Path := A_Temp . "\ergopti_test_cbrf_apply_" . A_TickCount . ".toml"
	try FileDelete(Path)
	; A real override: if the apply ever ran, this key would flip in the fixture.
	FileAppend("[layout]`nenabled = false`n", Path, "UTF-8")

	Fixture := Map("layout", Map("enabled", true))
	PrevFlag := _ConfigBootReadFailed
	_ConfigBootReadFailed := false

	Lock := FileOpen(Path, _CBRF_EXCLUSIVE_LOCK_FLAGS)
	Assert(Lock != "" and IsObject(Lock), "the test could not take an exclusive lock — it would otherwise assert nothing")
	Result := ApplyConfigToml(Fixture, Path)
	Flag := _ConfigBootReadFailed
	Lock.Close()
	try FileDelete(Path)
	_ConfigBootReadFailed := PrevFlag

	Assert(Result == -1,
		"ApplyConfigToml must return a FAILURE signal (-1) for an existing-but-unreadable config — returning 0 is indistinguishable from a config that legitimately carried no overrides")
	Assert(Flag,
		"ApplyConfigToml must latch _ConfigBootReadFailed so the deferred boot save knows the feature tree in memory is defaults rather than the user's settings")
	Assert(Fixture["layout"]["enabled"] == true,
		"nothing may be applied from a file that could not be read")
}

; The success path must keep working unchanged, or the guard would be a
; permanent regression dressed up as a fix.
_CBRF_ApplyStillWorksWhenReadable() {
	global _ConfigBootReadFailed
	Path := A_Temp . "\ergopti_test_cbrf_ok_" . A_TickCount . ".toml"
	try FileDelete(Path)
	FileAppend("[layout]`nenabled = false`n", Path, "UTF-8")

	Fixture := Map("layout", Map("enabled", true))
	PrevFlag := _ConfigBootReadFailed
	_ConfigBootReadFailed := false
	Result := ApplyConfigToml(Fixture, Path)
	Flag := _ConfigBootReadFailed
	_ConfigBootReadFailed := PrevFlag
	try FileDelete(Path)

	Assert(Result >= 1, "a readable config must still apply its overrides")
	Assert(Fixture["layout"]["enabled"] == false, "the override must reach the Features tree")
	Assert(!Flag, "a readable config must not latch the failure flag")
}





; ================================================================
; ================================================================
; ======= 3/ The persist declines while the flag is raised =======
; ================================================================
; ================================================================

; The last link: even with the file readable again and the driver fully ready,
; SaveFullConfig must refuse, because what it would serialize is the default
; tree that step 2 proved was never overridden.
; The last link: even with the file readable again and the driver fully ready,
; SaveFullConfig must refuse, because what it would serialize is the default
; tree that step 2 proved was never overridden.
;
; The unguarded write is deliberately NOT driven here as a control: a completed
; SaveFullConfig pulls in the whole tray/menu/metrics surface and blocks the
; headless runner on a dialog. The false-green risk that control would have
; covered ("it bailed for some unrelated reason") is closed instead by asserting
; the refusal's own distinct return value — the only other early exit,
; !_DriverReady, returns nothing — and by the positional assertion below.
_CBRF_CaptureSaveRuntime() {
	global ConfigurationFile, _DriverReady, _ConfigBootReadFailed
	return Map("path_set", IsSet(ConfigurationFile),
		"path", IsSet(ConfigurationFile) ? ConfigurationFile : "",
		"ready_set", IsSet(_DriverReady), "ready", IsSet(_DriverReady) ? _DriverReady : false,
		"flag_set", IsSet(_ConfigBootReadFailed),
		"flag", IsSet(_ConfigBootReadFailed) ? _ConfigBootReadFailed : false)
}

_CBRF_RestoreSaveRuntime(Runtime) {
	global ConfigurationFile, _DriverReady, _ConfigBootReadFailed
	if Runtime["path_set"]
		ConfigurationFile := Runtime["path"]
	else
		ConfigurationFile := unset
	if Runtime["ready_set"]
		_DriverReady := Runtime["ready"]
	else
		_DriverReady := unset
	if Runtime["flag_set"]
		_ConfigBootReadFailed := Runtime["flag"]
	else
		_ConfigBootReadFailed := unset
}

_CBRF_SaveDeclinesWhileFlagged(FailAfterRefusal := false) {
	global _ConfigBootReadFailed, ConfigurationFile, _DriverReady
	Target := A_Temp . "\ergopti_test_cbrf_save_" . A_TickCount . ".toml"
	Runtime := _CBRF_CaptureSaveRuntime()
	Coordinator := _ConfigFullSaveCoordinator()
	BeforeProperties := Map()
	for Name, Value in ObjOwnProps(Coordinator)
		BeforeProperties[Name] := Value
	try {
		try FileDelete(Target)
		; Content that is unmistakably the user's, so any rewrite is visible.
		FileAppend("[layout]`nenabled = false`n", Target, "UTF-8")
		Before := FileRead(Target, "UTF-8")
		; The explicit refusal records intent in this fixture's own coordinator.
		; Restore the caller's exact obligation instead of draining or clearing it.
		_ConfigFullSaveCoordinator({
			requested_generation: 0, committed_generation: 0, settled_generation: 0,
			terminal_required_generation: 0, bound_path: "", bound_path_key: "",
			reload_required: false, timer_armed: false, reported_failure_generation: 0
		})
		ConfigurationFile     := Target
		_DriverReady          := true
		_ConfigBootReadFailed := true
		Threw   := ""
		Refused := ""
		try Refused := SaveFullConfig()
		catch as e
			Threw := e.Message
		After := FileRead(Target, "UTF-8")
		Assert(Threw == "",
			"SaveFullConfig must DECLINE cleanly, not throw: it runs from a boot timer where an exception is invisible. Got: " . Threw)
		Assert(Refused == false,
			"SaveFullConfig must return false when it refuses, so the refusal is distinguishable from the !_DriverReady deferral (which returns nothing) and from a save that ran")
		Assert(After == Before,
			"SaveFullConfig must not rewrite config.toml while _ConfigBootReadFailed is set — the tree it would serialize is manifest defaults, and writing it destroys every setting the user had")

		State := _ConfigFullSaveCoordinator()
		AssertEqual(1, State.requested_generation, "the real refused explicit save still owns one accepted intent")
		AssertEqual(1, State.terminal_required_generation, "refusing serialization does not abandon mandatory intent")
		AssertEqual(0, State.committed_generation, "the refused fixture has no disk ACK")
		AssertEqual(0, State.settled_generation, "the refused fixture has not settled its intent")
		AssertTrue(_ConfigFullSaveHasPending(), "accepted intent stays pending within its own fixture")
		AssertEqual(Target, State.bound_path, "the accepted intent belongs to the physical fixture source")
		AssertEqual(_ConfigWriteLeaseKey(Target), State.bound_path_key)
		AssertFalse(State.timer_armed, "boot refusal must not arm a retry timer")
		AssertFalse(State.reload_required)
		AssertEqual(0, State.reported_failure_generation)
		if FailAfterRefusal
			throw Error("CBRF fixture cleanup control after genuine refusal")
	} finally {
		_ConfigFullSaveCoordinator(Coordinator)
		_CBRF_RestoreSaveRuntime(Runtime)
		try FileDelete(Target)
	}
	AssertTrue(_ConfigFullSaveCoordinator() == Coordinator, "normal cleanup restores the exact caller coordinator")
	AfterProperties := Map()
	for Name, Value in ObjOwnProps(Coordinator)
		AfterProperties[Name] := Value
	AssertEqual(BeforeProperties.Count, AfterProperties.Count)
	for Name, Value in BeforeProperties {
		AssertTrue(AfterProperties.Has(Name), "cleanup preserves every caller coordinator field")
		AssertEqual(Value, AfterProperties[Name], "cleanup leaves caller coordinator fields unchanged")
	}
}


; Positional guard: the refusal is only worth anything if it happens BEFORE the
; file is replaced. A guard that drifts below the write (or below the Updates
; collection that feeds it) still returns false and still passes the assertions
; above while the config is already gone.
_CBRF_GuardPrecedesTheWrite() {
	Body := _DriverFuncBody("SaveFullConfig")
	Assert(Body != "", "SaveFullConfig() must exist in the driver source")

	GuardPos := InStr(Body, "ConfigFullStateCanPersist()")
	GuardBody := _DriverFuncBody("ConfigFullStateCanPersist")
	Assert(GuardBody != "", "the shared full-state admission guard must exist")
	Assert(InStr(GuardBody, "_ConfigBootReadFailed") > 0,
		"shared admission must retain unreadable-boot protection")
	WritePos := _CBRF_CapturedPublisherPosition(Body)
	Assert(GuardPos > 0,
		"SaveFullConfig must consult _ConfigBootReadFailed — without it a boot that could not read config.toml persists manifest defaults over the user's settings")
	Assert(WritePos > 0, "SaveFullConfig must still reach its actual semantic publisher on the nominal path")
	Assert(GuardPos < WritePos,
		"the _ConfigBootReadFailed guard must come BEFORE its actual semantic publisher — after it, the user's config has already been replaced")
	Assert(_CBRF_SemanticGuardAndStrictAck(Body),
		"the current publisher remains after admission and before its strict Integer-1 ACK")
	Publisher := _StripFullLineComments(_DriverFuncBody("TOML_ConfigBatchWrite"))
	Assert(InStr(Publisher, 'return _TOML_BatchWriteImpl(Path, Updates, ExactSectionPrefixes, "write", , , true)') > 0,
		"the current gateway returns the semantic native writer result unchanged")
	NativePublisher := _StripFullLineComments(_DriverFuncBody("_TOML_BatchWriteImpl"))
	SourceBuilder := _StripFullLineComments(_DriverFuncBody("TOML_BuildConfigUpdatedContent"))
	SourceReceipt := _StripFullLineComments(_DriverFuncBody("_TOML_FinalizeBuildResult"))
	Assert(NativePublisher != "" && SourceBuilder != "" && SourceReceipt != "",
		"the private semantic publisher and its exact-source receipt owners must exist")
	Assert(InStr(NativePublisher, "TOML_BuildConfigDocumentCandidate(") > 0,
		"the current private publisher still builds the actual complete typed configuration")
	Assert(InStr(SourceBuilder, 'SourcePresent := FileExist(Path) ? 1 : 0') > 0
		&& InStr(SourceBuilder, 'SourceBytes := SourcePresent ? FSReadUtf8Exact(Path) : ""') > 0
		&& InStr(SourceBuilder, 'return _TOML_FinalizeBuildResult(Result, SourcePresent, SourceBytes)') > 0
		&& InStr(SourceReceipt, 'Result["source_present"] := SourcePresent') > 0
		&& InStr(SourceReceipt, 'Result["source_content"] := SourceBytes') > 0,
		"captured presence and physical bytes must come from the real source receipt before classification or collection")
	Assert(_CBRF_SourceReceiptOwnersAreExecutable(SourceBuilder, SourceReceipt, NativePublisher),
		"quoted receipt text cannot lend absent source capture, fields or native semantic publication")
}


Test("meta config-boot-read-failed: an unreadable existing TOML raises a sticky sentinel",
	_CBRF_UnreadableExistingFileIsFlagged)
Test("meta config-boot-read-failed: the boot apply refuses an unreadable config",
	_CBRF_ApplyRefusesUnreadableConfig)
Test("meta config-boot-read-failed: a readable config still applies",
	_CBRF_ApplyStillWorksWhenReadable)
Test("meta config-boot-read-failed: the persist declines while the sentinel is raised",
	_CBRF_SaveDeclinesWhileFlagged)
Test("meta config-boot-read-failed: the persist guard precedes the write",
	_CBRF_GuardPrecedesTheWrite)

; These mutations consume the same actual body as the positional guard.
_CBRF_CapturedPublisherPosition(Body) {
	Position := RegExMatch(Body, 'm)^[ \t]*Written := _TOML_BatchWriteImpl\(BoundPath, Updates, \[\], "write",[ \t]*\n[ \t]*SourceImage\["source_content"\], SourceImage\["source_present"\], true\)[ \t]*$', &Matched)
	Code := _DriverMaskNonCode(&Body)
	return Position && SubStr(Code, Position + InStr(Matched[0], "Written", true) - 1, 7) == "Written" ? Position : 0
}

_CBRF_SemanticGuardAndStrictAck(Body) {
	GuardPos := RegExMatch(Body, "m)^[ `t]*if !ConfigFullStateCanPersist\(\) \{[ `t]*$")
	CapturePos := RegExMatch(Body, 'm)^[ \t]*SourceImage := TOML_BuildConfigUpdatedContent\(BoundPath, \[\]\)')
	ClassifyPos := RegExMatch(Body, 'm)^[ \t]*ObsoleteSource := ConfigFullSnapshotCaptureObsoleteSource\(SourceImage\["source_content"\]\)')
	CollectPos := RegExMatch(Body, 'm)^[ \t]*Updates := HasMethod\(CollectFn, "Call"\)')
	WritePos := _CBRF_CapturedPublisherPosition(Body)
	if !GuardPos || !CapturePos || !ClassifyPos || !CollectPos || !WritePos
		return false
	Code := _DriverMaskNonCode(&Body)
	for Binding in [{ position: GuardPos, token: "if" }, { position: CapturePos, token: "SourceImage" },
			{ position: ClassifyPos, token: "ObsoleteSource" }, { position: CollectPos, token: "Updates" }] {
		Offset := InStr(SubStr(Body, Binding.position), Binding.token, true)
		if SubStr(Code, Binding.position + Offset - 1, StrLen(Binding.token)) != Binding.token
			return false
	}
	AckPos := RegExMatch(Body, "m)^[ `t]*if \(\(Written is Integer\) && Written == 1\)[ `t]*$",, WritePos)
	AckOffset := AckPos ? InStr(SubStr(Body, AckPos), "if", true) : 0
	return GuardPos < CapturePos && CapturePos < ClassifyPos && ClassifyPos < CollectPos
		&& CollectPos < WritePos && AckPos > WritePos
		&& AckOffset && SubStr(Code, AckPos + AckOffset - 1, 2) == "if"
}

_CBRF_CurrentPublisherGuardMutations() {
	Body := _StripFullLineComments(_DriverFuncBody("SaveFullConfig"))
	Call := 'Written := _TOML_BatchWriteImpl(BoundPath, Updates, [], "write",`n'
		. '`t`t`t`t`t`tSourceImage["source_content"], SourceImage["source_present"], true)'
	Assert(InStr(Body, Call, true) > 0, "mutations must own the actual captured-source publisher")
	AssertTrue(_CBRF_SemanticGuardAndStrictAck(Body), "the actual nominal path remains admitted")
	AssertFalse(_CBRF_SemanticGuardAndStrictAck(StrReplace(Body,
		Call, StrReplace(Call, "Written :=", "UnrelatedWritten :=", true))),
		"a suffix-sharing assignment cannot lend an unresolved Written result binding")
	AssertFalse(_CBRF_SemanticGuardAndStrictAck(StrReplace(Body,
		"if !ConfigFullStateCanPersist()", "if true")), "removing boot admission cannot pass")
	AssertFalse(_CBRF_SemanticGuardAndStrictAck(Call . "`n" . Body),
		"publishing before boot admission cannot pass")
	AssertFalse(_CBRF_SemanticGuardAndStrictAck(StrReplace(Body,
		"if ((Written is Integer) && Written == 1)", "if Written")), "truthy malformed receipts cannot pass")
	AssertFalse(_CBRF_SemanticGuardAndStrictAck(StrReplace(Body,
		'SourceImage["source_content"], SourceImage["source_present"], true)',
		'SourceImage["content"], SourceImage["source_present"], true)')), "candidate bytes cannot replace captured source authority")
	AssertFalse(_CBRF_SemanticGuardAndStrictAck(StrReplace(Body,
		'SourceImage["source_content"], SourceImage["source_present"], true)',
		'SourceImage["source_content"], true, true)')), "presence must remain bound to the exact admitted source")
	AssertFalse(_CBRF_SemanticGuardAndStrictAck(StrReplace(Body,
		"SourceImage := TOML_BuildConfigUpdatedContent(", "UnrelatedSourceImage := TOML_BuildConfigUpdatedContent(")), "unrelated captures cannot lend their source authority")
	AssertFalse(_CBRF_SemanticGuardAndStrictAck(StrReplace(Body,
		"ConfigFullSnapshotCaptureObsoleteSource(", "UnrelatedSourceClassifier(")), "collection must follow fresh source classification")
	Quoted := "AuditText := " . Chr(39) . "`n(`n" . Call . "`n)" . Chr(39)
	AssertFalse(_CBRF_SemanticGuardAndStrictAck(StrReplace(Body, Call, Quoted, true)), "quoted writer data cannot authorize publication")
	AssertFalse(_CBRF_SemanticGuardAndStrictAck(StrReplace(Body, Call, "/*`n" . Call . "`n*/", true)), "commented writer data cannot authorize publication")
	Ack := "if ((Written is Integer) && Written == 1)"
	AssertFalse(_CBRF_SemanticGuardAndStrictAck(StrReplace(Body, Ack, "/*`n" . Ack . "`n*/", true)),
		"commented strict-ACK text cannot authorize a generation")
	AssertFalse(_CBRF_SemanticGuardAndStrictAck(StrReplace(Body, Ack,
		"AuditText := " . Chr(39) . "`n(`n" . Ack . "`n)" . Chr(39), true)),
		"quoted strict-ACK text cannot authorize a generation")
}
Test("meta config-boot-read-failed: actual semantic publisher retains causal guard and strict-ACK controls",
	_CBRF_CurrentPublisherGuardMutations)

; These statements remain owned by the actual reader, finalizer and semantic
; publisher. A copied source fragment is data, not proof of executable receipt.
_CBRF_SourceStatementPosition(Body, Pattern, Token) {
	Position := RegExMatch(Body, Pattern, &Matched)
	if !Position
		return 0
	Offset := InStr(Matched[0], Token, true)
	Code := _DriverMaskNonCode(&Body)
	return Offset && SubStr(Code, Position + Offset - 1, StrLen(Token)) == Token ? Position : 0
}

_CBRF_SourceReceiptOwnersAreExecutable(Builder, Receipt, Publisher) {
	Presence := _CBRF_SourceStatementPosition(Builder, 'm)^[ \t]*SourcePresent := FileExist\(Path\) \? 1 : 0[ \t]*$', "SourcePresent")
	Content := _CBRF_SourceStatementPosition(Builder, 'm)^[ \t]*SourceBytes := SourcePresent \? FSReadUtf8Exact\(Path\) : ""[ \t]*$', "SourceBytes")
	Finalize := _CBRF_SourceStatementPosition(Builder, 'm)^[ \t]*return _TOML_FinalizeBuildResult\(Result, SourcePresent, SourceBytes\)[ \t]*$', "return")
	PresenceField := _CBRF_SourceStatementPosition(Receipt, 'm)^[ \t]*Result\["source_present"\] := SourcePresent[ \t]*$', "Result")
	ContentField := _CBRF_SourceStatementPosition(Receipt, 'm)^[ \t]*Result\["source_content"\] := SourceBytes[ \t]*$', "Result")
	Typed := _CBRF_SourceStatementPosition(Publisher, 'm)^[ \t]*try Admitted := TOML_BuildConfigDocumentCandidate\(SourceBytes, Updates, ExactSectionPrefixes\)[ \t]*$', "try")
	return Presence > 0 && Content > Presence && Finalize > Content
		&& PresenceField > 0 && ContentField > PresenceField && Typed > 0
}

_CBRF_SourceReceiptMutation(Builder, Receipt, Publisher, Owner, Statement) {
	Body := Owner == "builder" ? Builder : Owner == "receipt" ? Receipt : Publisher
	Assert(InStr(Body, Statement, true) > 0, "each receipt mutation must replace the actual executable native statement")
	for Replacement in ["AuditText := " . Chr(39) . "`n(`n" . Statement . "`n)" . Chr(39),
			"/*`n" . Statement . "`n*/"] {
		Changed := StrReplace(Body, Statement, Replacement, true)
		AssertFalse(Changed == Body, "receipt quote/comment controls must change the real owner body")
		AssertFalse(_CBRF_SourceReceiptOwnersAreExecutable(
			Owner == "builder" ? Changed : Builder,
			Owner == "receipt" ? Changed : Receipt,
			Owner == "publisher" ? Changed : Publisher), "quoted or commented statements cannot lend captured-source receipt authority")
	}
}

_CBRF_CurrentSourceReceiptGuardMutations() {
	Builder := _StripFullLineComments(_DriverFuncBody("TOML_BuildConfigUpdatedContent"))
	Receipt := _StripFullLineComments(_DriverFuncBody("_TOML_FinalizeBuildResult"))
	Publisher := _StripFullLineComments(_DriverFuncBody("_TOML_BatchWriteImpl"))
	Assert(Builder != "" && Receipt != "" && Publisher != "", "the native source receipt owners must exist before mutation")
	AssertTrue(_CBRF_SourceReceiptOwnersAreExecutable(Builder, Receipt, Publisher), "the real source receipt remains admitted")
	for Spec in [
		{ owner: "builder", statement: 'SourcePresent := FileExist(Path) ? 1 : 0' },
		{ owner: "builder", statement: 'SourceBytes := SourcePresent ? FSReadUtf8Exact(Path) : ""' },
		{ owner: "builder", statement: 'return _TOML_FinalizeBuildResult(Result, SourcePresent, SourceBytes)' },
		{ owner: "receipt", statement: 'Result["source_present"] := SourcePresent' },
		{ owner: "receipt", statement: 'Result["source_content"] := SourceBytes' },
		{ owner: "publisher", statement: 'try Admitted := TOML_BuildConfigDocumentCandidate(SourceBytes, Updates, ExactSectionPrefixes)' }
	]
		_CBRF_SourceReceiptMutation(Builder, Receipt, Publisher, Spec.owner, Spec.statement)
}
Test("meta config-boot-read-failed: actual captured-source receipt rejects nonexecutable authority",
	_CBRF_CurrentSourceReceiptGuardMutations)

; Preserve an existing caller obligation through both successful assertions and
; a deliberately thrown assertion-path error after the same real refusal.
_CBRF_SaveFixtureRestoresPendingCaller() {
	Runtime := _CBRF_CaptureSaveRuntime()
	Coordinator := _ConfigFullSaveCoordinator()
	Caller := {
		requested_generation: 7, committed_generation: 3, settled_generation: 3,
		terminal_required_generation: 7, bound_path: A_Temp . "\ergopti_cbrf_caller.toml",
		bound_path_key: _ConfigWriteLeaseKey(A_Temp . "\ergopti_cbrf_caller.toml"),
		reload_required: true, timer_armed: true, reported_failure_generation: 2
	}
	BeforeProperties := Map()
	for Name, Value in ObjOwnProps(Caller)
		BeforeProperties[Name] := Value
	try {
		_ConfigFullSaveCoordinator(Caller)
		for FailAfterRefusal in [false, true] {
			Threw := ""
			try _CBRF_SaveDeclinesWhileFlagged(FailAfterRefusal)
			catch as Err
				Threw := Err.Message
			AssertEqual(FailAfterRefusal ? "CBRF fixture cleanup control after genuine refusal" : "", Threw)
			AssertTrue(_ConfigFullSaveCoordinator() == Caller, "cleanup must restore the original caller object after either exit")
			AfterProperties := Map()
			for Name, Value in ObjOwnProps(Caller)
				AfterProperties[Name] := Value
			AssertEqual(BeforeProperties.Count, AfterProperties.Count)
			for Name, Value in BeforeProperties {
				AssertTrue(AfterProperties.Has(Name))
				AssertEqual(Value, AfterProperties[Name], "foreign pending intent must not be cleared, acknowledged or rebound")
			}
			AssertTrue(_ConfigFullSaveHasPending(), "cleanup retains the caller's own preexisting pending obligation")
			RestoredRuntime := _CBRF_CaptureSaveRuntime()
			for Name, Value in Runtime
				AssertEqual(Value, RestoredRuntime[Name], "cleanup restores runtime values and definedness after either exit")
		}
	} finally {
		_ConfigFullSaveCoordinator(Coordinator)
		_CBRF_RestoreSaveRuntime(Runtime)
	}
}
Test("meta config-boot-read-failed: refused save fixture preserves caller intent on normal and throwing exits",
	_CBRF_SaveFixtureRestoresPendingCaller)
