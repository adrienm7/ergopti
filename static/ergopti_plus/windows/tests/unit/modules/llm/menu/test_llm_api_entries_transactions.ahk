; tests/unit/modules/llm/menu/test_llm_api_entries_transactions.ahk

; ==============================================================================
; MODULE: LLM API Entries Transactions
; DESCRIPTION:
; The remote API entries publish only after both durable files succeed, a
; refusal or a token-encryption failure restores the old authority, the
; loader and parser reject malformed images as a whole, and the shared API
; commands keep their native owners.
; ==============================================================================

#Requires AutoHotkey v2.0





_LMT_ApiBuildConfig(Path, Updates) {
	OldContent := FSReadUtf8Exact(Path)
	if !(OldContent is String)
		return Map("status", "error", "kind", "source_unreadable",
			"content", "")
	return Map("status", "ok", "kind", "rendered",
		"content", _CMJFixtureCurrentSource(
			'[llm]`nenabled = true`napi_entry_id = "api_new"`n'),
		"source_present", 1, "source_content", OldContent)
}

_LMT_ApiSerialize(CandidateMenu) {
	return CandidateMenu["api_entry_id"] == "api_new"
		? '[{"Id":"api_new"}]' : "[]"
}

; The source authority is a complete canonical API entry, so new source admission
; still tests actual second-target refusal and compensation rather than malformed input.
_LMT_ApiOldImage() {
	return '[{"Id":"api_old","Name":"Old","Provider":"openai","BaseUrl":"https://old.invalid","Token":"old","Model":"old-model"}]'
}

_LMT_ApiMutate(Candidate) {
	Candidate["enabled"] := true
	return _LLM_Menu_UpsertApiEntryCandidate(Candidate,
		Map("Id", "api_new", "Name", "New", "Provider", "openai",
			"BaseUrl", "https://example.invalid", "Token", "secret",
			"Model", "model"), "")
}

; This fixture keeps the genuine sealed production port unchanged. The original
; target:new:1 seam has already verified real first-target publication; an open
; read-shared handle then denies only replacement of the actual second target.
class _LMT_ApiPhysicalPublicationFault {
	__New(CloseAtPause := false) {
		global ConfigurationFile, _PathsFile, _LMT_ApiPath
		this.Port := ConfigTransitionProductionPort()
		this.ConfigPath := ConfigurationFile
		this.ApiPath := _LMT_ApiPath
		this.PathsFile := _PathsFile
		this.OldConfig := FSReadUtf8Exact(this.ConfigPath)
		this.OldApi := FSReadUtf8Exact(this.ApiPath)
		this.CloseAtPause := CloseAtPause
		this.Handle := 0
		this.Bundle := 0
		this.Published := 0
		this.Notified := 0
		this.NativeRefusals := 0
		this.Closed := 0
	}

	Acquire(Paths) {
		this.Bundle := _LMT_Acquire(Paths)
		return this.Bundle
	}

	Pause(Point) {
		if Point != "target:new:1"
			return
		AssertTrue(ConfigTransitionProductionPort(this.Port),
			"physical faults must not revoke the genuine native port")
		AssertTrue(this.Port == ConfigTransitionProductionPort())
		AssertContains(FSReadUtf8Exact(this.ConfigPath), 'api_entry_id = "api_new"',
			"the genuine first publication must precede the second-target obstruction")
		AssertEqual(this.OldApi, FSReadUtf8Exact(this.ApiPath))
		this.Published += 1
		AssertEqual(1, this.Published)
		; GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING. All genuine rollback
		; reads remain possible; replacement/deletion of this file is denied.
		this.Handle := DllCall("kernel32\CreateFileW", "Str", this.ApiPath,
			"UInt", 0x80000000, "UInt", 1, "Ptr", 0, "UInt", 3,
			"UInt", 0x80, "Ptr", 0, "Ptr")
		NativeError := A_LastError
		if this.Handle == -1 {
			this.Handle := 0
			throw OSError(NativeError, A_ThisFunc, "Cannot acquire the physical API fault handle.")
		}
		AssertTrue(this.Handle != 0)
		AssertEqual(this.OldApi, FSReadUtf8Exact(this.ApiPath),
			"the real obstruction must allow unchanged API rollback verification")
		this.ObserveNativeRefusal()
		if this.CloseAtPause
			this.Close()
	}

	Notify(Message, Options) {
		global _LMT_ApiRefused
		this.Notified += 1
		try {
			AssertEqual(1, this.Published)
			AssertFalse(this.CloseAtPause)
			AssertTrue(this.Handle != 0)
			AssertTrue(ConfigTransitionProductionPort(this.Port))
			AssertTrue(this.Port == ConfigTransitionProductionPort())
			AssertTrue(_ConfigWriteTerminalTryAcquire([], this.Bundle),
				"the original failure callback must retain the genuine issuing bundle")
			AssertEqual(this.OldConfig, FSReadUtf8Exact(this.ConfigPath),
				"original automatic rollback must restore the exact first-target bytes")
			AssertEqual(this.OldApi, FSReadUtf8Exact(this.ApiPath))
			AssertFalse(FSStrictExists(ConfigTransitionWalPath(this.PathsFile)) == 1,
				"automatic rollback must settle its real WAL before failure notification")
			; The original notification carries UI text rather than CommitResult.
			; Require physical refusal both at the publication seam and after
			; actual automatic rollback. An armed handle alone is not a witness.
			AssertEqual(1, this.NativeRefusals)
			this.ObserveNativeRefusal()
			_LMT_ApiRefused := this.Published == 1 && this.NativeRefusals == 2
		} finally this.Close()
		return _LMT_Notify(Message, Options)
	}

