; tests/unit/modules/keystats/test_keystats_app_category_stage_retry.ahk

; ==============================================================================
; MODULE: App Category Native Stage Retry Regression
; DESCRIPTION:
; A real delete-denying handle strands a stage after revoked publication.
; Reusing the retained writer is deterministic and makes no allocator claim.
; ==============================================================================

_KLACSR_Current(Receipt, Path) {
	loop files Path . ".*.tmp", "F" {
		if Receipt["phase"] == "strand" && Receipt["stage"] == "" {
			Receipt["stage"] := A_LoopFileFullPath
			Receipt["lock"] := FileOpen(A_LoopFileFullPath, "r-wd")
			AssertTrue(IsObject(Receipt["lock"]), "the actual stage must acquire a native delete-denying handle")
			Receipt["active"] := false
		} else if Receipt["phase"] == "retry" && A_LoopFileFullPath != Receipt["stage"]
			Receipt["next_stage"] := A_LoopFileFullPath
	}
	return true
}

_KLACSR_Admission(Receipt) {
	return Receipt["active"]
}

_KLACSR_Case() {
	static Serial := 0
	PreviousCritical := Critical("On")
	Saved := Map()
	Properties := ["categories", "file_path", "dirty", "save_fn", "write_owner", "store_model"]
	for Key in Properties
		if KLAppCat.HasOwnProp(Key)
			Saved[Key] := KLAppCat.%Key%
	Root := A_Temp . "\ergopti_appcat_stage_retry_" . A_ScriptHwnd . "_" . ++Serial
	Path := Root . "\" . KLAppCatConst.FILE_NAME
	Timer := (*) => 0
	Owner := 0, Owned := false, Primary := 0, CleanupError := 0
	Receipt := Map("phase", "strand", "stage", "", "next_stage", "", "lock", 0, "active", true)
	try {
		AssertTrue(Saved.Get("write_owner", 0) is Integer && Saved.Get("write_owner", 0) == 0,
			"the fixture cannot replace a foreign category writer")
		FSCreateDirectoryExclusiveStrict(Root), Owned := true
		Original := '{"audit.exe":"productive","other.exe":"neutral"}' . "`n"
		Candidate := '{"audit.exe":"Révision 😀","other.exe":"neutral"}' . "`n"
		AssertTrue(FSWriteCreateDurable(Path, Original))
		KLAppCat.categories := Map(), KLAppCat.file_path := "", KLAppCat.dirty := false
		KLAppCat.save_fn := Timer, KLAppCat.write_owner := 0, KLAppCat.store_model := 0
		AssertTrue(KL_AppCat_Init(Root))
		Admitted := KLAppCat.categories, Model := KLAppCat.store_model
		Source := _KL_AppCat_ReadImage(Path)
		Owner := _KL_AppCat_AcquireWrite()
		AssertTrue(Owner is Map, "the real owner must authorize both deterministic native attempts")
		CleanupFailure := 0
		try _KL_AppCat_WriteOwned(Owner, Candidate, Source,
			_KLACSR_Current.Bind(Receipt, Path), _KLACSR_Admission.Bind(Receipt))
		catch as Failure {
			CleanupFailure := Failure
		}
		AssertTrue(Receipt["stage"] != "" && IsObject(Receipt["lock"]),
			"the first attempt must create and lock a real stage before revocation")
		AssertTrue(CleanupFailure is OSError, "the real cleanup must report the OS deletion refusal")
		AssertTrue(FSStrictExists(Receipt["stage"]))
		AssertEqual(Candidate, FSReadUtf8Exact(Receipt["stage"]))
		AssertEqual(Original, FSReadUtf8Exact(Path), "the refused first attempt cannot replace the authoritative file")
		AssertTrue(KLAppCat.categories == Admitted && KLAppCat.store_model == Model && !KLAppCat.dirty)
		Receipt["lock"].Close(), Receipt["lock"] := 0
		Receipt["active"] := true, Receipt["phase"] := "retry"
		Result := _KL_AppCat_WriteOwned(Owner, Candidate, Source,
			_KLACSR_Current.Bind(Receipt, Path), _KLACSR_Admission.Bind(Receipt))
		AssertEqual(Candidate, FSReadUtf8Exact(Path),
			"a retained writer must publish a fresh stage after the original lock is released")
		AssertTrue(Result is Integer && Result == 1)
		AssertTrue(Receipt["next_stage"] != "" && Receipt["next_stage"] != Receipt["stage"],
			"the retry must independently own another native stage rather than adopting debris")
		AssertFalse(FSStrictExists(Receipt["next_stage"]), "the admitted second stage must be consumed by native rename")
		AssertTrue(FSStrictExists(Receipt["stage"]), "retry cannot claim or delete the first failed stage")
		AssertEqual(Candidate, FSReadUtf8Exact(Receipt["stage"]))
		AssertTrue(KLAppCat.write_owner == Owner && KLAppCat.categories == Admitted,
			"the low-level writer cannot steal its lease or publish classifier state")
		_KL_AppCat_ReleaseWrite(Owner), Owner := 0
		AssertTrue(KL_AppCat_Reload(), "the ordinary public reload must admit the durable retry")
		AssertEqual("Révision 😀", KL_AppCat_Get("audit.exe"))
		AssertEqual("neutral", KL_AppCat_Get("other.exe"))
		AssertTrue(KLAppCat.write_owner is Integer && KLAppCat.write_owner == 0)
	} catch as Failure {
		Primary := Failure
	} finally {
		if IsObject(Receipt["lock"]) {
			try Receipt["lock"].Close()
			catch as Failure {
				CleanupError := Failure
			}
		}
		if IsObject(Owner)
			_KL_AppCat_ReleaseWrite(Owner)
		try SetTimer(Timer, 0)
		catch as Failure {
			if !IsObject(CleanupError)
				CleanupError := Failure
		} finally {
			for Key in Properties {
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

Test("App category stage retry: a stranded native stage cannot monopolize the next attempt (app-category-stage-retry)",
	_KLACSR_Case)
