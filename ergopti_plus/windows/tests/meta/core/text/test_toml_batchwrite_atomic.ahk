; tests/meta/core/text/test_toml_batchwrite_atomic.ahk

; ==============================================================================
; MODULE: TOML BatchWrite Atomic Meta Test
; DESCRIPTION:
; Protect the held publication chain, exact readback, final native admission and
; structured partial effects. Mutations start from the actual production body.
; ==============================================================================

#Requires AutoHotkey v2.0

_TBA_RequireUnique(Code, Pattern, Message) {
	Position := RegExMatch(Code, Pattern, &Found)
	Assert(Position > 0, Message)
	Assert(RegExMatch(Code, Pattern, , Position + Found.Len) == 0, Message)
	return Found
}
_TBA_HeldCallPattern() {
	return "i)\bPublished\s*:=\s*FSWriteReplaceOwned\s*\(\s*SourcePath\s*,\s*FinalCandidate\s*,\s*Suffix\s*,\s*&StageDetail\s*,"
		. "\s*_TOML_CreateHeldStage\.Bind\s*\(\s*Stage\s*\)\s*,"
		. "\s*_TOML_AdmitHeldStage\.Bind\s*\(\s*Stage\s*,\s*SourcePath\s*,\s*SourcePresent\s*,\s*SourceBytes\s*,\s*FinalCandidate\s*\)\s*,"
		. "\s*FinalAdmission\s*,\s*SourcePresent\s*,\s*&Publication\s*,\s*HeldFlushFn\s*\)"
}
_TBA_AssertPublication(Seg) {
	Assert(Seg != "", "the shared TOML renderer must be nonempty")
	Code := _DriverMaskNonCode(&Seg)
	Move := _TBA_RequireUnique(Code, _TBA_HeldCallPattern(),
		"TOML_BatchWrite must publish once through the held owner with source, admission and effect receipts")
	Assert(RegExMatch(SubStr(Code, 1, Move.Pos - 1), "i)\bPublication\b") == 0,
		"the native effect must not be consumed before publication")
	AssertEqual(0, RegExMatch(Code, "i)\b(FileDelete|FileMove|FileOpen)\s*\("),
		"the renderer must not acquire or retire publication files through unowned pathnames")
	Refusal := _TBA_RequireUnique(Code,
		"i)if\s*!\s*\(\s*\(\s*Published\s+is\s+Integer\s*\)\s*&&\s*Published\s*==\s*1\s*\)\s*\{",
		"the held publication must retain its strict refusal branch")
	Assert(Refusal.Pos > Move.Pos, "the refusal must inspect the completed held-owner receipt")
	Partial := _TBA_RequireUnique(Code,
		"i)\b_TOML_RecordPartialPublication\s*\(\s*Path\s*,\s*Publication\s*\)",
		"the renderer must retain structured incomplete native effects")
	Assert(Partial.Pos > Refusal.Pos)
	_TBA_RequireUnique(Code,
		"i)if\s+Publication\s+is\s+Object\s*&&\s*Publication\.renamed\s*&&\s*!Publication\.durable",
		"ordinary stage refusals must not fabricate a partial rename effect")
	Position := Move.Pos + Move.Len, Diagnostics := 0
	while RegExMatch(Code, "i)\bLoggerError\s*\(\s*[^,]*,\s*[^,]*,\s*Path\s*,\s*StageDetail\s*\)", &Log, Position) {
		RawLog := SubStr(Seg, Log.Pos, Log.Len)
		if InStr(RawLog, "Native publication") && InStr(RawLog, "not fully acknowledged")
				&& InStr(RawLog, "until restart")
			Diagnostics += 1
		Position := Log.Pos + Log.Len
	}
	Assert(Diagnostics == 1, "the actual partial diagnostic must retain incomplete native effects and session recovery")
}
_TBA_OwnedFlush(Code, Raw, Phase) {
	Position := 1, Result := 0
	while RegExMatch(Code, "i)\bFlushed\s*:=\s*Flush\.Call\s*\(\s*StageHandle\s*,\s*\)", &Call, Position) {
		if InStr(SubStr(Raw, Call.Pos, Call.Len), Chr(34) . Phase . Chr(34)) {
			AssertEqual(0, Result, "the owned native flush phase must be unique")
			Result := Call.Pos
		}
		Position := Call.Pos + Call.Len
	}
	Assert(Result > 0, "the actual owned native flush phase must exist: " . Phase)
	return Result
}
_TBA_AssertNativeDelegation() {
	Create := _DriverFuncBody("_TOML_CreateHeldStage")
	CreateCode := _DriverMaskNonCode(&Create)
	_TBA_RequireUnique(CreateCode, "i)\b_FSCreateHeldStage\s*\(\s*Folder\s*,\s*Name\s*,\s*Attributes\s*\)",
		"the renderer must acquire the real exclusive held stage")
	NativeCreate := _DriverFuncBody("_FSCreateHeldStage")
	NativeCreateCode := _DriverMaskNonCode(&NativeCreate)
	Assert(RegExMatch(NativeCreateCode, "i)\bFILE_CREATE\s*:=\s*2\b") > 0)
	NativeWriteFlag := _TBA_RequireUnique(NativeCreateCode,
		"i)\bFILE_WRITE_THROUGH\s*:=\s*(0x[0-9a-f]+|[0-9]+)\b",
		"the actual held stage must declare its native write-through flag")
	AssertEqual(2, Integer(NativeWriteFlag[1]), "the native write-through flag must retain its exact Win32 value")
	Read := _DriverFuncBody("_TOML_ReadHeldStage")
	ReadCode := _DriverMaskNonCode(&Read)
	Rewind := _TBA_RequireUnique(ReadCode, "i)\b_FSRewind\s*\(\s*State\.handle\s*\)", "the actual readback must rewind its retained handle")
	Readback := _TBA_RequireUnique(ReadCode, "i)\b_FSReadUtf8ExactHandle\s*\(\s*State\.handle\s*,\s*0\s*,\s*false\s*\)", "the actual readback must decode the same retained handle")
	Assert(Readback.Pos > Rewind.Pos)
	Before := _DriverFuncBody("_TOML_AdmitHeldStage")
	BeforeCode := _DriverMaskNonCode(&Before)
	Assert(RegExMatch(BeforeCode, "i)\b_TOML_StageMatches\s*\(\s*Path\s*,\s*Candidate\s*,\s*_TOML_ReadHeldStage\.Bind\s*\(\s*State\s*\)\s*\)\s*&&\s*_TOML_WriteSourceMatches\s*\(\s*Path\s*,\s*SourcePresent\s*,\s*SourceBytes\s*\)") > 0,
		"exact retained-stage readback and the original source witness must run before publication")
	Owned := _DriverFuncBody("FSWriteReplaceOwned")
	OwnedCode := _DriverMaskNonCode(&Owned)
	StageFlush := _TBA_OwnedFlush(OwnedCode, Owned, "stage")
	Preflight := _TBA_RequireUnique(OwnedCode, "i)\bBeforePublishFn\.Call\s*\(\s*\)", "the held writer must run the admitted preflight")
	Rename := _TBA_RequireUnique(OwnedCode, "i)\bFSConfigHeldRename\s*\(\s*StageHandle\s*,\s*FolderHandle\s*,\s*Leaf\s*,\s*ReplaceExisting\s*,\s*AdmissionFn\s*\)", "the held writer must retain the final native admission")
	Published := _TBA_RequireUnique(OwnedCode, "i)\bPublication\.renamed\s*:=\s*true", "the real rename effect must issue a structured receipt")
	PublishedFlush := _TBA_OwnedFlush(OwnedCode, Owned, "published")
	Assert(StageFlush < Preflight.Pos && Preflight.Pos < Rename.Pos
		&& Rename.Pos < Published.Pos && Published.Pos < PublishedFlush,
		"stage flush, exact preflight, admitted rename and published flush must remain ordered")
	_TBA_RequireUnique(OwnedCode, "i)\b_FSDiscardHeldStage\s*\(\s*StageHandle\s*\)", "cleanup must target only the retained stage handle")
	Assert(RegExMatch(OwnedCode, "i)\b(FileDelete|FileMove)\s*\(") == 0)
	Native := _DriverFuncBody("FSConfigHeldRename")
	Code := _DriverMaskNonCode(&Native)
	_TBA_RequireUnique(Code, "i)\bRename\s*:=\s*_FSHeldRename\b", "the final configuration owner must capture the actual retained rename")
	Admission := _TBA_RequireUnique(Code, "i)!\s*Accept\.Call\s*\(\s*AdmissionFn\s*\)", "final native admission must precede physical replacement")
	Dispatch := _TBA_RequireUnique(Code, "i)\bRename\.Call\s*\(\s*Stage\s*,\s*Folder\s*,\s*Name\s*,\s*ReplaceExisting\s*\)", "the final owner must invoke that exact native rename")
	Assert(Dispatch.Pos > Admission.Pos)
}
_TBA_BatchWriteIsAtomic() {
	Wrapper := _DriverFuncBody("TOML_BatchWrite")
	Seg := _DriverFuncBody("_TOML_BatchWriteImpl")
	Assert(InStr(Wrapper,
		'_TOML_BatchWriteImpl(Path, Updates, ExactSectionPrefixes, "write", , , false, AdmissionFn)') > 0,
		"the public writer must select the shared renderer's write mode explicitly")
	_TBA_AssertPublication(Seg)
	_TBA_AssertNativeDelegation()
}
Test("toml_helpers: TOML_BatchWrite uses write-through atomic replace "
	. "(toml-write-through-atomic)", _TBA_BatchWriteIsAtomic)