	ObserveNativeRefusal() {
		static Sequence := 0
		AssertTrue(this.Handle != 0)
		; CreateFile specifies the exact sharing error; rename promises only failure.
		DeleteHandle := DllCall("kernel32\CreateFileW", "Str", this.ApiPath,
			"UInt", 0x00010000, "UInt", 7, "Ptr", 0, "UInt", 3,
			"UInt", 0x80, "Ptr", 0, "Ptr")
		DeleteError := A_LastError
		if DeleteHandle != -1 {
			if !DllCall("kernel32\CloseHandle", "Ptr", DeleteHandle, "Int")
				throw OSError(A_LastError, A_ThisFunc, "Cannot close the unexpected delete-access probe.")
		}
		AssertEqual(-1, DeleteHandle, "The same held target must deny actual delete access")
		AssertEqual(32, DeleteError,
			"The incompatible native delete-access request must report a sharing violation")
		ProbePath := this.ApiPath . ".physical-fault-" . A_ScriptHwnd . "-" . ++Sequence
		if FSWriteCreateDurable(ProbePath, '[{"Id":"api_probe"}]') != 1
			throw Error("Cannot acquire the owned native replacement probe stage.")
		try {
			Moved := FSAtomicMoveReplace(ProbePath, this.ApiPath, &MoveError)
			AssertFalse(Moved)
			AssertTrue(MoveError is Integer && MoveError > 0,
				"The actual native replacement refusal must retain its nonzero error receipt")
			_TestPrint("# api-native-fault delete_access_error=" . DeleteError . " move_error=" . MoveError)
			AssertEqual(this.OldApi, FSReadUtf8Exact(this.ApiPath))
			this.NativeRefusals += 1
		} finally {
			if FSStrictExists(ProbePath) == 1 && !FSDeleteStrict(ProbePath)
				throw Error("Cannot delete the owned physical-fault probe stage.")
		}
	}

	Close() {
		if this.Handle == 0
			return
		if !DllCall("kernel32\CloseHandle", "Ptr", this.Handle, "Int")
			throw OSError(A_LastError, A_ThisFunc, "The physical API fault handle did not close.")
		this.Handle := 0
		this.Closed += 1
	}
}

_LMT_ApiFailingPort(CloseAtPause := false) {
	global _LMT_ApiFault
	_LMT_ApiFault := _LMT_ApiPhysicalPublicationFault(CloseAtPause)
	return _LMT_ApiFault.Port
}

_LMT_InstallApiFixture(Dir := "", WriteFn := FSWriteCreateDurable) {
	static Sequence := 0
	global Features, _LLM_Menu, ConfigurationFile, _PathsFile
	global _LMT_ApiPath, _LMT_ApiRefused, _LMT_ApplyCalls
	global _LMT_ApplyCritical, _LMT_Events, _LMT_ApiFault
	Previous := Map("features", Features, "menu", _LLM_Menu,
		"config", ConfigurationFile, "paths", _PathsFile,
		"api_fault", _LMT_ApiFault, "test_state", _LMT_CaptureFixtureState())
	if Dir == ""
		Dir := A_Temp . "\ergopti-llm-api-transaction-"
			. A_ScriptHwnd . "-" . A_TickCount . "-" . ++Sequence
	; Idempotent directory creation cannot establish exclusive cleanup ownership.
	if !DllCall("CreateDirectoryW", "Str", Dir, "Ptr", 0, "Int") {
		NativeError := A_LastError
		throw Error("Cannot acquire LLM fixture directory: " . Dir
			. " (Win32 error " . NativeError . ").")
	}
	try {
		ConfigPath := Dir . "\config.toml"
		ApiPath := Dir . "\api_entries.json"
		if WriteFn.Call(ConfigPath,
				_CMJFixtureCurrentSource('[llm]`nenabled = false`napi_entry_id = "api_old"`n')) != 1
			throw Error("Cannot create initial LLM fixture file: " . ConfigPath)
		ConfigMigrateBoot(ConfigPath)
		if WriteFn.Call(ApiPath, _LMT_ApiOldImage()) != 1
			throw Error("Cannot create initial LLM fixture file: " . ApiPath)
		CandidateFeatures := _LMT_Features()
		CandidateMenu := _LMT_Menu()
		CandidateMenu["api_entries"] := [Map("Id", "api_old", "Name", "Old",
			"Provider", "openai", "BaseUrl", "https://old.invalid",
			"Token", "old", "Model", "old-model")]
		CandidateMenu["api_entry_id"] := "api_old"
	} catch Error as Err {
		; Acquisition above proves this directory belongs only to this setup.
		DirDelete(Dir, true)
		throw Err
	}
	; Publish only a complete initial authority; failures leave the outer fixture live.
	ConfigurationFile := ConfigPath
	_PathsFile := Dir . "\paths.toml"
	_LMT_ApiPath := ApiPath
	Features := CandidateFeatures
	_LLM_Menu := CandidateMenu
	_LMT_ApiRefused := false
	_LMT_ApiFault := 0
	_LMT_ApplyCalls := 0
	_LMT_ApplyCritical := -1
	_LMT_Events := []
	Previous["dir"] := Dir
	return Previous
}

