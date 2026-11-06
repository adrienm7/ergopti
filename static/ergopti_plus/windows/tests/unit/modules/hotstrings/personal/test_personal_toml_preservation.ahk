; tests/unit/modules/hotstrings/personal/test_personal_toml_preservation.ahk

; ==============================================================================
; MODULE: Personal Editor Source Preservation Tests
; DESCRIPTION:
; Independent shared vectors exercise the real native writer and its physical
; source fence. Native execution remains required on Windows.
; ==============================================================================

#Requires AutoHotkey v2.0

_PTIO_PreservationVector(Vector) {
	global ScriptInformation, _ReadPersonalTomlCache, JSON_NULL
	Path := A_Temp . "\ergopti_personal_preservation_" . A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"], OldCache := _ReadPersonalTomlCache
	try {
		try FileDelete(Path)
		ScriptInformation["PersonalTomlPath"] := Path
		_ReadPersonalTomlCache := false
		Present := Vector.Get("source", JSON_NULL) != JSON_NULL
		if Present
			AssertTrue(FSWriteDurable(Path, Vector["source"]))
		Data := Vector["model"]
		if Present && Vector["name"] == "retained rows preserve foreign metadata and comments" {
			Observed := ReadPersonalToml(true)
			AssertEqual("Words", Observed["sections"]["words"]["description"],
				"nested metadata descriptions must be presented without replacing them with a fallback")
		}
		Order := _PersonalTomlCanonicalSectionOrder(Data, &Detail)
		Assert(Order is Array, Detail)
		if Vector.Has("refusal") {
			ErrorMessage := ""
			try _PersonalTomlPreserveModel(Vector["source"], Data, Order)
			catch as Err
				ErrorMessage := Err.Message
			AssertEqual(Vector["refusal"], ErrorMessage)
			AssertFalse(WritePersonalToml(Data), "the public writer must refuse the same unsafe ownership operation")
			AssertEqual(Vector["source"], FSReadUtf8Exact(Path), "refusal must retain the exact source")
			return
		}
		AssertTrue(WritePersonalToml(Data), "the real source-preserving native writer must publish the admitted model")
		Actual := FSReadUtf8Exact(Path)
		for Text in Vector.Get("contains", [])
			AssertContains(Actual, Text)
		for Text in Vector.Get("absent", [])
			AssertFalse(InStr(Actual, Text, true), "explicit deletion must remain authoritative")
		if Vector.Has("ends_with_newline")
			AssertEqual(Vector["ends_with_newline"], SubStr(Actual, -1) == "`n")
		Document := TOML_ParseDocument(Actual)
		for KeyPath in Vector.Get("arrays", []) {
			Value := Document
			for Part in StrSplit(KeyPath, ".")
				Value := Value is Array ? Value[Integer(Part)] : Value[Part]
			Assert(Value is Array, KeyPath . " must remain a typed native TOML array")
		}
		for KeyPath, Expected in Vector.Get("decoded", Map()) {
			Value := Document
			for Part in StrSplit(KeyPath, ".")
				Value := Value is Array ? Value[Integer(Part)] : Value[Part]
			if Value is TOML_Bool
				Value := Value.Value
			AssertEqual(Expected, Value, KeyPath)
		}
	} finally {
		try FileDelete(Path)
		_PersonalTomlInvalidateCaches(Path)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}

_PTIO_PreservationCorpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\hotstrings\personal_editor_preservation.json", "UTF-8"))["vectors"]
AssertEqual(23, _PTIO_PreservationCorpus.Length, "the native replay must cover the independently authored preservation inventory")
for _PTIO_PreservationCase in _PTIO_PreservationCorpus
	Test("personal-editor-preservation: " . _PTIO_PreservationCase["name"],
		_PTIO_PreservationVector.Bind(_PTIO_PreservationCase))

_PTIO_PreservationConcurrentStage(Path, Replacement, StagePath, Content) {
	AssertTrue(FSWriteDurable(StagePath, Content))
	AssertTrue(FSWriteDurable(Path, Replacement))
	return true
}

_PTIO_PreservationChangedSourceRefuses() {
	global ScriptInformation, _ReadPersonalTomlCache
	Path := A_Temp . "\ergopti_personal_preservation_fence_" . A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"], OldCache := _ReadPersonalTomlCache
	Original := '[[race]]`n"old" = { output = "Before", is_word = false, auto_expand = true, is_case_sensitive = false, final_result = false }`n'
	Replacement := Original . '# Concurrent user changes remain authoritative.`n'
	try {
		try FileDelete(Path)
		ScriptInformation["PersonalTomlPath"] := Path
		_ReadPersonalTomlCache := false
		AssertTrue(FSWriteDurable(Path, Original))
		Data := ReadPersonalToml(true)
		Data["sections"]["race"]["entries"][1]["output"] := "After"
		AssertFalse(WritePersonalToml(Data, _PTIO_PreservationConcurrentStage.Bind(Path, Replacement)),
			"a staging yield must not publish against a changed source image")
		AssertEqual(Replacement, FSReadUtf8Exact(Path))
	} finally {
		try FileDelete(Path)
		_PersonalTomlInvalidateCaches(Path)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal-editor-preservation: a changed durable image refuses after staging", _PTIO_PreservationChangedSourceRefuses)

_PTIO_PreservationMetadataAliasesRefuse() {
	global ScriptInformation, _ReadPersonalTomlCache
	Path := A_Temp . "\ergopti_personal_preservation_alias_" . A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"], OldCache := _ReadPersonalTomlCache
	Row := '[[words]]`n"hello" = { output = "Before", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
	try {
		try FileDelete(Path)
		ScriptInformation["PersonalTomlPath"] := Path
		for Metadata in ['[_META]`nsections_order = ["words"]`n',
				'[_meta]`n"Sections_Order" = ["words"]`n',
				'[_meta.sections.words]`n"Description" = "foreign"`n'] {
			Source := Metadata . Row
			AssertTrue(FSWriteDurable(Path, Source))
			Data := ReadPersonalToml(true)
			Data["sections"]["words"]["entries"][1]["output"] := "After"
			AssertFalse(WritePersonalToml(Data), "case aliases must not gain a neighboring canonical metadata owner")
			AssertEqual(Source, FSReadUtf8Exact(Path))
		}
	} finally {
		try FileDelete(Path)
		_PersonalTomlInvalidateCaches(Path)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal-editor-preservation: case aliases refuse metadata publication", _PTIO_PreservationMetadataAliasesRefuse)

_PTIO_PreservationDescendantsKeepArrayAssociations() {
	global ScriptInformation, _ReadPersonalTomlCache
	Path := A_Temp . "\ergopti_personal_preservation_child_" . A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"], OldCache := _ReadPersonalTomlCache
	Source := '[[words]]`n"first" = { output = "Before", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
		. '[words.future]`nowner = "first child"`n'
		. '[[words]]`n"second" = { output = "Second", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
		. '[words.future]`nowner = "second child"`n'
	try {
		try FileDelete(Path)
		ScriptInformation["PersonalTomlPath"] := Path
		AssertTrue(FSWriteDurable(Path, Source))
		Data := ReadPersonalToml(true)
		AssertEqual(2, Data["sections"]["words"]["entries"].Length)
		Data["sections"]["words"]["entries"][1]["output"] := "After"
		AssertTrue(WritePersonalToml(Data), "a row edit must retain every foreign child namespace association")
		Actual := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertEqual(2, Actual["words"].Length)
		AssertEqual("first child", Actual["words"][1]["future"]["owner"])
		AssertEqual("second child", Actual["words"][2]["future"]["owner"])
		AssertEqual("After", Actual["words"][1]["first"]["output"])
		AssertEqual("Second", Actual["words"][2]["second"]["output"])
		BeforeDeletion := FSReadUtf8Exact(Path)
		Data := Map("sections", Map(), "sections_order", [])
		AssertFalse(WritePersonalToml(Data), "a projected section deletion cannot discard hidden descendants")
		AssertEqual(BeforeDeletion, FSReadUtf8Exact(Path))
	} finally {
		try FileDelete(Path)
		_PersonalTomlInvalidateCaches(Path)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal-editor-preservation: foreign children retain their array element", _PTIO_PreservationDescendantsKeepArrayAssociations)

_PTIO_PreservationDeletedRowsKeepComments() {
	global ScriptInformation, _ReadPersonalTomlCache
	Path := A_Temp . "\ergopti_personal_preservation_comment_" . A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"], OldCache := _ReadPersonalTomlCache
	Source := '[[words]]`n"hello" = { output = "Hash#inside", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false } # User comment survives deletion.'
	try {
		try FileDelete(Path)
		ScriptInformation["PersonalTomlPath"] := Path
		for DeleteSection in [false, true] {
			AssertTrue(FSWriteDurable(Path, Source))
			Data := ReadPersonalToml(true)
			if DeleteSection
				Data := Map("sections", Map(), "sections_order", [])
			else
				Data["sections"]["words"]["entries"] := []
			AssertTrue(WritePersonalToml(Data))
			Actual := FSReadUtf8Exact(Path)
			AssertContains(Actual, '# User comment survives deletion.')
			AssertFalse(InStr(Actual, 'Hash#inside', true), "literal hashes must not become phantom comments")
			AssertFalse(InStr(Actual, '"hello" =', true), "the deleted assignment must stay deleted")
		}
	} finally {
		try FileDelete(Path)
		_PersonalTomlInvalidateCaches(Path)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal-editor-preservation: deleting rows preserves standalone trailing comments", _PTIO_PreservationDeletedRowsKeepComments)

_PTIO_PreservationDeletedHeadersKeepComments() {
	global ScriptInformation, _ReadPersonalTomlCache
	Path := A_Temp . "\ergopti_personal_preservation_header_" . A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"], OldCache := _ReadPersonalTomlCache
	Source := '[["hash#words"]] # User header comment.`n"hello" = { output = "Before", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
	try {
		try FileDelete(Path)
		ScriptInformation["PersonalTomlPath"] := Path
		AssertTrue(FSWriteDurable(Path, Source))
		Observed := ReadPersonalToml(true)
		AssertEqual(1, Observed["sections_order"].Length, "a header comment must not hide the displayed section")
		AssertTrue(WritePersonalToml(Map("sections", Map(), "sections_order", [])))
		Actual := FSReadUtf8Exact(Path)
		AssertContains(Actual, '# User header comment.')
		AssertFalse(InStr(Actual, 'hash#words', true), "a quoted name's hash is not a comment")
		AssertFalse(InStr(Actual, '"hello" =', true))
	} finally {
		try FileDelete(Path)
		_PersonalTomlInvalidateCaches(Path)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal-editor-preservation: deleting section headers preserves their comments", _PTIO_PreservationDeletedHeadersKeepComments)

_PTIO_PreservationQuotedMetadataProjection() {
	Source := '[_meta]`n"sections_order" = ["second", "first"]`n'
		. '[_meta.sections]`n"first" = "First quoted description"`n'
		. '[_meta.sections.second]`n"description" = "Second nested description"`n'
		. '[[first]]`n"a" = { output = "First", is_word = false, auto_expand = true, is_case_sensitive = false, final_result = false }`n'
		. '[[second]]`n"b" = { output = "Second", is_word = false, auto_expand = true, is_case_sensitive = false, final_result = false }`n'
	Data := ReadPersonalToml(true, 0, Source)
	AssertEqual("second", Data["sections_order"][1], "the semantic sections order must take precedence over physical headers")
	AssertEqual("first", Data["sections_order"][2])
	AssertEqual("First quoted description", Data["sections"]["first"]["description"])
	AssertEqual("Second nested description", Data["sections"]["second"]["description"])
}
Test("personal-editor-preservation: quoted and nested metadata drive the displayed model", _PTIO_PreservationQuotedMetadataProjection)

_PTIO_PreservationUnownedDescriptions(EditDescription) {
	global ScriptInformation, _ReadPersonalTomlCache
	Path := A_Temp . "\ergopti_personal_preservation_description_" . A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"], OldCache := _ReadPersonalTomlCache
	Row := '[[words]]`n"hello" = { output = "Before", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
	try {
		try FileDelete(Path)
		ScriptInformation["PersonalTomlPath"] := Path
		for Metadata in ['[_meta.sections.words]`ndescription = { en = "Words", unknown_language = "Untouched" }`n',
				'[_meta.sections]`nwords = { en = "Words", unknown_language = "Untouched" }`n',
				'[_meta.sections]`nwords = 12`n', '[_meta.sections]`nwords = ["Unseen description"]`n'] {
			Source := Metadata . Row
			AssertTrue(FSWriteDurable(Path, Source))
			Data := ReadPersonalToml(true)
			AssertEqual("words", Data["sections"]["words"]["description"], "an unprojected description displays only the section fallback")
			Data["sections"]["words"]["entries"][1]["output"] := "After"
			if EditDescription {
				Data["sections"]["words"]["description"] := "Replacement"
				ErrorMessage := ""
				try _PersonalTomlPreserveModel(Source, Data, ["words"])
				catch as Err
					ErrorMessage := Err.Message
				AssertEqual("unowned-personal-description", ErrorMessage)
				AssertFalse(WritePersonalToml(Data), "a changed fallback cannot replace unseen description data")
				AssertEqual(Source, FSReadUtf8Exact(Path))
			} else {
				AssertTrue(WritePersonalToml(Data), "an unrelated row edit must leave invisible descriptions untouched")
				Actual := FSReadUtf8Exact(Path)
				AssertContains(Actual, Metadata)
				Document := TOML_ParseDocument(Actual)
				AssertEqual("After", Document["words"][1]["hello"]["output"])
			}
		}
	} finally {
		try FileDelete(Path)
		_PersonalTomlInvalidateCaches(Path)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal-editor-preservation: unchanged fallbacks preserve invisible description data", _PTIO_PreservationUnownedDescriptions.Bind(false))
Test("personal-editor-preservation: edited fallbacks refuse replacing invisible description data", _PTIO_PreservationUnownedDescriptions.Bind(true))

#Include test_personal_info_editor_consent.ahk

_PNOS_Case(Invalid) {
	global ScriptInformation, _ReadPersonalTomlCache, _TomlUnreadableFiles
	OldCache := _ReadPersonalTomlCache
	HadPath := ScriptInformation.Has("PersonalTomlPath")
	OldPath := ScriptInformation.Get("PersonalTomlPath", "")
	Root := A_Temp . "\ergopti_personal_output_scalar_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . "\personal_hotstrings.toml", Created := false
	try {
		AssertFalse(_ConfigFullSaveHasPending(), "the private personal path must not detach a foreign accepted full-save obligation")
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		ScriptInformation["PersonalTomlPath"] := Path
		_ReadPersonalTomlCache := false
		Source := '[[words]]`n"hello" = { output = "Original", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		Observed := ReadPersonalToml(true)
		AssertEqual(1, Observed["sections"]["words"]["entries"].Length)
		AssertEqual("Original", Observed["sections"]["words"]["entries"][1]["output"])
		Candidate := _PersonalTomlCloneDetached(Observed)
		Payload := JsonParse(Invalid ? '{"output":"A\u0000B"}' : '{"output":"A\nB\tC"}')
		Value := Payload["output"]
		AssertTrue(Value is String)
		if Invalid {
			AssertEqual(3, StrLen(Value))
			AssertEqual(65, NumGet(StrPtr(Value), 0, "UShort"))
			AssertEqual(0, NumGet(StrPtr(Value), 2, "UShort"))
			AssertEqual(66, NumGet(StrPtr(Value), 4, "UShort"))
		} else
			AssertEqual("A`nB`tC", Value)
		Candidate["sections"]["words"]["entries"][1]["output"] := Value
		Before := FSReadBytesStrict(Path)
		Result := WritePersonalToml(Candidate)
		After := FSReadBytesStrict(Path)
		Disk := TOML_ParseDocument(FSReadUtf8Exact(Path))
		Actual := Disk["words"][1]["hello"]["output"]
		_TestPrint("# personal-output-scalar invalid=" . Invalid . " result=" . Result
			. " requested-length=" . StrLen(Value) . " actual-length=" . StrLen(Actual)
			. " before-bytes=" . Before.Size . " after-bytes=" . After.Size)
		if Invalid {
			AssertFalse(Result, "a public personal edit must refuse before normalization can truncate its original scalar")
			AssertEqual(Before.Size, After.Size)
			AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Before,
				"Ptr", After, "UPtr", Before.Size, "UPtr"), "the unsupported JSON output must not replace the original complete source")
			AssertEqual("Original", Actual)
		} else {
			AssertTrue(Result, "ordinary newline/tab input retains its canonical personal token policy")
			AssertEqual("A{Enter}B{Tab}C", Actual)
			Reloaded := ReadPersonalToml(true)
			AssertEqual("A{Enter}B{Tab}C", Reloaded["sections"]["words"]["entries"][1]["output"])
		}
	} finally {
		if Created {
			_PersonalTomlInvalidateCaches(Path)
			if _TomlUnreadableFiles.Has(Path)
				_TomlUnreadableFiles.Delete(Path)
			DirDelete(Root, true)
		}
		if HadPath
			ScriptInformation["PersonalTomlPath"] := OldPath
		else
			ScriptInformation.Delete("PersonalTomlPath")
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal output scalar: JSON NUL cannot disappear during normalization (personal-output-scalar)", _PNOS_Case.Bind(true))
Test("personal output scalar: newline and tab remain canonical tokens (personal-output-scalar)", _PNOS_Case.Bind(false))

_PSTG_ForeignStage(Collision, PersonalInfo := false) {
	Root := A_Temp . "\ergopti_personal_stage_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . (PersonalInfo ? "\personal_info.toml" : "\personal_hotstrings.toml"), Created := false
	global ScriptInformation, _ReadPersonalTomlCache, _ReadPersonalInfoTomlCache, _TomlUnreadableFiles
	PathKey := PersonalInfo ? "PersonalInfoTomlPath" : "PersonalTomlPath"
	OldCache := _ReadPersonalTomlCache, OldInfoCache := _ReadPersonalInfoTomlCache
	HadPath := ScriptInformation.Has(PathKey), OldPath := ScriptInformation.Get(PathKey, "")
	Owner := FSWriteReplaceOwned, HadOwn := Owner.HasOwnProp("Call")
	if HadOwn
		SavedCall := Owner.GetOwnPropDesc("Call")
	Installed := false
	State := {hits: 0, stagePath: "", sentinelBytes: 0, createdSentinel: 0, originalEntered: 0, originalCompleted: 0}
	Source := '[[words]]`n"hello" = { output = "Original", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
	if PersonalInfo
		Source := '[info]`nfirst_name = "Original"`n[letters]`np = "first_name"`n'
	Sentinel := "Foreign personal stage: é😀 unchanged"
	Observe(This, Target, Content, Suffix, &Detail := "", StageFn := 0,
			BeforePublishFn := 0, AdmissionFn := 0, ReplaceExisting := true,
			&Publication := 0, FlushFn := 0) {
		Mine := (Target is String) && StrCompare(Target, Path, true) == 0
		CreateOriginal(Folder, Name, Attributes) {
			SplitPath(Path, &Leaf)
			AssertEqual(Leaf . Suffix, Name, "the actual factory must name the target's exact stage leaf")
			State.hits += 1
			State.stagePath := Path . Suffix
			if Collision {
				State.createdSentinel := FSWriteCreateDurable(State.stagePath, Sentinel)
				AssertEqual(1, State.createdSentinel, "the foreign stage must actually be acquired with CREATE_NEW")
				State.sentinelBytes := FSReadBytesStrict(State.stagePath)
			}
			return StageFn.Call(Folder, Name, Attributes)
		}
		if Mine
			State.originalEntered += 1
		NativeResult := Func.Prototype.Call.Call(This, Target, Content, Suffix, &Detail,
			Mine ? CreateOriginal : StageFn, BeforePublishFn, AdmissionFn, ReplaceExisting, &Publication, FlushFn)
		if Mine
			State.originalCompleted += 1
		return NativeResult
	}
	try {
		AssertFalse(_ConfigFullSaveHasPending(), "a private personal target must not displace another accepted full-save obligation")
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		ScriptInformation[PathKey] := Path
		if PersonalInfo {
			_ReadPersonalInfoTomlCache := false
			Candidate := Map("first_name", "Edited")
		} else {
			_ReadPersonalTomlCache := false
			Observed := ReadPersonalToml(true)
			AssertEqual("Original", Observed["sections"]["words"]["entries"][1]["output"])
			Candidate := _PersonalTomlCloneDetached(Observed)
			Candidate["sections"]["words"]["entries"][1]["output"] := "Edited"
		}
		Before := FSReadBytesStrict(Path)
		Owner.DefineProp("Call", {Call: Observe})
		Installed := true
		Result := PersonalInfo ? WritePersonalInfoToml(Path, Candidate, Map("p", "first_name")) : WritePersonalToml(Candidate)
		After := FSReadBytesStrict(Path)
		StagePresent := State.stagePath != "" && FSStrictExists(State.stagePath)
		StageBytes := StagePresent ? FSReadBytesStrict(State.stagePath) : Buffer(0)
		_TestPrint("# personal-stage-ownership info=" . PersonalInfo . " collision=" . Collision . " calls=" . State.hits
			. " created_sentinel=" . State.createdSentinel . " original_entered=" . State.originalEntered
			. " original_completed=" . State.originalCompleted
			. " result=" . Result . " stage_present=" . StagePresent
			. " before_bytes=" . Before.Size . " after_bytes=" . After.Size)
		AssertEqual(1, State.hits, "the actual default personal publisher must reach its real native staging owner")
		AssertEqual(1, State.originalEntered, "the real staging writer must be delegated exactly once")
		AssertEqual(1, State.originalCompleted, "the real original writer must return before business assertions")
		AssertEqual(Collision ? 1 : 0, State.createdSentinel)
		if Collision {
			AssertTrue(StagePresent, "a personal save cannot rename or delete another owner's stage")
			AssertEqual(State.sentinelBytes.Size, StageBytes.Size)
			AssertEqual(StageBytes.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", State.sentinelBytes,
				"Ptr", StageBytes, "UPtr", StageBytes.Size, "UPtr"), "foreign bytes must remain exact")
			AssertFalse(Result)
			AssertEqual(Before.Size, After.Size)
			AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Before,
				"Ptr", After, "UPtr", Before.Size, "UPtr"), "collision refuses all target publication")
		} else {
			AssertTrue(Result)
			AssertFalse(StagePresent)
			Actual := TOML_ParseDocument(FSReadUtf8Exact(Path))
			AssertEqual("Edited", PersonalInfo ? Actual["info"]["first_name"] : Actual["words"][1]["hello"]["output"])
		}
	} finally {
		if Installed {
			if HadOwn
				Owner.DefineProp("Call", SavedCall)
			else
				Owner.DeleteProp("Call")
		}
		if Created {
			_PersonalTomlInvalidateCaches(Path)
			if _TomlUnreadableFiles.Has(Path)
				_TomlUnreadableFiles.Delete(Path)
			Refusals := _TOML_WriteRefusals(), RefusalKey := _TOML_WriteRefusalKey(Path)
			if Refusals.Has(RefusalKey)
				Refusals.Delete(RefusalKey)
			DirDelete(Root, true)
		}
		if HadPath
			ScriptInformation[PathKey] := OldPath
		else
			ScriptInformation.Delete(PathKey)
		_ReadPersonalTomlCache := OldCache
		_ReadPersonalInfoTomlCache := OldInfoCache
	}
}
for _PSTG_Collision in [true, false]
	Test("personal stage: foreign collision=" . _PSTG_Collision . " (personal-stage-ownership)", _PSTG_ForeignStage.Bind(_PSTG_Collision))

for _PSTG_InfoCollision in [true, false]
	Test("personal information stage: foreign collision=" . _PSTG_InfoCollision . " (personal-info-stage-ownership)",
		_PSTG_ForeignStage.Bind(_PSTG_InfoCollision, true))
