; tests/fixtures/toml_stage_collision.ahk
; Isolated interpreter gives the real writer's first private sequence exactly 1.
#Requires AutoHotkey v2.0
#Warn All, StdOut
#Warn VarUnset, Off
#Warn LocalSameAsGlobal, Off
#Include ../test_framework.ahk
#Include ../../core/logger/engine/logger.ahk
#Include ../../infra/hotpath_profiler.ahk
#Include ../../core/fs/adapters/file_system.ahk
#Include ../../core/text/engine/toml/helpers.ahk

_TBCS_Child() {
	AssertEqual(2, A_Args.Length)
	Mode := A_Args[1], Root := A_Args[2]
	AssertTrue(Mode == "collision" || Mode == "control")
	AssertTrue(DirExist(Root) != "")
	Path := Root . "\config.toml"
	Stage := Path . "." . A_ScriptHwnd . "-1.tmp"
	Source := '[custom]`nvalue = "Initial"`n'
	Sentinel := "Foreign stage owner — untouched bytes"
	AssertEqual(1, FSWriteCreateDurable(Path, Source))
	Before := FSReadBytesStrict(Path)
	if Mode == "collision" {
		AssertEqual(1, FSWriteCreateDurable(Stage, Sentinel))
		; Reaping must not convert a current interpreter's stage into ownership.
		FileSetTime("20200101000000", Stage, "M")
		AssertFalse(FSAtomicTempOwnerIsGone(RegExReplace(Stage, "^.*\\"), "config.toml"))
		AssertEqual(Sentinel, FSReadUtf8Exact(Stage))
	}
	Result := TOML_BatchWrite(Path, [{Section: "custom", Key: "value", Value: "Edited"}])
	StagePresent := FSStrictExists(Stage)
	StageText := StagePresent ? FSReadUtf8Exact(Stage) : "<absent>"
	After := FSReadBytesStrict(Path)
	FileAppend("mode=" . Mode . " result=" . Result . " stage_present=" . StagePresent
		. " source_before=" . Before.Size . " source_after=" . After.Size . "`n", Root . "\receipt.txt", "UTF-8-RAW")
	if Mode == "collision" {
		AssertTrue(StagePresent, "an ordinary config write must not consume another owner's predicted stage")
		AssertEqual(Sentinel, StageText, "the foreign stage must retain its exact contents")
		AssertFalse(Result, "the collision must refuse the complete durable transaction")
		AssertEqual(Before.Size, After.Size, "the durable source must remain unchanged")
		AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Before,
			"Ptr", After, "UPtr", Before.Size, "UPtr"), "all original source bytes must remain authoritative")
	} else {
		AssertTrue(Result, "an uncollided real ordinary write must still acknowledge")
		AssertFalse(StagePresent, "the successful native rename consumes only its owned stage")
		AssertEqual("Edited", TOML_ParseDocument(FSReadUtf8Exact(Path))["custom"]["value"])
	}
}
try {
	_TBCS_Child()
	ExitApp(0)
} catch as Err {
	if A_Args.Length == 2
		try FileAppend("error=" . Err.Message . "`n", A_Args[2] . "\receipt.txt", "UTF-8-RAW")
	ExitApp(1)
}
