; tests/unit/infra/config/migration/test_config_journal_nul_suffix.ahk

; ==============================================================================
; MODULE: Config Journal Caller NUL Suffixes
; DESCRIPTION:
; Captured native transitions, reads and writes reject a caller-only NUL
; suffix on every source and candidate, and a registry reason suffix
; revokes the captured admission.
; ==============================================================================

#Requires AutoHotkey v2.0





; Caller-held predicates must reject additional source units after a literal NUL.
; The native reader is never asked to decode NUL-bearing bytes in this subject.
_CMJ_CapturedTransitionRejectsCallerNulSuffix(Side) {
	global ConfigurationFile
	HadPath := IsSet(ConfigurationFile)
	PreviousPath := HadPath ? ConfigurationFile : ""
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml"
	Source := '[_meta]`nschema_version = 12`n[layout]`nergopti_base = true`n# genuine original image`n'
	Candidate := '[_meta]`nschema_version = 12`n[layout]`nergopti_base = false`n# genuine candidate image`n'
	Bundle := false
	PrimaryError := false, CleanupErrors := [], OriginalBytesValid := false
	try {
		AssertEqual(12, ConfigMigrateCurrentVersion(), "the handwritten images require the actual v12 registry")
		ConfigurationFile := Path
		AssertTrue(FSWriteDurable(Path, Source))
		BeforeBytes := FileRead(Path, "RAW")
		AssertEqual(StrLen(Source), BeforeBytes.Size, "the genuine original native image has its complete independent ASCII byte count")
		loop BeforeBytes.Size
			AssertEqual(Ord(SubStr(Source, A_Index, 1)), NumGet(BeforeBytes, A_Index - 1, "UChar"),
				"the initial raw byte vector equals the handwritten source")
		OriginalBytesValid := true
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(Bundle is Object, "the captured predicate requires an actual native terminal bundle")
		OriginalBundleId := Bundle.id
		AssertTrue(ConfigSchemaPrepareOwnedSource(Path, Bundle), "the real prepare_owned handoff owns this source")
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path))
		Guard := ConfigMigrateBoot(Path, "capture_transition", Map("present", 1, "content", Candidate), Bundle)
		AssertTrue(HasMethod(Guard, "Call"), "the genuine capture_transition request must return its actual predicate")
		AssertTrue(Guard.Call(Source, 1, Candidate, 1), "exact original and candidate images are admitted")
		AssertTrue(Guard.Call(Candidate, 1, Source, 1), "both genuine images retain the issued transition permission")
		Nul := Chr(0), Suffix := "fixed-caller-suffix"
		AssertEqual(1, StrLen(Nul)), AssertEqual(0, Ord(Nul))
		CallerSource := Source . Nul . Suffix
		CallerCandidate := Candidate . Nul . Suffix
		AssertTrue(CallerSource is String), AssertTrue(CallerCandidate is String)
		AssertEqual(StrLen(Source) + 1 + StrLen(Suffix), StrLen(CallerSource))
		AssertEqual(StrLen(Candidate) + 1 + StrLen(Suffix), StrLen(CallerCandidate))
		AssertEqual(0, Ord(SubStr(CallerSource, StrLen(Source) + 1, 1)))
		AssertEqual(0, Ord(SubStr(CallerCandidate, StrLen(Candidate) + 1, 1)))
		if Side == "source"
			AssertFalse(Guard.Call(CallerSource, 1, Candidate, 1),
				"caller source units after NUL are outside both genuinely captured images")
		else if Side == "next"
			AssertFalse(Guard.Call(Source, 1, CallerCandidate, 1),
				"caller next-content units after NUL cannot borrow genuine candidate permission")
		else
			throw Error("Unknown caller-only NUL regression side")
		AssertFalse(Guard.Call(1, 1, Candidate, 1), "the existing Source String guard rejects a numeric caller")
		AssertTrue(Guard.Call(Source, 1, Candidate, 1), "exact source repair preserves the same still-live captured predicate")
		Bundle.id := OriginalBundleId + 1
		AssertFalse(Guard.Call(Source, 1, Candidate, 1), "actual native bundle identity withdrawal refuses the retained predicate")
		Bundle.id := OriginalBundleId
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path), "exact bundle repair restores its actual native ownership")
		AssertTrue(Guard.Call(Source, 1, Candidate, 1), "the same guard accepts the exactly repaired real bundle")
	} catch as Err {
		PrimaryError := Err
	}
	; Each teardown action remains independent of earlier body/cleanup failures.
	try ConfigurationFile := HadPath ? PreviousPath : unset
	catch as Err
		CleanupErrors.Push({ stage: "global_restore", error: Err })
	if Bundle is Object && IsSet(OriginalBundleId) {
		try Bundle.id := OriginalBundleId
		catch as Err
			CleanupErrors.Push({ stage: "bundle_id_restore", error: Err })
	}
	ReleaseAcknowledged := !(Bundle is Object)
	if Bundle is Object {
		try {
			Released := _ConfigWriteTerminalRelease(Bundle)
			ReleaseAcknowledged := (Released is Integer) && Released == 1
			if !ReleaseAcknowledged
				throw Error("The actual terminal bundle retirement was not acknowledged")
		} catch as Err
			CleanupErrors.Push({ stage: "bundle_release", error: Err })
	}
	SourceUnchanged := false
	try {
		if !IsSet(BeforeBytes)
			throw Error("No complete original native byte receipt was captured")
		AfterBytes := FileRead(Path, "RAW")
		AssertEqual(BeforeBytes.Size, AfterBytes.Size, "caller-only predicate checks never change the native file length")
		loop BeforeBytes.Size
			AssertEqual(NumGet(BeforeBytes, A_Index - 1, "UChar"), NumGet(AfterBytes, A_Index - 1, "UChar"),
				"caller-only predicate checks preserve every actual raw byte")
		SourceUnchanged := OriginalBytesValid
	} catch as Err
		CleanupErrors.Push({ stage: "raw_byte_proof", error: Err })
	if ReleaseAcknowledged && SourceUnchanged {
		try _CMJ_Cleanup(Dir, Path)
		catch as Err
			CleanupErrors.Push({ stage: "fixture_cleanup", error: Err })
	} else {
		CleanupErrors.Push({ stage: "directory_retained", error: Error("Retained fixture directory because native retirement or unchanged original byte proof is unavailable: " . Dir) })
	}
	for Secondary in CleanupErrors {
		; Framework diagnostics are bounded and cannot replace the primary error.
		Detail := SubStr(StrReplace(StrReplace(Secondary.error.Message, "`r", " "), "`n", " "), 1, 512)
		try _TestPrint("# ERGOPTI_PRIVATE_CALLER_NUL_CLEANUP side=" . Side . " stage=" . Secondary.stage
			. " dir=" . Dir . " detail=" . Detail)
	}
	if IsObject(PrimaryError)
		throw PrimaryError
	if CleanupErrors.Length > 0
		throw CleanupErrors[1].error
}
Test("config journal: captured native transition rejects caller-only Source NUL suffix",
	_CMJ_CapturedTransitionRejectsCallerNulSuffix.Bind("source"))
