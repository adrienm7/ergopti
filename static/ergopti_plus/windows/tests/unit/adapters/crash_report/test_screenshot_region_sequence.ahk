; tests/unit/adapters/crash_report/test_screenshot_region_sequence.ahk

; ==============================================================================
; MODULE: Native Region Screenshot Clipboard Custody Tests
; DESCRIPTION:
; Receives the actual registered PowerShell worker with real clipboard images.
; Controlled copies and native delayed rendering exercise custody without any
; screen capture, keyboard injection or live screenshot selection.
; ==============================================================================

#Requires AutoHotkey v2.0

_GSQ_WriteBitmap(Path, Red, Blue) {
	Bytes := Buffer(58, 0)
	NumPut("UShort", 0x4D42, Bytes, 0)
	NumPut("UInt", 58, Bytes, 2)
	NumPut("UInt", 54, Bytes, 10)
	NumPut("UInt", 40, Bytes, 14)
	NumPut("Int", 1, "Int", 1, Bytes, 18)
	NumPut("UShort", 1, "UShort", 24, Bytes, 26)
	NumPut("UInt", 4, Bytes, 34)
	NumPut("UChar", Blue, "UChar", 0, "UChar", Red, Bytes, 54)
	File := FileOpen(Path, "w")
	try AssertEqual(58, File.RawWrite(Bytes), "the owned bitmap fixture must be complete")
	finally File.Close()
}

_GSQ_Done(State, Code, Output, ErrorText) {
	State.Code := Code
	State.Output := Output
	State.ErrorText := ErrorText
	State.Calls += 1
}

_GSQ_ReplaceOnce(Text, Needle, Replacement) {
	Result := StrReplace(Text, Needle, Replacement, true, &Count)
	AssertEqual(1, Count, "the native scheduling boundary must exist exactly once")
	return Result
}

; WM_RENDERFORMAT must publish without reopening the clipboard held by its
; requester. The clipboard owns the bitmap after a successful SetClipboardData.
_GSQ_Render(Owner, Format, LParam, Msg, Hwnd) {
	if Hwnd != Owner.Hwnd || Format != 2
		return
	Owner.Calls += 1
	Bitmap := DllCall("LoadImageW", "Ptr", 0, "WStr", Owner.Path, "UInt", 0,
		"Int", 0, "Int", 0, "UInt", 0x10, "Ptr")
	if !Bitmap {
		Owner.ErrorText := "The delayed fixture bitmap could not be loaded."
		return 0
	}
	if !DllCall("SetClipboardData", "UInt", 2, "Ptr", Bitmap, "Ptr") {
		Owner.ErrorText := "The delayed clipboard format could not be rendered."
		DllCall("Gdi32\DeleteObject", "Ptr", Bitmap)
		return 0
	}
	Owner.Sequence := CB_GetSequenceNumber()
	return 0
}