_LMT_RestoreApiFixture(Previous) {
	global Features, _LLM_Menu, ConfigurationFile, _PathsFile, _LMT_ApiFault
	if _LMT_ApiFault is _LMT_ApiPhysicalPublicationFault
		_LMT_ApiFault.Close()
	_LMT_ApiFault := Previous["api_fault"]
	Features := Previous["features"]
	_LLM_Menu := Previous["menu"]
	ConfigurationFile := Previous["config"]
	_PathsFile := Previous["paths"]
	_LMT_RestoreFixtureState(Previous["test_state"])
	try DirDelete(Previous["dir"], true)
}

_LMT_ApiCommit(Port := 0) {
	global _LMT_ApiFault
	if _LMT_ApiFault is _LMT_ApiPhysicalPublicationFault {
		AssertTrue(Port == _LMT_ApiFault.Port)
		return LLM_Menu_CommitApiEntriesMutation("the test API entry",
			_LMT_ApiMutate, _LMT_Apply, Port, ObjBindMethod(_LMT_ApiFault, "Notify"),
			ObjBindMethod(_LMT_ApiFault, "Acquire"), _LMT_Settle, _LMT_Collect,
			_LMT_ApiBuildConfig, _LMT_ApiSerialize, ObjBindMethod(_LMT_ApiFault, "Pause"))
	}
	return LLM_Menu_CommitApiEntriesMutation("the test API entry",
		_LMT_ApiMutate, _LMT_Apply, Port, _LMT_Notify, _LMT_Acquire,
		_LMT_Settle, _LMT_Collect, _LMT_ApiBuildConfig,
		_LMT_ApiSerialize)
}

_LMT_ApiCommitWithSerializer(SerializeFn) {
	return LLM_Menu_CommitApiEntriesMutation("the test API entry",
		_LMT_ApiMutate, _LMT_Apply, ConfigTransitionProductionPort(),
		_LMT_Notify, _LMT_Acquire, _LMT_Settle, _LMT_Collect,
		_LMT_ApiBuildConfig, SerializeFn)
}

_LMT_ApiSuccessPublishesOnlyAfterBothFiles() {
	global _LLM_Menu, ConfigurationFile, _PathsFile, _LMT_ApiPath
	global _LMT_ApplyCalls
	Previous := _LMT_InstallApiFixture()
	try {
		AssertTrue(_LMT_ApiCommit(ConfigTransitionProductionPort()))
		AssertContains(FSReadUtf8Exact(ConfigurationFile),
			'api_entry_id = "api_new"')
		AssertEqual('[{"Id":"api_new"}]', FSReadUtf8Exact(_LMT_ApiPath))
		AssertEqual("api_new", _LLM_Menu["api_entry_id"])
		AssertTrue(_LLM_Menu["enabled"])
		AssertEqual(1, _LMT_ApplyCalls)
		AssertFalse(FSStrictExists(ConfigTransitionWalPath(_PathsFile)) == 1,
			"successful live CRUD must clean its committed-new WAL before release")
		AssertFalse(_ConfigWriteTerminalIsActive())
	} finally _LMT_RestoreApiFixture(Previous)
}
Test("LLM API entries: both durable targets precede live publication "
	. "(llm-api-two-target-durable-publish)",
	_LMT_ApiSuccessPublishesOnlyAfterBothFiles)

_LMT_ApiSecondTargetFailureRollsEverythingOld() {
	global _LLM_Menu, ConfigurationFile, _PathsFile, _LMT_ApiPath
	global _LMT_ApiRefused, _LMT_ApplyCalls, _LMT_ApiFault
	Previous := _LMT_InstallApiFixture()
	try {
		AssertFalse(_LMT_ApiCommit(_LMT_ApiFailingPort()))
		AssertTrue(_LMT_ApiRefused,
			"the adversarial port must refuse publication of api_entries.json")
		AssertContains(FSReadUtf8Exact(ConfigurationFile),
			'api_entry_id = "api_old"',
			"the first target must roll back when the second target fails")
		AssertEqual(_LMT_ApiOldImage(), FSReadUtf8Exact(_LMT_ApiPath))
		AssertEqual("api_old", _LLM_Menu["api_entry_id"],
			"failed multi-target durability must leave live authority old")
		AssertFalse(_LLM_Menu["enabled"])
		AssertEqual(0, _LMT_ApplyCalls)
		AssertFalse(FSStrictExists(ConfigTransitionWalPath(_PathsFile)) == 1,
			"verified all-old rollback must remove its WAL")
		AssertFalse(_ConfigWriteTerminalIsActive())
		AssertEqual(1, _LMT_ApiFault.Published)
		AssertEqual(1, _LMT_ApiFault.Notified)
		AssertEqual(2, _LMT_ApiFault.NativeRefusals)
		AssertEqual(1, _LMT_ApiFault.Closed)
		AssertEqual(0, _LMT_ApiFault.Handle)
		AssertTrue(ConfigTransitionProductionPort(_LMT_ApiFault.Port))
		AssertTrue(_LMT_ApiFault.Port == ConfigTransitionProductionPort())
		AssertEqual(_LMT_ApiFault.OldConfig, FSReadUtf8Exact(ConfigurationFile))
	} finally _LMT_RestoreApiFixture(Previous)
}
Test("LLM API entries: second-target refusal restores both old authorities "
	. "(llm-api-two-target-failure-rollback)",
	_LMT_ApiSecondTargetFailureRollsEverythingOld)