_TBA_SourceMutant(Mode) {
	Seg := _DriverFuncBody("_TOML_BatchWriteImpl")
	Code := _DriverMaskNonCode(&Seg)
	Found := _TBA_RequireUnique(Code, _TBA_HeldCallPattern(), "the actual mutation seam must be unique")
	Call := SubStr(Seg, Found.Pos, Found.Len)
	Expected := "TOML_BatchWrite must publish once through the held owner with source, admission and effect receipts"
	switch Mode {
		case "missing-receipt":
			Mutant := StrReplace(Seg, Call, StrReplace(Call, "&Publication", "Publication"))
		case "duplicate-publication":
			Mutant := StrReplace(Seg, Call, Call . "`n" . Call)
		case "early-error":
			Mutant := StrReplace(Seg, Call, "Premature := Publication`n" . Call)
			Expected := "the native effect must not be consumed before publication"
		case "missing-config-receipt":
			Mutant := StrReplace(Seg, Call, StrReplace(Call, "&StageDetail", "StageDetail"))
		case "missing-native-admission":
			Mutant := StrReplace(Seg, Call, StrReplace(Call, "FinalAdmission, SourcePresent", "0, SourcePresent"))
		case "bypassed-config-native-owner":
			Mutant := StrReplace(Seg, Call, StrReplace(Call, "FSWriteReplaceOwned", "FSWriteDurable"))
		case "missing-diagnostic":
			AssertEqual(1, StrSplit(Seg, "not fully acknowledged").Length - 1)
			Mutant := StrReplace(Seg, "not fully acknowledged", "unknown native status")
			Expected := "the actual partial diagnostic must retain incomplete native effects and session recovery"
	}
	Observed := 0
	try _TBA_AssertPublication(Mutant)
	catch as Err
		Observed := Err
	Assert(Observed is Error, "the actual source oracle must refuse the named mutation")
	AssertEqual("Error", Type(Observed))
	AssertEqual(Expected, Observed.Message, "the source mutation must fail at its intended invariant")
}
for Mode in ["missing-receipt", "duplicate-publication", "early-error", "missing-diagnostic",
	"missing-config-receipt", "missing-native-admission", "bypassed-config-native-owner"]
	Test("toml_helpers: atomic source oracle refuses " . Mode . " (toml-write-through-atomic)",
		_TBA_SourceMutant.Bind(Mode))

_TBA_SourceFormattingControl() {
	Seg := _DriverFuncBody("_TOML_BatchWriteImpl")
	Code := _DriverMaskNonCode(&Seg)
	Found := _TBA_RequireUnique(Code, _TBA_HeldCallPattern(), "the formatting seam must be unique")
	Call := SubStr(Seg, Found.Pos, Found.Len)
	Changed := StrReplace(StrReplace(Call, "FSWriteReplaceOwned(", "FSWRITEREPLACEOWNED( "), ",", " , ")
	Seg := StrReplace(Seg, Call, Changed)
	Seg := "; FSWriteReplaceOwned(Path, FinalCandidate)`n"
		. 'Decoy := "FSWriteReplaceOwned(Path, FinalCandidate)"' . "`n" . Seg
	_TBA_AssertPublication(Seg)
}
Test("toml_helpers: atomic source oracle accepts legal formatting and ignores data (toml-write-through-atomic)",
	_TBA_SourceFormattingControl)
