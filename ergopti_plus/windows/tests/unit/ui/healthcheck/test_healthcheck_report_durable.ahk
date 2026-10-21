; tests/unit/ui/healthcheck/test_healthcheck_report_durable.ahk

; ==============================================================================
; MODULE: Diagnostics Attachment Native Write Tests
; DESCRIPTION:
; Actual byte-range locks, short native writes and flush refusals must stop the
; real report effect chain before Explorer or the browser receives a path.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../../support/filesystem_write_lock.ahk

_HCRD_NativeWrite(State, Mode, Handle, Bytes, Count, &Written) {
	State["writes"] += 1
	State["events"].Push("write")
	if Mode == "write-throw"
		throw OSError(5)
	Result := _FSNativeWrite(Handle, Bytes, Mode == "short" ? Count - 1 : Count, &Written)
	State["written"] := Written
	return Result
}

_HCRD_Flush(State, Mode, File) {
	State["flushes"] += 1
	State["events"].Push("flush")
	if Mode == "flush-throw"
		throw OSError(5)
	return Mode == "flush-false" ? false : FSFlushFileBuffers(File)
}

_HCRD_Durable(State, Mode, Path, Text) {
	OpenFn := Mode == "native-lock" ? ObjBindMethod(State["lock"], "Open") : FileOpen
	return FSWriteDurable(Path, Text, OpenFn, 0, _HCRD_Flush.Bind(State, Mode), _HCRD_NativeWrite.Bind(State, Mode))
}

_HCRD_Save(State, Mode, Dir, Name, Text) {
	State["path"] := Dir . "\" . Name, State["text"] := Text
	State["events"].Push("save")
	return _HCReport_Save(Dir, Name, Text, _HCRD_Durable.Bind(State, Mode))
}

_HCRD_External(State, Kind, Value) {
	State[Kind] += 1
	State["events"].Push(Kind)
	AssertTrue(FileExist(State["path"]) != "", "an external opener receives only a completed attachment")
	AssertEqual(State["text"], FSReadUtf8Exact(State["path"]))
	return true
}

_HCRD_Copy(State, Text) {
	State["copies"] += 1
	State["events"].Push("copy")
	return true
}

_HCRD_RealEffectChain(ActionId, Mode) {
	Root := _FSWL_Path()
	Lock := _FSWL_Lock()
	State := Map("lock", Lock, "events", [], "writes", 0, "written", 0, "flushes", 0,
		"copies", 0, "reveal", 0, "browser", 0)
	try {
		Config := HealthCheck_Config(), Snapshot := _THPA_Snapshot()
		Document := HealthCheck_ShareDocument(Snapshot, Config["schema"])
		Effects := _THPA_Effects([])
		Effects["copy"] := _HCRD_Copy.Bind(State)
		Effects["save"] := _HCRD_Save.Bind(State, Mode)
		Effects["reveal"] := _HCRD_External.Bind(State, "reveal")
		Effects["open_url"] := _HCRD_External.Bind(State, "browser")
		Outcome := HealthCheck_PerformAction(Map("action", ActionId, "text", Document["text"]),
			Map("diagnostics_dir", Root), Config, Effects, Snapshot)
		Lock.Release()
		AssertEqual(Mode == "native-lock", Lock.Acquired, "write denial comes from the real native range lock")
		AssertEqual(Mode == "healthy", Outcome["ok"], "buffer acceptance is not attachment completion")
		AssertEqual(1, State["writes"], "the actual unbuffered native write boundary runs exactly once")
		AssertEqual(ActionId == "report" ? 1 : 0, State["copies"])
		if Mode == "healthy" {
			AssertEqual(State["path"], Outcome["path"])
			AssertEqual(Document["text"], FSReadUtf8Exact(Outcome["path"]))
			AssertEqual(StrPut(Document["text"], "UTF-8") - 1, FileGetSize(Outcome["path"]), "the Markdown has no added BOM or terminator")
			AssertEqual(FileGetSize(Outcome["path"]), State["written"], "the real OS receipt covers the entire UTF-8 image")
			AssertEqual(1, State["flushes"])
			AssertEqual(1, State["reveal"])
			AssertEqual(ActionId == "report" ? 1 : 0, State["browser"])
			AssertEqual(ActionId == "report" ? "copy,save,write,flush,reveal,browser" : "save,write,flush,reveal", _HC_Join(State["events"], ","))
		} else {
			AssertFalse(Outcome.Has("path"), "failure cannot acknowledge an attachment path")
			AssertFalse(FileExist(State["path"]), "the canonical owner removes its incomplete report")
			AssertEqual(0, State["reveal"], "Explorer must not open an incomplete attachment")
			AssertEqual(0, State["browser"], "the bug form must not open after attachment refusal")
			AssertEqual(InStr(Mode, "flush-") == 1 ? 1 : 0, State["flushes"], "only a complete OS write reaches flush")
			if Mode == "short"
				AssertEqual(StrPut(Document["text"], "UTF-8") - 2, State["written"], "the short receipt came from a real prefix write")
		}
	} finally {
		try Lock.Release()
		finally {
			if DirExist(Root)
				DirDelete(Root, true)
		}
	}
}

for _HCRD_Action in ["save", "report"]
	for _HCRD_Mode in ["healthy", "native-lock", "short", "write-throw", "flush-false", "flush-throw"]
		Test("Diagnostics attachment: " . _HCRD_Action . " " . _HCRD_Mode . " requires complete native bytes (healthcheck-report-durable)",
			_HCRD_RealEffectChain.Bind(_HCRD_Action, _HCRD_Mode))

_HCRD_DefaultUnicode() {
	Root := _FSWL_Path(), Text := "étoile😀`nline"
	try {
		Path := _HCReport_Save(Root, "résumé-🦊.md", Text)
		Expected := FSUtf8Bytes(Text), Actual := FSReadBytesStrict(Path)
		AssertEqual(Expected.Size, Actual.Size, "UTF-8-RAW adds neither BOM nor terminator")
		AssertEqual(Expected.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Expected, "Ptr", Actual, "UPtr", Expected.Size, "UPtr"))
		AssertEqual(Text, FSReadUtf8Exact(Path), "the actual default writer preserves Unicode Markdown")
	} finally {
		if DirExist(Root)
			DirDelete(Root, true)
	}
}
Test("Diagnostics attachment: actual default writer preserves complete UTF-8 Markdown (healthcheck-report-durable)", _HCRD_DefaultUnicode)

; This native premise reproduces the old primitive recipe without rewriting
; production or pretending that a newly added argument existed on the old API.
_HCRD_BufferedAcceptanceIsNotPersistence() {
	Path := _FSWL_Path(), Lock := _FSWL_Lock(), File := 0, Text := "étoile😀`nline"
	try {
		File := Lock.Open(Path, "w", "UTF-8-RAW")
		Buffered := File.Write(Text)
		File.Close(), File := 0
		Lock.Release()
		AssertTrue(Lock.Acquired)
		AssertEqual(StrPut(Text, "UTF-8") - 1, Buffered, "the old buffered call can report every byte")
		AssertEqual(0, FileGetSize(Path), "the real locked OS write and discarded Close failure persisted nothing")
	} finally {
		try {
			if IsObject(File)
				File.Close()
		} finally {
			try Lock.Release()
			finally {
				if FileExist(Path)
					FileDelete(Path)
			}
		}
	}
}
Test("Diagnostics attachment: native lock exposes buffered false acceptance (healthcheck-report-durable)", _HCRD_BufferedAcceptanceIsNotPersistence)