; The api_entries.json serializer one encryption fixture commits with. A
; function of its own so the closure reads a parameter: a closure never sees a
; for-loop variable, so built in the loop it threw an UnsetError, and every
; fixture was refused for that error instead of for its encryptor's output.
; @param EncryptFn {Func} The token encryptor under test.
; @returns {Func} A serializer taking the detached menu candidate.
_LMT_SerializerEncryptingWith(EncryptFn) {
	return (MenuState) => _LLM_Menu_SerializeApiEntries(MenuState, EncryptFn)
}

_LMT_ApiTokenEncryptionFailurePreservesOldImage() {
	global _LLM_Menu, ConfigurationFile, _PathsFile, _LMT_ApiPath
	global _LMT_ApplyCalls
	Previous := _LMT_InstallApiFixture()
	OldApiImage := '[{"Id":"api_old","Token":"dpapi:preserved-ciphertext"}]'
	try {
		FileDelete(_LMT_ApiPath)
		FSWriteCreateDurable(_LMT_ApiPath, OldApiImage)
		OldConfigImage := FSReadUtf8Exact(ConfigurationFile)
		OldMenu := _LLM_Menu
		Encrypted := LLM_ApiToken_Encrypt("audit-secret")
		AssertTrue(Encrypted is String)
		AssertTrue(LLM_ApiToken_IsValidEnvelope(Encrypted),
			"a successful encryption must produce a usable DPAPI envelope")
		AssertEqual("audit-secret", LLM_ApiToken_Decrypt(Encrypted),
			"the strict envelope contract must retain DPAPI round-trip behavior")
		AssertFalse(InStr(Encrypted, "audit-secret") > 0,
			"the persisted envelope must not contain the raw token")
		AssertFalse(LLM_ApiToken_Encrypt("audit-secret", (*) => ""),
			"DPAPI failure must not degrade an API token to plaintext")
		AssertFalse(LLM_ApiToken_Encrypt("dpapi:"),
			"a prefix-shaped raw token must not impersonate an encrypted envelope")
		for Fixture in [
			["identity", (Token) => Token],
			["empty envelope", (*) => "dpapi:"],
			["malformed envelope", (*) => "dpapi:not-base64!"]
		] {
			SerializeFn := _LMT_SerializerEncryptingWith(Fixture[2])
			AssertFalse(_LMT_ApiCommitWithSerializer(SerializeFn),
				Fixture[1] . " token encryption must refuse the complete transition")
			AssertEqual(OldApiImage, FSReadUtf8Exact(_LMT_ApiPath),
				Fixture[1] . " failure must preserve the previous encrypted image")
			AssertEqual(OldConfigImage, FSReadUtf8Exact(ConfigurationFile),
				Fixture[1] . " failure must preserve the sibling config image")
			AssertTrue(_LLM_Menu == OldMenu,
				Fixture[1] . " failure must not publish the detached candidate")
			AssertEqual(0, _LMT_ApplyCalls,
				Fixture[1] . " failure must not invoke runtime application")
			AssertFalse(FSStrictExists(ConfigTransitionWalPath(_PathsFile)) == 1,
				Fixture[1] . " failure must settle without a transition WAL")
		}
	} finally _LMT_RestoreApiFixture(Previous)
}
Test("LLM API entries: token encryption failure preserves old authority "
	. "(audit-ahk-007)",
	_LMT_ApiTokenEncryptionFailurePreservesOldImage)


_LMT_ApiEntry(Id, Name := "Entry", Provider := "openai") {
	return Map("Id", Id, "Name", Name, "Provider", Provider,
		"BaseUrl", "https://example.invalid", "Token", "secret",
		"Model", "model")
}


_LMT_ApiLoadReport(Reason) {
	global _LMT_ApiLoadReports
	_LMT_ApiLoadReports.Push(Reason)
	return true
}