Test("config journal: captured native transition rejects caller-only NextContent NUL suffix",
	_CMJ_CapturedTransitionRejectsCallerNulSuffix.Bind("next"))


; All captured image families retain complete caller String identity. NUL
; suffixes stay in caller values and are never written to the native source.
_CMJ_CapturedImageRejectsCallerNulSuffix(Request, Side, WithBom := false) {
	global ConfigurationFile
	HadPath := IsSet(ConfigurationFile)
	PreviousPath := HadPath ? ConfigurationFile : ""
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml"
	Source := '[_meta]`nschema_version = 12`n[layout]`nergopti_base = true`n# genuine captured image`n'
	Candidate := '[_meta]`nschema_version = 12`n[layout]`nergopti_base = false`n# genuine captured candidate`n'
	PhysicalSource := WithBom ? Chr(0xFEFF) . Source : Source
	Bundle := false, PrimaryError := false, CleanupErrors := [], OriginalBytesValid := false
	try {
		AssertEqual(12, ConfigMigrateCurrentVersion(), "the handwritten images require the actual v12 registry")
		ConfigurationFile := Path
		AssertTrue(!WithBom || Request == "capture_read", "the BOM subject belongs only to logical captured read")
		AssertTrue(FSWriteDurable(Path, PhysicalSource))
		BeforeBytes := FileRead(Path, "RAW")
		ByteOffset := WithBom ? 3 : 0
		AssertEqual(StrLen(Source) + ByteOffset, BeforeBytes.Size, "the actual source has its independent ASCII payload and physical BOM byte count")
		if WithBom {
			for Index, Byte in [239, 187, 191]
				AssertEqual(Byte, NumGet(BeforeBytes, Index - 1, "UChar"), "the complete native image begins with the fixed physical UTF-8 BOM")
		}
		loop StrLen(Source)
			AssertEqual(Ord(SubStr(Source, A_Index, 1)), NumGet(BeforeBytes, ByteOffset + A_Index - 1, "UChar"),
				"the complete raw payload equals the handwritten ASCII native source")
		OriginalBytesValid := true
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(Bundle is Object, "the fixture must acquire the actual native terminal bundle")
		OriginalBundleId := Bundle.id
		AssertTrue(ConfigSchemaPrepareOwnedSource(Path, Bundle), "the genuine prepare_owned request owns this existing image")
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path))
		Registry := ConfigMigrateShippedRegistry(), RegistryStep := Registry["steps"][1]
		OriginalReason := RegistryStep["reason"]
		if Request == "capture_write" {
			AssertFalse(ConfigMigrateBoot(Path, Request, 1), "ordinary capture refuses an actual non-String candidate at its request boundary")
			AssertFalse(ConfigMigrateBoot(Path, Request, '[_meta]`nschema_version = 99`n'),
				"ordinary capture cannot issue a current-image predicate for a genuine newer-schema candidate")
		}
		Guard := Request == "capture_write" ? ConfigMigrateBoot(Path, Request, Candidate) : ConfigMigrateBoot(Path, Request)
		AssertTrue(HasMethod(Guard, "Call"), "the actual captured API must issue the requested predicate")
		Nul := Chr(0), Suffix := "fixed-caller-image-suffix"
		AssertEqual(1, StrLen(Nul)), AssertEqual(0, Ord(Nul))
		CallerSource := Source . Nul . Suffix
		CallerCandidate := Candidate . Nul . Suffix
		AssertTrue(CallerSource is String), AssertTrue(CallerCandidate is String)
		AssertEqual(StrLen(Source) + 1 + StrLen(Suffix), StrLen(CallerSource))
		AssertEqual(StrLen(Candidate) + 1 + StrLen(Suffix), StrLen(CallerCandidate))
		AssertEqual(0, Ord(SubStr(CallerSource, StrLen(Source) + 1, 1)))
		AssertEqual(0, Ord(SubStr(CallerCandidate, StrLen(Candidate) + 1, 1)))
		if Request == "capture_write" {
			AssertTrue(Guard.Call(Source, 1, Candidate), "the ordinary write predicate accepts both exact genuinely captured images")
			AssertFalse(Guard.Call(1, 1, Candidate)), AssertFalse(Guard.Call({}, 1, Candidate))
			AssertFalse(Guard.Call(Source, "1", Candidate)), AssertFalse(Guard.Call(Source, 0, Candidate))
			AssertFalse(Guard.Call(Source, 1, 1)), AssertFalse(Guard.Call(Source, 1, {}))
			if Side == "source"
				AssertFalse(Guard.Call(CallerSource, 1, Candidate), "ordinary write Source units after NUL cannot borrow captured image identity")
			else if Side == "candidate"
				AssertFalse(Guard.Call(Source, 1, CallerCandidate), "ordinary write FinalCandidate units after NUL cannot borrow captured candidate identity")
			else
				throw Error("Unknown ordinary write caller position")
			AssertTrue(Guard.Call(Source, 1, Candidate), "exact caller repair retains the original captured write predicate")
		} else {
			AssertTrue(Guard.Call(Source, 1), "the actual read or noop predicate accepts the complete original image")
			if WithBom
				AssertFalse(Guard.Call(PhysicalSource, 1), "the genuine captured read expects BOM-stripped logical text while raw native bytes retain BOM")
			AssertFalse(Guard.Call(1, 1)), AssertFalse(Guard.Call({}, 1))
			AssertFalse(Guard.Call(Source, "1")), AssertFalse(Guard.Call(Source, 0))
			AssertFalse(Guard.Call(CallerSource, 1), "caller Source units after NUL are outside the genuinely captured image")
			AssertTrue(Guard.Call(Source, 1), "exact caller repair retains the same read or noop predicate")
			if Request == "capture_noop" || Request == "capture_reconcile_noop"
				AssertTrue(ConfigSchemaAcknowledgeNoop(Path, Guard), "the retained genuine noop guard is consumed by the actual native acknowledgement")
		}
		RegistryStep["reason"] := OriginalReason . " withdrawn after genuine image capture"
		if Request == "capture_write"
			AssertFalse(Guard.Call(Source, 1, Candidate), "the real registry owner withdrawal revokes the captured ordinary write")
		else
			AssertFalse(Guard.Call(Source, 1), "the real registry owner withdrawal revokes the captured read or noop")
		RegistryStep["reason"] := OriginalReason
		if Request == "capture_write"
			AssertTrue(Guard.Call(Source, 1, Candidate), "exact registry repair restores the original captured ordinary write")
		else
			AssertTrue(Guard.Call(Source, 1), "exact registry repair restores the original captured read or noop")
		Bundle.id := OriginalBundleId + 1
		AssertFalse(_ConfigWriteTerminalOwnsExact(Bundle, Path), "the original actual bundle identity is genuinely withdrawn")
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "read permission cannot extend write-ready under a withdrawn owned bundle")
		if Request == "capture_read"
			AssertTrue(Guard.Call(Source, 1), "retained read permission intentionally survives terminal withdrawal without granting write-ready")
		else if Request == "capture_write"
			AssertFalse(Guard.Call(Source, 1, Candidate), "actual terminal withdrawal revokes ordinary write admission")
		else {
			AssertFalse(Guard.Call(Source, 1), "actual terminal withdrawal revokes noop admission")
			AssertFalse(ConfigSchemaAcknowledgeNoop(Path, Guard), "the real native acknowledgement cannot consume withdrawn noop admission")
		}
		Bundle.id := OriginalBundleId
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path), "exact original bundle repair restores actual native ownership")
		AssertTrue(ConfigSchemaCanPrepareWrite(Path))
		if Request == "capture_write"
			AssertTrue(Guard.Call(Source, 1, Candidate), "the same ordinary write guard accepts exact bundle repair")
		else {
			AssertTrue(Guard.Call(Source, 1), "the same read or noop guard accepts exact bundle repair")
			if Request == "capture_noop" || Request == "capture_reconcile_noop"
				AssertTrue(ConfigSchemaAcknowledgeNoop(Path, Guard), "actual native noop acknowledgement succeeds after exact owner repair")
		}
	} catch as Err {
		PrimaryError := Err
	}
	; Cleanup independently restores all shared state and retains uncertain bytes.
	try ConfigurationFile := HadPath ? PreviousPath : unset
	catch as Err
		CleanupErrors.Push({ stage: "global_restore", error: Err })
	if IsSet(RegistryStep) && IsSet(OriginalReason) {
		try RegistryStep["reason"] := OriginalReason
		catch as Err
			CleanupErrors.Push({ stage: "registry_restore", error: Err })
	}
	if Bundle is Object && IsSet(OriginalBundleId) {
		try Bundle.id := OriginalBundleId
		catch as Err
			CleanupErrors.Push({ stage: "bundle_id_restore", error: Err })
	}
	ReleaseAcknowledged := !(Bundle is Object)
	if Bundle is Object {
		try {
			Released := _ConfigWriteTerminalRelease(Bundle)
			ReleaseAcknowledged := (Released is Integer) && Released == 1
			if !ReleaseAcknowledged
				throw Error("The actual terminal bundle retirement was not acknowledged")
		} catch as Err
			CleanupErrors.Push({ stage: "bundle_release", error: Err })
	}
	SourceUnchanged := false
	try {
		if !IsSet(BeforeBytes)
			throw Error("No complete original native byte receipt was captured")
		AfterBytes := FileRead(Path, "RAW")
		AssertEqual(BeforeBytes.Size, AfterBytes.Size, "caller-only image checks never change the native source length")
		loop BeforeBytes.Size
			AssertEqual(NumGet(BeforeBytes, A_Index - 1, "UChar"), NumGet(AfterBytes, A_Index - 1, "UChar"),
				"caller-only image checks preserve every complete native source byte")
		SourceUnchanged := OriginalBytesValid
	} catch as Err
		CleanupErrors.Push({ stage: "raw_byte_proof", error: Err })
	if ReleaseAcknowledged && SourceUnchanged {
		try _CMJ_Cleanup(Dir, Path)
		catch as Err
			CleanupErrors.Push({ stage: "fixture_cleanup", error: Err })
	} else {
		CleanupErrors.Push({ stage: "directory_retained", error: Error("Retained fixture directory because native retirement or unchanged original byte proof is unavailable: " . Dir) })
	}
	for Secondary in CleanupErrors {
		Detail := SubStr(StrReplace(StrReplace(Secondary.error.Message, "`r", " "), "`n", " "), 1, 512)
		try _TestPrint("# ERGOPTI_CAPTURED_IMAGE_CLEANUP request=" . Request . " side=" . Side
			. " stage=" . Secondary.stage . " dir=" . Dir . " detail=" . Detail)
	}
	if IsObject(PrimaryError)
		throw PrimaryError
	if CleanupErrors.Length > 0
		throw CleanupErrors[1].error
}
Test("config journal: captured read rejects caller-only Source NUL suffix",
	_CMJ_CapturedImageRejectsCallerNulSuffix.Bind("capture_read", "source"))
