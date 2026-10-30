; tests/unit/adapters/test_file_system_ports.ahk

; ==============================================================================
; MODULE: FileSystem Port Spec (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/file_system/port_vectors.json through the Windows
; reader, as _shared/lua/test/file_system_ports_contract.lua does on macOS and
; Linux, then exercises the real owner's classified read and publication on real
; files under the temporary directory.
; ==============================================================================

#Requires AutoHotkey v2.0

_TFSP_Corpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\file_system\port_vectors.json", "UTF-8"))
}

_TFSP_Nothing(*) {
	return true
}

; The owner a vector describes: every required method, then its changes.
_TFSP_Owner(Corpus, Vector) {
	Owner := Map()
	for Method in Corpus["required"]
		Owner[Method] := _TFSP_Nothing
	for Name in Vector.Get("with_capabilities", [])
		for Method in Corpus["capabilities"][Name]
			Owner[Method] := _TFSP_Nothing
	for Method in Vector.Get("extra", [])
		Owner[Method] := _TFSP_Nothing
	for Method in Vector.Get("without", [])
		Owner.Delete(Method)
	for Method in Vector.Get("non_functions", [])
		Owner[Method] := "not a function"
	return Owner
}

_TFSP_AssertSame(Expected, Actual, What) {
	AssertEqual(Expected.Length, Actual.Length, What . ": length")
	for Index, Item in Expected
		AssertEqual(Item, Actual[Index], What . ": entry " . Index)
}

_TFSP_Vectors() {
	Corpus := _TFSP_Corpus()
	Assert(Corpus["vectors"].Length >= 8, "the corpus holds its vectors")
	for Vector in Corpus["vectors"] {
		Owner := _TFSP_Owner(Corpus, Vector)
		Expect := Vector["expect"]
		if Expect.Has("offered") {
			_TFSP_AssertSame(Expect["offered"], FSPortsCheckOwner(Owner), Vector["id"])
			continue
		}
		Message := ""
		try FSPortsCheckOwner(Owner)
		catch as Err
			Message := Err.Message
		AssertContains(Message, Expect["error"], Vector["id"])
	}
}
Test("file system ports: the shared vectors (file-system-ports)", _TFSP_Vectors)

_TFSP_SpecMatchesTheCorpus() {
	Corpus := _TFSP_Corpus()
	AssertEqual(Corpus["required"].Length, FILE_SYSTEM_PORT_CONTRACT.Length, "required method count")
	Required := Map()
	for Method in Corpus["required"]
		Required[Method] := true
	for Method in FILE_SYSTEM_PORT_CONTRACT
		Assert(Required.Has(Method), "the generated contract names " . Method)
	for Name, Methods in Corpus["capabilities"]
		AssertEqual(Methods.Length, FILE_SYSTEM_PORT_CAPABILITIES[Name].Length, Name)
}
Test("file system ports: the generated table is the corpus' (file-system-ports)", _TFSP_SpecMatchesTheCorpus)

_TFSP_RealOwner() {
	Corpus := _TFSP_Corpus()
	_TFSP_AssertSame(Corpus["drivers"]["windows"], FSPortsCheckOwner(FILE_SYSTEM_OWNER), "the Windows capabilities")
	Ports := FSConfigurationPorts()
	Assert(Ports["owner"] == FILE_SYSTEM_OWNER, "the owner's identity")
	Assert(Ports["reader"] == FSReadWithStatus && Ports["writer"] == FSWriteIfUnchanged
		&& Ports["publisher"] == FSWriteIfUnchangedAdmitted && Ports["delete"] == FSDelete, "the method identities")
	AssertEqual(5, ADAPTER_FILE_SYSTEM.Count, "the portable port stays five methods")
	Body := _DriverFileSource("file_system.ahk")
	Assert(RegExMatch(Body, "m)^FSPortsCheckOwner\(FILE_SYSTEM_OWNER\)\s*\z") > 0,
		"the owner checks itself as the last root statement of its file")
}
Test("file system ports: the real owner satisfies the spec at load (file-system-ports)", _TFSP_RealOwner)