_LMT_DuplicateApiImageIsRejectedWithoutPublication() {
	global _LLM_Menu, ConfigurationFile, LLM_API_PROVIDERS
	global _LMT_ApiLoadReports
	Previous := _LMT_InstallFixture()
	PreviousProviders := LLM_API_PROVIDERS
	Dir := A_Temp . "\ergopti-api-identity-load-"
		. A_ScriptHwnd . "-" . A_TickCount
	DirCreate(Dir)
	ConfigurationFile := Dir . "\config.toml"
	Raw := '[{"Id":"duplicate","Name":"First","Provider":"openai",'
		. '"BaseUrl":"https://first.invalid","Token":"one","Model":"m1"},'
		. '{"Id":"duplicate","Name":"Second","Provider":"openai",'
		. '"BaseUrl":"https://second.invalid","Token":"two","Model":"m2"}]'
	Path := Dir . "\api_entries.json"
	FSWriteCreateDurable(Path, Raw)
	SentinelEntries := [_LMT_ApiEntry("live", "Live")]
	_LLM_Menu["api_entries"] := SentinelEntries
	_LLM_Menu["api_entry_id"] := "live"
	LLM_API_PROVIDERS := Map("openai", Map())
	_LMT_ApiLoadReports := []
	try {
		AssertFalse(_LLM_Menu_LoadApiEntries(0, _LMT_ApiLoadReport,
			(Token) => Token, LLM_API_PROVIDERS),
			"a duplicate persisted identity must reject the complete image")
		AssertTrue(_LLM_Menu["api_entries"] == SentinelEntries,
			"a rejected persisted image must not publish any detached row")
		AssertEqual("live", _LLM_Menu["api_entry_id"],
			"a rejected persisted image must preserve the active identity")
		AssertEqual(Raw, FSReadUtf8Exact(Path),
			"load rejection must never rewrite or quarantine user credentials")
		AssertEqual(1, _LMT_ApiLoadReports.Length,
			"one corrupt persisted image must produce one terminal diagnostic")
		AssertContains(_LMT_ApiLoadReports[1], "duplicate API entry id 'duplicate'",
			"the diagnostic must identify the ambiguous stable identity")
	} finally {
		LLM_API_PROVIDERS := PreviousProviders
		try DirDelete(Dir, true)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM API entries: duplicate persisted ids reject the whole image "
	. "(api-entry-identity-cardinality)",
	_LMT_DuplicateApiImageIsRejectedWithoutPublication)


_LMT_AssertApiImageRejected(Raw, CaseName) {
	global _LLM_Menu, ConfigurationFile
	Dir := A_Temp . "\ergopti-api-schema-load-"
		. A_ScriptHwnd . "-" . A_TickCount
	DirCreate(Dir)
	ConfigurationFile := Dir . "\config.toml"
	Path := Dir . "\api_entries.json"
	FSWriteCreateDurable(Path, Raw)
	SentinelEntries := [_LMT_ApiEntry("live", "Live")]
	_LLM_Menu["api_entries"] := SentinelEntries
	_LLM_Menu["api_entry_id"] := "live"
	try {
		_LLM_Menu_LoadApiEntries()
		AssertTrue(_LLM_Menu["api_entries"] == SentinelEntries,
			CaseName . " must reject the complete image before publication")
		AssertEqual("live", _LLM_Menu["api_entry_id"],
			CaseName . " must preserve the exact active identity")
		AssertEqual(Raw, FSReadUtf8Exact(Path),
			CaseName . " rejection must preserve the persisted bytes")
	} finally try DirDelete(Dir, true)
}


_LMT_ApiImageWithFieldValue(Field, JsonValue) {
	Values := Map(
		"Id", '"one"',
		"Name", '"One"',
		"Provider", '"openai"',
		"BaseUrl", '"https://one.invalid"',
		"Token", '"secret"',
		"Model", '"m1"')
	Values[Field] := JsonValue
	Parts := []
	for Key in ["Id", "Name", "Provider", "BaseUrl", "Token", "Model"]
		Parts.Push('"' . Key . '":' . Values[Key])
	return "[{" . _LLM_MenuJoin(Parts, ",") . "}]"
}


_LMT_ApiLoaderRejectsMalformedSchemaAsOneImage() {
	global LLM_API_PROVIDERS
	Previous := _LMT_InstallFixture()
	PreviousProviders := LLM_API_PROVIDERS
	LLM_API_PROVIDERS := Map("openai", Map())
	ValidObject := '{"Id":"one","Name":"One","Provider":"openai",'
		. '"BaseUrl":"https://one.invalid","Token":"secret","Model":"m1"}'
	try {
		_LMT_AssertApiImageRejected(ValidObject, "non-array top-level JSON")
		_LMT_AssertApiImageRejected("[" . ValidObject . "] trailing",
			"JSON with trailing data")
		for Field in ["Id", "Name", "Provider", "BaseUrl", "Token", "Model"]
			_LMT_AssertApiImageRejected(_LMT_ApiImageWithFieldValue(Field, "42"),
				"non-string required field " . Field)
		_LMT_AssertApiImageRejected('[{"Id":"one","Name":"One",'
			. '"Provider":"","BaseUrl":"https://one.invalid",'
			. '"Token":"secret","Model":"m1"}]', "empty provider")
		_LMT_AssertApiImageRejected('[{"Id":"one","Name":"One",'
			. '"Provider":"openai","BaseUrl":"https://one.invalid",'
			. '"Token":"secret"}]', "missing required field")
	} finally {
		LLM_API_PROVIDERS := PreviousProviders
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM API entries: loader rejects malformed schema as one image "
	. "(api-entry-identity-cardinality)",
	_LMT_ApiLoaderRejectsMalformedSchemaAsOneImage)


_LMT_ApiParserPreservesEscapedStrings() {
	Providers := Map("openai", Map())
	Parsed := _LLM_Menu_ParseAndValidateApiEntries(
		'[{"Id":"one","Name":"Quoted \"name\"","Provider":"openai",'
		. '"BaseUrl":"https://one.invalid/{path}",'
		. '"Token":"brace{token}\\tail","Model":"m1"}]',
		Providers, (Token) => Token)
	AssertTrue(Parsed["ok"],
		"the strict parser must retain valid escaped strings and literal braces")
	AssertEqual('Quoted "name"', Parsed["entries"][1]["Name"])
	AssertEqual("https://one.invalid/{path}", Parsed["entries"][1]["BaseUrl"])
	AssertEqual("brace{token}\tail", Parsed["entries"][1]["Token"])
}
_LMT_RetiredProviderRowIsKeptNotFatal() {
	Providers := Map("openai", Map())
	Raw := '[{"Id":"old","Name":"Old","Provider":"gone",'
		. '"BaseUrl":"https://old.invalid","Token":"opaque-token","Model":"m0"},'
		. '{"Id":"one","Name":"One","Provider":"openai",'
		. '"BaseUrl":"https://one.invalid","Token":"secret","Model":"m1"}]'
	Decrypted := []
	Parsed := _LLM_Menu_ParseAndValidateApiEntries(Raw, Providers,
		(Token) => (Decrypted.Push(Token), Token))
	AssertTrue(Parsed["ok"],
		"a row naming a retired provider must not reject the rest of the file")
	AssertEqual(1, Parsed["entries"].Length)
	AssertEqual("one", Parsed["entries"][1]["Id"])
	AssertEqual(1, Parsed["retired"].Length)
	AssertEqual("old", Parsed["retired"][1]["Id"])
	AssertEqual(1, Decrypted.Length,
		"a retired row must never reach token decryption")

	; The retired row is written back as stored behind the live rows.
	State := Map("api_entries", Parsed["entries"],
		"api_entries_retired", Parsed["retired"], "api_entry_id", "one")
	Image := _LLM_Menu_SerializeApiEntries(State, _LMT_StableEncryptToken)
	AssertTrue(Image is String, "a state with a retired row must serialize")
	AssertContains(Image, '"Id":"old","Name":"Old","Provider":"gone"')
	AssertContains(Image, '"Token":"opaque-token"',
		"the retired token must be written back unchanged, not re-encrypted")
	Reread := _LLM_Menu_ParseAndValidateApiEntries(Image, Providers,
		(Token) => Token)
	AssertEqual(1, Reread["retired"].Length)

	; A live id equal to a retired id would make the image ambiguous.
	Clash := Map("api_entries", [_LMT_ApiEntry("old", "New")],
		"api_entries_retired", Parsed["retired"], "api_entry_id", "old")
	AssertFalse(_LLM_Menu_SerializeApiEntries(Clash, _LMT_StableEncryptToken),
		"a live entry must not reuse a retired row's id")
	AssertTrue(_LLM_Menu_ApiSourceOwned(Raw),
		"a retired row is owned by the writer, so the file stays writable")
}
Test("LLM API entries: a retired provider row is kept and written back "
	. "(api-entry-retired-provider-row)",
	_LMT_RetiredProviderRowIsKeptNotFatal)


Test("LLM API entries: strict parser preserves escaped strings and braces "
	. "(api-entry-identity-cardinality)",
	_LMT_ApiParserPreservesEscapedStrings)


_LMT_ApiEntryControlCharactersNeverPublish() {
	Providers := Map("openai", Map())
	for Field in ["Id", "Name", "BaseUrl", "Token", "Model"] {
		Raw := _LMT_ApiImageWithFieldValue(Field, '"bad\noutput = injected"')
		Parsed := _LLM_Menu_ParseAndValidateApiEntries(
			Raw, Providers, (Token) => Token)
		AssertFalse(Parsed["ok"],
			"(ahk2-12-curl-config-boundary) persisted control-bearing " . Field
			. " must reject the complete image")

		Candidate := Map("api_entries", [_LMT_ApiEntry("live", "Live")],
			"api_entry_id", "live")
		Before := _LLM_Menu_SerializeApiEntries(Candidate, _LMT_StableEncryptToken)
		NewEntry := _LMT_ApiEntry("new", "New")
		NewEntry[Field] .= "`noutput = injected"
		AssertFalse(_LLM_Menu_UpsertApiEntryCandidate(Candidate, NewEntry, ""),
			"(ahk2-12-curl-config-boundary) interactive control-bearing " . Field
			. " must be refused before candidate mutation")
		AssertEqual(Before,
			_LLM_Menu_SerializeApiEntries(Candidate, _LMT_StableEncryptToken),
			"a refused API entry must preserve the detached graph byte-for-byte")
	}
	EncryptedImage := _LMT_ApiImageWithFieldValue("Token", '"encrypted"')
	DecryptedControl := _LLM_Menu_ParseAndValidateApiEntries(
		EncryptedImage, Providers, (*) => "secret`nheader = injected")
	AssertFalse(DecryptedControl["ok"],
		"(ahk2-12-curl-config-boundary) controls revealed by token decryption must fail closed")
}
Test("LLM API entries: control characters never publish from disk or CRUD "
	. "(ahk2-12-curl-config-boundary)",
	_LMT_ApiEntryControlCharactersNeverPublish)


_LMT_DuplicateApiCandidatesRefuseEveryCrudMutation() {
	DuplicateA := _LMT_ApiEntry("duplicate", "First")
	DuplicateB := _LMT_ApiEntry("duplicate", "Second")

	SelectCandidate := Map("api_entries", [DuplicateA, DuplicateB],
		"api_entry_id", "before")
	AssertFalse(_LLM_Menu_SelectApiEntryCandidate(SelectCandidate, "duplicate"))
	AssertEqual("before", SelectCandidate["api_entry_id"])

	EditCandidate := Map("api_entries", [DuplicateA, DuplicateB],
		"api_entry_id", "duplicate")
	BeforeEdit := _LLM_Menu_SerializeApiEntries(EditCandidate, _LMT_StableEncryptToken)
	AssertFalse(_LLM_Menu_UpsertApiEntryCandidate(EditCandidate,
		_LMT_ApiEntry("duplicate", "Replacement"), "duplicate"),
		"editing an ambiguous identity must refuse instead of replacing the first row")
	AssertEqual(BeforeEdit,
		_LLM_Menu_SerializeApiEntries(EditCandidate, _LMT_StableEncryptToken),
		"a refused ambiguous edit must leave every credential byte unchanged")

	RemoveCandidate := Map("api_entries", [DuplicateA, DuplicateB],
		"api_entry_id", "duplicate")
	BeforeRemove := _LLM_Menu_SerializeApiEntries(RemoveCandidate, _LMT_StableEncryptToken)
	AssertFalse(_LLM_Menu_RemoveApiEntryCandidate(RemoveCandidate, "duplicate"))
	AssertEqual(BeforeRemove,
		_LLM_Menu_SerializeApiEntries(RemoveCandidate, _LMT_StableEncryptToken),
		"a refused ambiguous removal must leave every credential byte unchanged")

	CorruptSiblingCandidate := Map("api_entries", [
		_LMT_ApiEntry("duplicate", "First"),
		_LMT_ApiEntry("duplicate", "Second"),
		_LMT_ApiEntry("unique", "Unique")], "api_entry_id", "unique")
	BeforeSiblingEdit := _LLM_Menu_SerializeApiEntries(
		CorruptSiblingCandidate, _LMT_StableEncryptToken)
	AssertFalse(_LLM_Menu_UpsertApiEntryCandidate(CorruptSiblingCandidate,
		_LMT_ApiEntry("unique", "Replacement"), "unique"),
		"CRUD must refuse a corrupt sibling identity outside the selected target")
	AssertEqual(BeforeSiblingEdit, _LLM_Menu_SerializeApiEntries(
		CorruptSiblingCandidate, _LMT_StableEncryptToken))
}
Test("LLM API entries: duplicate candidate ids refuse select edit and remove "
	. "(api-entry-identity-cardinality)",
	_LMT_DuplicateApiCandidatesRefuseEveryCrudMutation)


_LMT_UniqueApiCandidatesMutateExactlyOneRow() {
	First := _LMT_ApiEntry("first", "First")
	Second := _LMT_ApiEntry("second", "Second")

	SelectCandidate := Map("api_entries", [First, Second],
		"api_entry_id", "first")
	AssertTrue(_LLM_Menu_SelectApiEntryCandidate(SelectCandidate, "second"))
	AssertEqual("second", SelectCandidate["api_entry_id"])

	EditCandidate := Map("api_entries", [First, Second],
		"api_entry_id", "first")
	AssertTrue(_LLM_Menu_UpsertApiEntryCandidate(EditCandidate,
		_LMT_ApiEntry("second", "Replacement"), "second"))
	AssertEqual("First", EditCandidate["api_entries"][1]["Name"])
	AssertEqual("Replacement", EditCandidate["api_entries"][2]["Name"])

	RemoveCandidate := Map("api_entries", [First, Second],
		"api_entry_id", "second")
	AssertTrue(_LLM_Menu_RemoveApiEntryCandidate(RemoveCandidate, "second"))
	AssertEqual(1, RemoveCandidate["api_entries"].Length)
	AssertEqual("first", RemoveCandidate["api_entries"][1]["Id"])
}
Test("LLM API entries: unique candidate ids mutate exactly one row "
	. "(api-entry-identity-cardinality)",
	_LMT_UniqueApiCandidatesMutateExactlyOneRow)

_LMT_SharedApiActiveCommandRows() {
	global _LLM_Menu, _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\api_active_commands.json"))
	Assert(Corpus is Map, "the independent active API commands corpus must be readable")
	Root := _MM_GetManifestRoot()
	Assert(Root is Map, "the real shared menu must be present")
	Declarations := Root[Corpus["section"]]
	AssertEqual(2, Declarations.Length)
	SavedTestKey := Declarations[1]["i18n"]
	Previous := _LMT_InstallFixture()
	try {
		_LLM_Menu["api_entries"] := [_LMT_ApiEntry("active")]
		_LLM_Menu["api_entry_id"] := "active"
		Declarations[1]["i18n"] := "button.cancel"
		Rows := _LLM_Menu_ApiEntriesRows()
		AssertEqual(t("button.cancel"), Rows[Rows.Length - 2]["label"],
			"the actual provider reads the canonical Test caption")
		AssertEqual(t("menu.llm.api_edit_entry"), Rows[Rows.Length - 1]["label"],
			"the existing native Edit action stays immediately before removal")
		AssertEqual(t(Corpus["rows"][2]["i18n"]), Rows[Rows.Length]["label"])
		for Index, Expected in Corpus["rows"] {
			AssertEqual(Expected["id"], Declarations[Index]["id"])
			AssertEqual(Corpus["ready"], Declarations[Index]["disabled_when"][1])
		}
		HeldTest := Rows[Rows.Length - 2]["action"]
		HeldRemove := Rows[Rows.Length]["action"]
		_LLM_Menu["api_entry_id"] := ""
		AssertEqual(false, HeldTest.Call(), "a revoked active owner cannot acquire a test request")
		AssertEqual(false, HeldRemove.Call(), "a revoked active owner cannot open the removal dialog")
		AssertEqual(1, _LLM_Menu["api_entries"].Length)
	} finally {
		Declarations[1]["i18n"] := SavedTestKey
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM API: actual shared active commands preserve Edit and refuse revoked owners",
	_LMT_SharedApiActiveCommandRows)

; Only the unrelated collector/JSON ports are controlled; configuration rendering
; and both WAL filesystem targets use their actual production implementations.
_LMT_ApiSemanticRows(CandidateFeatures, CandidateMenu) {
	return [
		{ Section: "llm", Key: "enabled", Value: TOML_Bool(CandidateMenu["enabled"]) },
		{ Section: "llm", Key: "api_entry_id", Value: CandidateMenu["api_entry_id"] }
	]
}
_LMT_ApiSemanticDetachedBuilder() {
	global ConfigurationFile, _PathsFile, _LLM_Menu, Features, _LMT_ApiPath
	global _LMT_ApplyCalls, _ConfigBootReadFailed, _ConfigBootRejectedOverrides
	global _ConfigBootOutdatedEntries, _ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots
	Previous := _LMT_InstallApiFixture()
	OldRead := _ConfigBootReadFailed, OldRejected := _ConfigBootRejectedOverrides
	OldOutdated := _ConfigBootOutdatedEntries
	Source := '_meta.schema_version = ' . ConfigMigrateCurrentVersion() . '`nllm = {enabled = false, api_entry_id = "api_old", future = "retain"}`n[future]`nold = "retain" # user data`n'
	Expected := Chr(0xFEFF) . '_meta.schema_version = ' . ConfigMigrateCurrentVersion() . '`nllm = {enabled = true, api_entry_id = "api_new", future = "retain"}`n[future]`nold = "retain" # user data`n'
	try {
		_ConfigBootReadFailed := false
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		AssertEqual(1, FSWrite(ConfigurationFile, Source))
		BeforeFeatures := Features
		BeforeMenu := _LLM_Menu
		Result := LLM_Menu_CommitApiEntriesMutation("the semantic API entry",
			_LMT_ApiMutate, _LMT_Apply, ConfigTransitionProductionPort(),
			_LMT_Notify, _LMT_Acquire, _LMT_Settle, _LMT_ApiSemanticRows,
			0, _LMT_ApiSerialize)
		AssertTrue((Result is Integer) && Result == 1, "the actual detached builder admits the complete inline source")
		AssertEqual(Expected, FSReadUtf8Exact(ConfigurationFile))
		AssertEqual('[{"Id":"api_new"}]', FSReadUtf8Exact(_LMT_ApiPath))
		AssertEqual("api_new", _LLM_Menu["api_entry_id"])
		AssertTrue(_LLM_Menu["enabled"])
		AssertEqual(1, _LMT_ApplyCalls)
		AssertFalse(BeforeMenu["enabled"], "publication cannot mutate the old detached menu authority")
		AssertFalse(BeforeFeatures["llm"]["enabled"], "publication cannot mutate the old feature authority")
		AssertFalse(FSStrictExists(ConfigTransitionWalPath(_PathsFile)) == 1)
		AssertFalse(_ConfigWriteTerminalIsActive())
		AssertFalse(ConfigWriteLeaseBusy())
		Cache := ParseConfigTomlFile(ConfigurationFile)
		AssertEqual("api_new", IniCacheGet(Cache, "llm", "api_entry_id"))
		AssertEqual("retain", IniCacheGet(Cache, "llm", "future"))
	} finally {
		_ConfigBootReadFailed := OldRead
		_ConfigBootRejectedOverrides := OldRejected
		_ConfigBootOutdatedEntries := OldOutdated
		for Store in [_ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots] {
			if Store.Has(ConfigurationFile)
				Store.Delete(ConfigurationFile)
		}
		_LMT_RestoreApiFixture(Previous)
	}
}
Test("LLM API entries: actual detached config builder preserves inline and future records (config-full-semantic-successor)",
	_LMT_ApiSemanticDetachedBuilder)

; Causal withdrawal: the same real port and first-target seam succeed when the
; acquired native handle is physically closed before second-target publication.
_LMT_ApiPhysicalFaultWithdrawalAllowsBothTargets() {
	global _LMT_ApiFault, _LMT_ApiPath, _LMT_ApiRefused, _LMT_ApplyCalls
	global _LLM_Menu, ConfigurationFile, _PathsFile
	Previous := _LMT_InstallApiFixture()
	try {
		AssertTrue(_LMT_ApiCommit(_LMT_ApiFailingPort(true)))
		AssertEqual(1, _LMT_ApiFault.Published)
		AssertEqual(1, _LMT_ApiFault.Closed)
		AssertEqual(0, _LMT_ApiFault.Handle)
		AssertEqual(0, _LMT_ApiFault.Notified)
		AssertEqual(1, _LMT_ApiFault.NativeRefusals)
		AssertFalse(_LMT_ApiRefused)
		AssertTrue(ConfigTransitionProductionPort(_LMT_ApiFault.Port))
		AssertTrue(_LMT_ApiFault.Port == ConfigTransitionProductionPort())
		AssertContains(FSReadUtf8Exact(ConfigurationFile), 'api_entry_id = "api_new"')
		AssertEqual('[{"Id":"api_new"}]', FSReadUtf8Exact(_LMT_ApiPath))
		AssertEqual("api_new", _LLM_Menu["api_entry_id"])
		AssertTrue(_LLM_Menu["enabled"])
		AssertEqual(1, _LMT_ApplyCalls)
		AssertFalse(FSStrictExists(ConfigTransitionWalPath(_PathsFile)) == 1)
		AssertFalse(_ConfigWriteTerminalIsActive())
	} finally _LMT_RestoreApiFixture(Previous)
}
Test("LLM API entries: physical second-target fault withdrawal preserves native publication",
	_LMT_ApiPhysicalFaultWithdrawalAllowsBothTargets)