Test("config journal: captured BOM read rejects caller-only Source NUL suffix",
	_CMJ_CapturedImageRejectsCallerNulSuffix.Bind("capture_read", "source", true))
Test("config journal: captured noop rejects caller-only Source NUL suffix",
	_CMJ_CapturedImageRejectsCallerNulSuffix.Bind("capture_noop", "source"))
Test("config journal: captured reconcile noop rejects caller-only Source NUL suffix",
	_CMJ_CapturedImageRejectsCallerNulSuffix.Bind("capture_reconcile_noop", "source"))
Test("config journal: captured ordinary write rejects caller-only Source NUL suffix",
	_CMJ_CapturedImageRejectsCallerNulSuffix.Bind("capture_write", "source"))
Test("config journal: captured ordinary write rejects caller-only FinalCandidate NUL suffix",
	_CMJ_CapturedImageRejectsCallerNulSuffix.Bind("capture_write", "candidate"))


; Caller-held values never borrow an image by ending at an embedded NUL.
; Physical source bytes remain ASCII; no transition or native publication occurs.
_CMJ_UpstreamExactCallerNul(Kind) {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml"
	Source := '[_meta]`nschema_version = 12`n[layout]`nergopti_base = true`n'
	PrimaryError := false, CleanupErrors := [], OriginalBytesValid := false
	try {
		AssertEqual(12, ConfigMigrateCurrentVersion(), "the independent current image requires the actual v12 registry")
		AssertTrue(FSWriteDurable(Path, Source))
		BeforeBytes := FileRead(Path, "RAW")
		AssertEqual(StrLen(Source), BeforeBytes.Size)
		loop StrLen(Source)
			AssertEqual(Ord(SubStr(Source, A_Index, 1)), NumGet(BeforeBytes, A_Index - 1, "UChar"),
				"every native source byte equals the handwritten ASCII image")
		OriginalBytesValid := true
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		AssertTrue(ConfigSchemaCanPrepareWrite(Path), "genuine boot grants the original ready phase")
		Nul := Chr(0)
		AssertEqual(1, StrLen(Nul)), AssertEqual(0, Ord(Nul))
		if Kind == "registry" {
			Registry := ConfigMigrateShippedRegistry(), Step := Registry["steps"][1]
			OriginalReason := Step["reason"]
			AssertTrue(OriginalReason is String)
			Guard := ConfigMigrateBoot(Path, "capture_noop")
			AssertTrue(HasMethod(Guard, "Call")), AssertTrue(Guard.Call(Source, 1))
			AssertTrue(ConfigSchemaAcknowledgeNoop(Path, Guard))
			Suffix := "caller-registry-suffix", ChangedReason := OriginalReason . Nul . Suffix
			AssertEqual(StrLen(OriginalReason) + 1 + StrLen(Suffix), StrLen(ChangedReason))
			AssertEqual(0, Ord(SubStr(ChangedReason, StrLen(OriginalReason) + 1, 1)))
			Step["reason"] := ChangedReason
			AssertFalse(ConfigSchemaCanPrepareWrite(Path), "native registry admission must revoke when its real reason gains units after NUL")
			AssertFalse(Guard.Call(Source, 1), "the retained original noop must lose the genuinely changed registry owner")
			AssertFalse(ConfigSchemaAcknowledgeNoop(Path, Guard), "native noop acknowledgement cannot consume the withdrawn registry")
			Step["reason"] := OriginalReason
			AssertTrue(ConfigSchemaCanPrepareWrite(Path))
			AssertTrue(Guard.Call(Source, 1)), AssertTrue(ConfigSchemaAcknowledgeNoop(Path, Guard))
		} else if Kind == "memo" {
			Exact := ConfigMigrateBoot(Path, "capture_write", Source)
			AssertTrue(HasMethod(Exact, "Call")), AssertTrue(Exact.Call(Source, 1, Source))
			DuplicateTail := '`n[_meta]`nschema_version = 99`n'
			Malformed := Source . Nul . DuplicateTail
			AssertEqual(StrLen(Source) + 1 + StrLen(DuplicateTail), StrLen(Malformed))
			AssertEqual(0, Ord(SubStr(Malformed, StrLen(Source) + 1, 1)))
			; This is the existing duplicate-table rule, not an invented NUL ban.
			ParserRefusal := ""
			try TOML_ParseDocument(Malformed)
			catch ValueError as Err
				ParserRefusal := Err.Message
			AssertEqual("Duplicate or closed TOML table namespace", ParserRefusal,
				"the actual independent parser refuses the complete duplicate metadata header")
			Rejected := ConfigMigrateBoot(Path, "capture_write", Malformed)
			AssertFalse(HasMethod(Rejected, "Call"), "classification memo must not issue write admission for the parse-refused complete caller candidate")
			AssertFalse(Rejected)
			AssertTrue(ConfigSchemaCanPrepareWrite(Path), "candidate refusal leaves genuine unchanged source readiness intact")
			Repaired := ConfigMigrateBoot(Path, "capture_write", Source)
			AssertTrue(HasMethod(Repaired, "Call")), AssertTrue(Repaired.Call(Source, 1, Source))
		} else
			throw ValueError("Unknown upstream complete caller-image regression")
	} catch as Err {
		PrimaryError := Err
	}
	if IsSet(Step) && IsSet(OriginalReason) {
		try Step["reason"] := OriginalReason
		catch as Err
			CleanupErrors.Push({ stage: "registry_restore", error: Err })
	}
	SourceUnchanged := false
	try {
		if !IsSet(BeforeBytes)
			throw Error("No complete original native byte receipt was captured")
		AfterBytes := FileRead(Path, "RAW")
		AssertEqual(BeforeBytes.Size, AfterBytes.Size)
		loop BeforeBytes.Size
			AssertEqual(NumGet(BeforeBytes, A_Index - 1, "UChar"), NumGet(AfterBytes, A_Index - 1, "UChar"),
				"caller-only admission checks preserve every physical source byte")
		SourceUnchanged := OriginalBytesValid
	} catch as Err
		CleanupErrors.Push({ stage: "raw_byte_proof", error: Err })
	if SourceUnchanged {
		try _CMJ_Cleanup(Dir, Path)
		catch as Err
			CleanupErrors.Push({ stage: "fixture_cleanup", error: Err })
	} else
		CleanupErrors.Push({ stage: "directory_retained", error: Error("Retained uncertain native source: " . Dir) })
	for Secondary in CleanupErrors {
		Detail := SubStr(StrReplace(StrReplace(Secondary.error.Message, "`r", " "), "`n", " "), 1, 512)
		try _TestPrint("# ERGOPTI_UPSTREAM_CALLER_NUL_CLEANUP kind=" . Kind . " stage=" . Secondary.stage
			. " dir=" . Dir . " detail=" . Detail)
	}
	if IsObject(PrimaryError)
		throw PrimaryError
	if CleanupErrors.Length > 0
		throw CleanupErrors[1].error
}
Test("config journal: actual registry reason NUL suffix revokes captured native admission",
	_CMJ_UpstreamExactCallerNul.Bind("registry"))
Test("config journal: classification memo cannot admit caller NUL duplicate metadata candidate",
	_CMJ_UpstreamExactCallerNul.Bind("memo"))