_GSQ_Receive(Mode) {
	global _GestureRegionCapture, _GSWO_Handles
	Stem := A_Temp . "\ergopti_region_sequence_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	RedPath := Stem . "_red.bmp", BluePath := Stem . "_blue.bmp"
	ReadyPath := Stem . "_ready", AckPath := Stem . "_ack"
	Old := _GSWO_Install()
	Token := 0, Snapshot := "", OwnedSequence := 0, Handle := 0, Stage := ""
	OwnerGui := 0, RenderFn := 0, Renderer := 0
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	Primary := 0, LockObserved := false, LockProbed := false
	PreviousCritical := Critical("Off")
	try {
		Token := CB_TryBeginOwnedTransaction("test_region_image_sequence")
		AssertTrue(Token != 0, "the native clipboard fixture must own its transaction")
		Snapshot := CB_SaveAll()
		AssertFalse(Snapshot is String && Snapshot == "__CB_SAVE_ERROR__", "the original clipboard must be retained")
		_GSQ_WriteBitmap(RedPath, 255, 0)
		_GSQ_WriteBitmap(BluePath, 0, 255)
		if Mode == "delayed" {
			OwnerGui := Gui("+ToolWindow -Caption")
			Renderer := {Hwnd: OwnerGui.Hwnd, Path: RedPath, Calls: 0, Sequence: 0, ErrorText: ""}
			RenderFn := _GSQ_Render.Bind(Renderer)
			OnMessage(0x305, RenderFn)
			AssertTrue(DllCall("OpenClipboard", "Ptr", OwnerGui.Hwnd, "Int"))
			try {
				AssertTrue(DllCall("EmptyClipboard", "Int"))
				DllCall("SetClipboardData", "UInt", 2, "Ptr", 0, "Ptr")
				AssertTrue(DllCall("IsClipboardFormatAvailable", "UInt", 2, "Int"),
					"the native owner must declare its delayed bitmap")
			} finally AssertTrue(DllCall("CloseClipboard", "Int"))
			AssertEqual(OwnerGui.Hwnd, DllCall("GetClipboardOwner", "Ptr"), "the fixture must retain its delayed source")
			OwnedSequence := CB_GetSequenceNumber()
		} else {
			AssertTrue(CB_WriteBitmapFile(RedPath), "the selected red bitmap must reach the native clipboard")
			OwnedSequence := CB_GetSequenceNumber()
		}
		AssertTrue(OwnedSequence > 0)
		ExpectedSequence := OwnedSequence
		_GSWO_SeedRegion()
		_GestureRegionCapture["clipboard_sequence"] := Mode == "unknown" ? 0 : ExpectedSequence
		AssertTrue(GestureRegionCaptureStartSaveWorker(1), "the actual region registrar must construct its worker")
		Job := _GSWO_JobByOwner("region_save", 1)
		Stage := Job["stage"]
		AssertFalse(FileExist(Stage), "the worker must use a fresh owned stage")
		Args := _GSWO_Handles[1]["args"].Clone()
		Script := Args[Args.Length]
		if Mode == "before" {
			AssertTrue(CB_WriteBitmapFile(BluePath))
			OwnedSequence := CB_GetSequenceNumber()
			AssertTrue(OwnedSequence != ExpectedSequence, "the hostile copy must have a distinct sequence")
		} else if Mode == "locked" {
			ReadyLiteral := StrReplace(ReadyPath, "'", "''")
			AckLiteral := StrReplace(AckPath, "'", "''")
			Pause := "[System.IO.File]::WriteAllText('" . ReadyLiteral . "','locked');"
				. "$until=[DateTime]::UtcNow.AddSeconds(10);"
				. "while(-not [System.IO.File]::Exists('" . AckLiteral . "')){if([DateTime]::UtcNow -gt $until){throw 'Native lock observation timed out.'};Start-Sleep -Milliseconds 10};"
			Needle := "$bitmapHandle = [ErgoptiScreenshotClipboard]::GetClipboardData(2);"
			Script := _GSQ_ReplaceOnce(Script, Needle, Pause . Needle)
		} else if Mode == "after" {
			BlueLiteral := StrReplace(BluePath, "'", "''")
			CopyBlue := "$replacement=[System.Drawing.Image]::FromFile('" . BlueLiteral . "');"
				. "try {[System.Windows.Forms.Clipboard]::SetImage($replacement)}finally{$replacement.Dispose()};"
				. "Write-Output ('OWNED_SEQUENCE='+[ErgoptiRegionFixtureClipboard]::GetClipboardSequenceNumber());"
			Script := _GSQ_ReplaceOnce(Script, "$img.Save(", CopyBlue . "$img.Save(")
		}
		StageLiteral := StrReplace(Stage, "'", "''")
		Script .= ";$received=[System.Drawing.Image]::FromFile('" . StageLiteral . "');"
			. "try{Write-Output ('PIXEL='+$received.GetPixel(0,0).R+','+$received.GetPixel(0,0).G+','+$received.GetPixel(0,0).B)}finally{$received.Dispose()}"
		FixtureType := "$ProgressPreference = 'SilentlyContinue';Add-Type -TypeDefinition 'public static class ErgoptiRegionFixtureClipboard {"
			. '[System.Runtime.InteropServices.DllImport("user32.dll")]public static extern uint GetClipboardSequenceNumber();}' . "' -ErrorAction Stop;"
		Args[Args.Length] := FixtureType . Script
		PowerShell := A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe"
		Handle := ShellRunner_SpawnTreeOwned(PowerShell, Args, _GSQ_Done.Bind(State))
		AssertTrue(Handle.start(), "the actual native worker must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 20000 {
			if Mode == "locked" && !LockProbed && FileExist(ReadyPath) {
				LockProbed := true
				Opened := DllCall("OpenClipboard", "Ptr", A_ScriptHwnd, "Int")
				LockObserved := !Opened
				if Opened
					DllCall("CloseClipboard", "Int")
				AssertTrue(FSWriteCreateDurable(AckPath, "continue") != 0)
			}
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "the exact worker must settle once")
		if Mode == "after" {
			AssertTrue(RegExMatch(State.Output, "m)^OWNED_SEQUENCE=(\d+)\r?$", &Receipt),
				"the controlled native copy must report its own sequence")
			OwnedSequence := Integer(Receipt[1])
		}
		if Mode == "before" || Mode == "unknown" {
			AssertTrue(State.Code != 0, "the worker must refuse lost clipboard custody: " . State.Output . State.ErrorText)
			AssertTrue(InStr(State.ErrorText, "clipboard content changed") > 0)
			AssertFalse(FileExist(Stage), "refused custody must never create a staged image")
		} else {
			AssertEqual(0, State.Code, State.ErrorText)
			AssertEqual("", State.ErrorText)
			AssertTrue(FileExist(Stage), "an admitted image must be saved")
			AssertTrue(InStr(State.Output, "PIXEL=255,0,0") > 0, "the stage must contain the selected red pixel")
			if Mode == "locked"
				AssertTrue(LockProbed && LockObserved, "another process cannot replace the bitmap during acquisition")
			if Mode == "delayed" {
				AssertEqual(1, Renderer.Calls, "the native delayed renderer must answer once")
				AssertEqual("", Renderer.ErrorText)
				AssertTrue(Renderer.Sequence != ExpectedSequence,
					"legitimate materialization must really change the clipboard sequence")
			}
		}
	} catch as Err {
		Primary := Err
	} finally {
		try {
			if IsObject(Handle)
				AssertEqual(1, Handle.terminate(), "the exact native child must retire before fixture cleanup")
			if RegExMatch(State.Output, "m)^OWNED_SEQUENCE=(\d+)\r?$", &FinalReceipt)
				OwnedSequence := Integer(FinalReceipt[1])
			if IsObject(Renderer) && Renderer.Sequence
				OwnedSequence := Renderer.Sequence
			if Token {
				if OwnedSequence {
					CB_RestoreOwnedAllEventually(Snapshot, OwnedSequence, Token, "test_region_image_sequence", true)
					RestoreStarted := A_TickCount
					while CB_HasRestoreDebtForOwner(Token) && TickElapsed(RestoreStarted) < 5000 {
						CB_RetryRestoreDebt()
						Sleep(10)
					}
					AssertFalse(CB_HasRestoreDebtForOwner(Token), "the native fixture must settle its restore debt")
				} else
					CB_EndOwnedTransaction(Token)
			}
			for Path in [RedPath, BluePath, ReadyPath, AckPath, Stage]
				if Path != "" && FileExist(Path)
					FileDelete(Path)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		} finally {
			try {
				if IsObject(RenderFn)
					OnMessage(0x305, RenderFn, 0)
				if IsObject(OwnerGui)
					OwnerGui.Destroy()
			} catch as Err {
				if !IsObject(Primary)
					Primary := Err
			} finally {
				_GSWO_Restore(Old)
				Critical(PreviousCritical)
			}
		}
	}
	if IsObject(Primary)
		throw Primary
}

for _GSQ_Mode in ["current", "before", "locked", "after", "unknown", "delayed"]
	Test("region image custody: native " . _GSQ_Mode . " copy (region-image-sequence)", _GSQ_Receive.Bind(_GSQ_Mode))
