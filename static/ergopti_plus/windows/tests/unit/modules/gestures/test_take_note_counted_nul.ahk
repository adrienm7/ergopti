; tests/unit/modules/gestures/test_take_note_counted_nul.ahk

; Counted JSON strings cross a real native file-existence witness, while the
; public action uses explicit passive OS/timer ports: no Notepad or input.
class _TNNU_Ops {
	__New() {
		this.Reads := 0
		this.Effects := []
		this.Timers := []
		this.Errors := []
	}
	NowTick() {
		this.Reads += 1
		return 100
	}
	IsSuspended() => false
	Schedule(Callback, Delay) {
		this.Timers.Push(Callback)
		return true
	}
	ReportError(Message) {
		this.Errors.Push(Message)
	}
	FileExists(Path) {
		this.Effects.Push("file-exists")
		return true
	}
	CreateEmptyFile(Path) {
		throw Error("The existing-note control must not create a file.")
	}
	Launch(Path) {
		throw Error("The existing-note control must not launch Notepad.")
	}
	FindWindow(FileName, Admits := 0) {
		this.Effects.Push("find-window")
		return 4242
	}
	Activate(Hwnd) {
		this.Effects.Push("activate")
		return true
	}
	IsActive(Hwnd) {
		this.Effects.Push("is-active")
		return true
	}
	SelectedTab(Hwnd) => ""
	IsExactWindow(Hwnd, FileName) {
		this.Effects.Push("is-exact")
		return true
	}
	Maximize(Hwnd) {
		this.Effects.Push("maximize")
		return true
	}
	SendFinal(Keys) {
		throw Error("An already-open note must not get launch-only final input.")
	}
	WarnTimeout(Pattern, Waited) {
		throw Error("The current fake window must complete before its deadline.")
	}
}
_TNNU_Case(Mode) {
	global _TakeNotePending, _TakeNoteNextId, _TakeNoteGeneration
	Root := A_Temp . "\ergopti_note_nul_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "The native folder witness must be exclusively acquired.")
		Quoted := JsonStringLiteral(Root)
		Counted := JsonParse(SubStr(Quoted, 1, StrLen(Quoted) - 1) . '\u0000ignored"')
		AssertTrue(Counted is String)
		AssertEqual(StrLen(Root) + 8, StrLen(Counted), "JSON must preserve the complete counted string, including its suffix.")
		AssertEqual(0, NumGet(StrPtr(Counted), StrLen(Root) * 2, "UShort"))
		AssertEqual("ignored", SubStr(Counted, StrLen(Root) + 2))
		RawAlias := FileExist(Counted) != ""
		AdapterAlias := _TakeNoteNative.FileExists(Counted)
		AssertTrue(RawAlias, "The real native file primitive must see the independently owned folder prefix.")
		AssertFalse(AdapterAlias, "The note adapter must not authenticate an invalid counted path from its existing prefix.")
		Ops := _TNNU_Ops()
		Owned := Map(), Claimed := false
		PreviousCritical := Critical("On")
		try {
			AssertFalse(A_IsSuspended, "The request fixture requires an admitted lifecycle.")
			AssertEqual(0, _TakeNotePending.Count, "A fixture cannot park a foreign take-note job.")
			SavedPending := _TakeNotePending
			SavedNext := _TakeNoteNextId
			SavedGeneration := _TakeNoteGeneration
			_TakeNotePending := Owned
			Claimed := true
			Valid := Mode == "valid"
			Destination := Valid ? Root : Counted
			Id := TakeNoteRequest(Mode == "nul-dated", Destination, true, Ops)
			_TestPrint("# TAKE_NOTE_NUL mode=" . Mode . " raw_alias=" . RawAlias . " adapter_alias=" . AdapterAlias
				. " original_units=" . StrLen(Destination) . " result=" . Id . " pending=" . Owned.Count
				. " timers=" . Ops.Timers.Length . " reads=" . Ops.Reads . " errors=" . Ops.Errors.Length)
			AssertEqual(0, Ops.Effects.Length, "No file, process, focus or input port may run before the deferred callback.")
			if !Valid {
				AssertEqual(0, Id, "A counted-NUL folder must be refused by the public action before a job is admitted.")
				AssertEqual(0, Owned.Count)
				AssertEqual(0, Ops.Timers.Length)
				AssertEqual(0, Ops.Reads, "Invalid input must not enter clock/job acquisition.")
				AssertEqual(SavedNext, _TakeNoteNextId)
				AssertEqual(1, Ops.Errors.Length, "The refusal must produce exactly one diagnostic.")
			} else {
				AssertTrue(Id > 0 && Owned.Has(Id))
				AssertEqual(Root . "\Notes.txt", Owned[Id]["file_path"])
				AssertEqual(1, Ops.Timers.Length)
				Callback := Ops.Timers.RemoveAt(1)
				Callback.Call()
				AssertEqual(0, Owned.Count, "The valid existing-note transaction must complete through its genuine deferred state machine.")
				AssertEqual(0, Ops.Errors.Length)
				AssertEqual("maximize", Ops.Effects[Ops.Effects.Length - 2], "The unchanged existing-note path must still maximize its exact target.")
			}
		} finally {
			Ops.Timers := []
			if Claimed && _TakeNotePending == Owned {
				Owned.Clear()
				_TakeNotePending := SavedPending
				_TakeNoteNextId := SavedNext
				_TakeNoteGeneration := SavedGeneration
			}
			Critical(PreviousCritical)
		}
	} finally {
		if Created
			DirDelete(Root)
	}
}
for _TNNU_Mode in ["valid", "nul-undated", "nul-dated"]
	Test("TakeNote counted destination: " . _TNNU_Mode . " preserves public admission (take-note-counted-nul)", _TNNU_Case.Bind(_TNNU_Mode))
