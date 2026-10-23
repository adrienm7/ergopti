; tests/unit/modules/keystats/test_keystats_app_category_edit_contract.ahk

; ==============================================================================
; MODULE: App Category Edit Store Contracts
; DESCRIPTION:
; Exercises the canonical file, edit snapshots and native staging admission.
; Unknown metadata and discoveries survive without treating legacy labels as edits.
; ==============================================================================

_KLACEC_With(Callback) {
	static Serial := 0
	PreviousCritical := Critical("On")
	Saved := Map()
	for Key in ["categories", "file_path", "dirty", "save_fn", "write_owner", "store_model"]
		if KLAppCat.HasOwnProp(Key)
			Saved[Key] := KLAppCat.%Key%
	Root := A_Temp . "\ergopti_appcat_contract_" . A_ScriptHwnd . "_" . ++Serial
	Path := Root . "\" . KLAppCatConst.FILE_NAME
	Timer := (*) => 0
	Owned := false, Primary := 0, CleanupError := 0
	try {
		AssertTrue(Saved.Get("write_owner", 0) is Integer && Saved.Get("write_owner", 0) == 0,
			"the fixture cannot replace a foreign category writer")
		FSCreateDirectoryExclusiveStrict(Root), Owned := true
		Content := '{"schema":"ergopti.app_categories","version":1,"apps":{'
			. '"audit.exe":{"type":"productive","score":1,"extra":{"flag":true,"nil":null}},'
			. '"other.exe":"neutral"},"metadata":{"flag":true,"nil":null,"array":[true,null]}}' . "`n"
		AssertTrue(FSWriteCreateDurable(Path, Content))
		KLAppCat.categories := Map(), KLAppCat.file_path := "", KLAppCat.dirty := false
		KLAppCat.save_fn := Timer, KLAppCat.write_owner := 0, KLAppCat.store_model := 0
		AssertTrue(KL_AppCat_Init(Root), "the real decoder must admit the mixed canonical source")
		Callback.Call(Root, Path, Content)
	} catch as Failure {
		Primary := Failure
	} finally {
		try SetTimer(Timer, 0)
		catch as Failure {
			CleanupError := Failure
		} finally {
			for Key in ["categories", "file_path", "dirty", "save_fn", "write_owner", "store_model"] {
				if Saved.Has(Key)
					KLAppCat.%Key% := Saved[Key]
				else if KLAppCat.HasOwnProp(Key)
					KLAppCat.DeleteProp(Key)
			}
			Critical(PreviousCritical)
		}
		if Owned {
			try DirDelete(Root, true)
			catch as Failure {
				if !IsObject(CleanupError)
					CleanupError := Failure
			}
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupError)
		throw CleanupError
}

_KLACEC_Invalid(Kind, Root, Path, Original) {
	Admitted := KLAppCat.categories
	Model := KLAppCat.store_model
	Changed := Kind == "version"
		? StrReplace(Original, '"version":1', '"version":2')
		: StrReplace(Original, '"score":1', '"score":true')
	AssertTrue(Changed != Original, "the malformed file must differ at its intended schema coordinate")
	AssertTrue(FSWriteDurable(Path, Changed))
	Snapshot := KL_AppCat_EditorSnapshot("audit.exe", Root)
	AssertTrue(Snapshot is Integer && Snapshot == 0, "invalid canonical data cannot become dialog defaults")
	AssertTrue(KLAppCat.categories == Admitted && KLAppCat.store_model == Model,
		"a refused source cannot replace either admitted runtime authority")
	AssertEqual(Changed, FSReadUtf8Exact(Path), "the malformed source must remain available for correction")
	AssertFalse(KLAppCat.dirty)
}

_KLACEC_Metadata(Root, Path, Original) {
	Snapshot := KL_AppCat_EditorSnapshot("AUDIT.EXE", Root)
	AssertTrue(Snapshot is Map)
	AssertEqual("productive", Snapshot["current_type"])
	AssertEqual(1, Snapshot["current_score"])
	AssertTrue(KL_AppCat_CommitEdit(Snapshot, "Travail 😀", -1.25))
	Committed := FSReadUtf8Exact(Path)
	BeforeTop := JsonObjectMemberSpans(Original)
	AfterTop := JsonObjectMemberSpans(Committed)
	AssertEqual(BeforeTop["metadata"]["member_text"], AfterTop["metadata"]["member_text"],
		"unknown top-level JSON keeps boolean, null and nested values exactly")
	BeforeRecord := JsonObjectMemberSpans(Original, ["apps", "audit.exe"])
	AfterRecord := JsonObjectMemberSpans(Committed, ["apps", "audit.exe"])
	AssertEqual(BeforeRecord["extra"]["member_text"], AfterRecord["extra"]["member_text"],
		"unknown per-record metadata must not pass through the lossy primitive encoder")
	Projected := KL_AppCat_ProjectAt(Root, ["AUDIT.EXE", "other.exe"])
	AssertEqual(1, Projected.Count, "an unedited legacy label cannot acquire an historical score override")
	AssertEqual("Travail 😀", Projected["AUDIT.EXE"]["type"])
	AssertEqual(-1.25, Projected["AUDIT.EXE"]["score"])
	AssertTrue(KL_AppCat_Reload())
	AssertEqual("Travail 😀", KL_AppCat_Get("audit.exe"))
	AssertEqual("neutral", KL_AppCat_Get("other.exe"))
}

_KLACEC_Full(Receipt, Path) {
	Receipt["full_calls"] += 1
	loop files Path . ".*.tmp", "F" {
		Receipt["stage_seen"] := true
		if Receipt["mode"] == "revoke"
			Receipt["active"] := false
		else if Receipt["mode"] == "discover" && !Receipt["discovered"] {
			Receipt["discovered"] := true
			Receipt["discovery"] := KL_AppCat_Get("during-stage.exe")
		}
	}
	return true
}

_KLACEC_Admission(Receipt) {
	Receipt["admission_calls"] += 1
	if !Receipt["active"]
		Receipt["refused_calls"] += 1
	return Receipt["active"]
}

_KLACEC_Stages(Path) {
	Count := 0
	loop files Path . ".*.tmp", "F"
		Count += 1
	return Count
}

_KLACEC_Staging(Mode, Root, Path, Original) {
	Admitted := KLAppCat.categories
	Model := KLAppCat.store_model
	Receipt := Map("active", true, "mode", Mode, "stage_seen", false, "discovered", false,
		"full_calls", 0, "admission_calls", 0, "refused_calls", 0)
	Snapshot := KL_AppCat_EditorSnapshot("audit.exe", Root)
	Result := KL_AppCat_CommitEdit(Snapshot, "Révision 😀", 0.5,
		_KLACEC_Full.Bind(Receipt, Path), _KLACEC_Admission.Bind(Receipt))
	AssertTrue(Receipt["stage_seen"], "the full check must observe the real already-created native stage")
	AssertTrue(Receipt["admission_calls"] > 0, "the final RAM guard must actually be consulted")
	AssertTrue(KLAppCat.categories == Admitted, "staging cannot replace the live classifier identity")
	AssertTrue(KLAppCat.write_owner is Integer && KLAppCat.write_owner == 0,
		"the exact writer lease must be released for the next operation")
	AssertEqual(0, _KLACEC_Stages(Path), "both publication and refusal must retire the owned stage")
	if Mode == "revoke" {
		AssertEqual(Original, FSReadUtf8Exact(Path), "late page revocation must retain the authoritative file")
		AssertEqual("productive", KL_AppCat_Get("audit.exe"), "late refusal cannot publish the detached label")
		AssertTrue(KLAppCat.store_model == Model && !KLAppCat.dirty)
		AssertTrue(Result is Integer && Result == 0)
		AssertTrue(Receipt["refused_calls"] > 0, "the refusal must come from live admission, not a missing stage")
		Receipt["active"] := true, Receipt["mode"] := "live"
		AssertTrue(KL_AppCat_CommitEdit(Snapshot, "Révision 😀", 0.5,
			_KLACEC_Full.Bind(Receipt, Path), _KLACEC_Admission.Bind(Receipt)),
			"the same retained source may still commit after an independent live attempt")
	} else {
		AssertTrue(Result is Integer && Result == 1)
		AssertEqual("unknown", Receipt["discovery"])
		AssertFalse(JsonParse(FSReadStrict(Path))["apps"].Has("during-stage.exe"),
			"the real staged image predates the reentrant discovery")
		AssertTrue(KLAppCat.categories.Has("during-stage.exe") && KLAppCat.dirty,
			"the new runtime discovery must retain its deferred-save obligation")
		AssertTrue(KL_AppCat_Save(), "a genuine durable retry must preserve the late discovery")
	}
	AssertTrue(KL_AppCat_Reload())
	AssertEqual("Révision 😀", KL_AppCat_Get("audit.exe"))
	if Mode == "discover" {
		AssertTrue(KLAppCat.categories.Has("during-stage.exe"), "the real reload must admit the saved discovery")
		AssertEqual("unknown", KL_AppCat_Get("during-stage.exe"))
	}
}

Test("App category edit contract: unknown schema version refuses untouched (app-category-edit-contract)",
	_KLACEC_With.Bind(_KLACEC_Invalid.Bind("version")))
Test("App category edit contract: JSON boolean cannot impersonate a score (app-category-edit-contract)",
	_KLACEC_With.Bind(_KLACEC_Invalid.Bind("boolean")))
Test("App category edit contract: unknown JSON metadata and legacy semantics survive (app-category-edit-contract)",
	_KLACEC_With.Bind(_KLACEC_Metadata))
Test("App category edit contract: final native admission refuses a retired owner (app-category-edit-contract)",
	_KLACEC_With.Bind(_KLACEC_Staging.Bind("revoke")))
Test("App category edit contract: discovery during staging survives durable retry (app-category-edit-contract)",
	_KLACEC_With.Bind(_KLACEC_Staging.Bind("discover")))