; ======================================
; ======================================
; ======= The real publication =========
; ======================================
; ======================================

_TFSP_InTemp(Scenario) {
	Dir := A_Temp . "\ergopti_fsports_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount
	DirCreate(Dir)
	try
		Scenario.Call(Dir . "\target.toml")
	finally
		DirDelete(Dir, true)
}

_TFSP_NoStage(Path) {
	SplitPath(Path, , &Dir)
	Count := 0
	Loop Files, Dir . "\*.tmp"
		Count += 1
	AssertEqual(0, Count, "no publication stage is left behind")
}

_TFSP_ClassifiedRead(Path) {
	AssertEqual(FS_STATUS_ABSENT, FSReadWithStatus(Path)["status"], "a missing file is absent, not an error")
	Marked := Chr(0xFEFF) . "a = 1"
	FSWrite(Path, Marked)
	Read := FSReadWithStatus(Path)
	AssertEqual(FS_STATUS_OK, Read["status"], "an existing file")
	AssertEqual(Marked, Read["content"], "the exact bytes, its byte-order mark included")
	Reported := []
	Unreadable := FSReadWithStatus(Path . "\not\a\dir", (Category) => Reported.Push(Category))
	Assert(Unreadable["status"] == FS_STATUS_ABSENT || Unreadable["status"] == FS_STATUS_ERROR, "a path under a file")
	Refused := FSReadWithStatus("", (Category) => Reported.Push(Category))
	AssertEqual(FS_STATUS_ERROR, Refused["status"], "an inadmissible path is unreadable, not absent")
	Assert(Reported.Length >= 1, "the failure category is reported")
}
Test("file system ports: the classified read tells absent from unreadable (file-system-ports)",
	() => _TFSP_InTemp(_TFSP_ClassifiedRead))

_TFSP_Publication(Path) {
	Absent := Map("status", FS_STATUS_ABSENT)
	Created := FSWriteIfUnchanged(Path, "one", Absent)
	Assert(Created["committed"], "an absent source is created")
	AssertEqual("one", FSRead(Path), "the created bytes")
	Stale := FSWriteIfUnchanged(Path, "two", Absent)
	AssertFalse(Stale["committed"], "a file that must not exist refuses the creation")
	AssertEqual("one", FSRead(Path), "the refused publication changed nothing")
	Source := FSReadWithStatus(Path)
	Replaced := FSWriteIfUnchanged(Path, "two", Source)
	Assert(Replaced["committed"], "an unchanged source is replaced")
	AssertEqual("two", FSRead(Path), "the replaced bytes")
	Reported := []
	Changed := FSWriteIfUnchanged(Path, "three", Source, (Category) => Reported.Push(Category))
	AssertFalse(Changed["committed"], "a source that changed is refused")
	AssertEqual("two", FSRead(Path), "the source that changed is kept")
	AssertEqual(1, Reported.Length, "the refusal reports its category")
	AssertFalse(FSWriteIfUnchanged(Path, "x", Map())["committed"], "a precondition without status is refused")
	_TFSP_NoStage(Path)
}
Test("file system ports: a publication is refused when the source changed (file-system-ports)",
	() => _TFSP_InTemp(_TFSP_Publication))

_TFSP_Admission(Path) {
	Absent := Map("status", FS_STATUS_ABSENT)
	AssertFalse(FSWriteIfUnchangedAdmitted(Path, "x", Absent, 0, 0)["committed"], "the admission is required")
	AssertFalse(FSWriteIfUnchangedAdmitted(Path, "x", Absent, 0, () => 0)["committed"], "a refused admission stops the commit")
	AssertEqual(FS_STATUS_ABSENT, FSReadWithStatus(Path)["status"], "nothing was published")
	_TFSP_NoStage(Path)
	Assert(FSWriteIfUnchangedAdmitted(Path, "x", Absent, 0, () => 1)["committed"], "an admitted publication commits")
	AssertEqual("x", FSRead(Path), "the admitted bytes")
}
Test("file system ports: the final admission gates the commit (file-system-ports)",
	() => _TFSP_InTemp(_TFSP_Admission))
