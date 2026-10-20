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

; The immediate image must exercise the DIB section produced by the real
; clipboard adapter, which the cross-process GDI+ reader used to reject.
_GSQ_RequireDibSection() {
	AssertTrue(DllCall("OpenClipboard", "Ptr", A_ScriptHwnd, "Int"))
	try {
		Bitmap := DllCall("GetClipboardData", "UInt", 2, "Ptr")
		AssertTrue(Bitmap != 0, "the real immediate clipboard bitmap must exist")
		Info := Buffer(A_PtrSize == 8 ? 32 : 24, 0)
		AssertEqual(Info.Size, DllCall("Gdi32\GetObjectW", "Ptr", Bitmap,
			"Int", Info.Size, "Ptr", Info, "Int"), "the native BITMAP must be observable")
		AssertTrue(NumGet(Info, A_PtrSize == 8 ? 24 : 20, "Ptr") != 0,
			"the immediate source must be a DIB section, not only the passing delayed DDB control")
	} finally AssertTrue(DllCall("CloseClipboard", "Int"))
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

/** Observes the borrowed native bitmap under the existing worker lock. */
_GSQ_BitmapDiagnostics() {
	return "Add-Type -TypeDefinition '"
		. 'using System;using System.Runtime.InteropServices;'
		. 'public static class ErgoptiRegionBitmapDiagnostic {'
		. '[DllImport("gdi32.dll",SetLastError=true)]static extern uint GetObjectType(IntPtr image);'
		. '[DllImport("gdi32.dll",EntryPoint="GetObjectW",SetLastError=true)]static extern int GetObjectW(IntPtr image,int size,IntPtr data);'
		. '[DllImport("kernel32.dll")]static extern uint GetLastError();'
		. '[DllImport("kernel32.dll",EntryPoint="SetLastError")]static extern void ClearLastError(uint code);'
		. '[DllImport("user32.dll")]static extern IntPtr GetClipboardOwner();'
		. '[DllImport("user32.dll")]static extern bool IsClipboardFormatAvailable(uint format);'
		. '[DllImport("user32.dll",SetLastError=true)]static extern IntPtr CopyImage(IntPtr image,uint type,int width,int height,uint flags);'
		. '[DllImport("gdi32.dll",SetLastError=true)]static extern bool DeleteObject(IntPtr image);'
		. '[DllImport("user32.dll",SetLastError=true)]static extern IntPtr GetDC(IntPtr window);'
		. '[DllImport("user32.dll",SetLastError=true)]static extern int ReleaseDC(IntPtr window,IntPtr dc);'
		. '[DllImport("gdi32.dll",SetLastError=true)]static extern int GetDIBits(IntPtr dc,IntPtr image,uint start,uint count,IntPtr pixels,IntPtr info,uint usage);'
		. 'static string LastError(){int managed=Marshal.GetLastWin32Error();uint native=GetLastError();return managed+" native_error="+native;}'
		. 'public static void Observe(IntPtr bitmap){'
		. 'Console.WriteLine("REGION_BITMAP_OWNER handle="+bitmap.ToInt64()+" owner="+GetClipboardOwner().ToInt64()+" cf_dib="+IsClipboardFormatAvailable(8)+" cf_dibv5="+IsClipboardFormatAvailable(17));'
		. 'ClearLastError(0);uint type=GetObjectType(bitmap);string typeError=LastError();'
		. 'Console.WriteLine("REGION_BITMAP_TYPE result="+type+" last_error="+typeError);'
		. 'int size=IntPtr.Size==8?104:84;IntPtr info=Marshal.AllocHGlobal(size);'
		. 'try{Marshal.Copy(new byte[size],0,info,size);ClearLastError(0);int received=GetObjectW(bitmap,size,info);string error=LastError();'
		. 'byte[] bytes=new byte[size];Marshal.Copy(info,bytes,0,size);'
		. 'Console.WriteLine("REGION_BITMAP_OBJECT result="+received+" last_error="+error+" bytes="+BitConverter.ToString(bytes));'
		. 'foreach(uint flags in new uint[]{0,8192}){ClearLastError(0);IntPtr copy=CopyImage(bitmap,0,0,0,flags);string copyError=LastError();'
		. 'Console.WriteLine("REGION_BITMAP_COPY flags="+flags+" handle="+copy.ToInt64()+" last_error="+copyError+" borrowed="+(copy==bitmap));'
		. 'if(copy!=IntPtr.Zero&&copy!=bitmap){ClearLastError(0);bool deleted=DeleteObject(copy);string deleteError=LastError();'
		. 'Console.WriteLine("REGION_BITMAP_DELETE flags="+flags+" result="+deleted+" last_error="+deleteError);}}'
		. 'if(received>=24&&Marshal.ReadInt32(info,4)==1&&Marshal.ReadInt32(info,8)==1){ObservePixel(bitmap);}'
		. 'else{Console.WriteLine("REGION_BITMAP_PIXEL skipped=not_one_pixel_bitmap");}'
		. '}finally{Marshal.FreeHGlobal(info);}}'
		. 'static void ObservePixel(IntPtr bitmap){ClearLastError(0);IntPtr dc=GetDC(IntPtr.Zero);string dcError=LastError();'
		. 'Console.WriteLine("REGION_BITMAP_DC handle="+dc.ToInt64()+" last_error="+dcError);if(dc==IntPtr.Zero){return;}'
		. 'IntPtr header=IntPtr.Zero,pixels=IntPtr.Zero;'
		. 'try{header=Marshal.AllocHGlobal(40);pixels=Marshal.AllocHGlobal(4);Marshal.Copy(new byte[40],0,header,40);Marshal.WriteInt32(pixels,0);'
		. 'Marshal.WriteInt32(header,0,40);Marshal.WriteInt32(header,4,1);Marshal.WriteInt32(header,8,1);Marshal.WriteInt16(header,12,1);Marshal.WriteInt16(header,14,32);Marshal.WriteInt32(header,20,4);'
		. 'ClearLastError(0);int lines=GetDIBits(dc,bitmap,0,1,pixels,header,0);string error=LastError();byte[] pixel=new byte[4];Marshal.Copy(pixels,pixel,0,4);'
		. 'Console.WriteLine("REGION_BITMAP_PIXEL result="+lines+" last_error="+error+" bgra="+BitConverter.ToString(pixel));'
		. '}finally{if(header!=IntPtr.Zero){Marshal.FreeHGlobal(header);}if(pixels!=IntPtr.Zero){Marshal.FreeHGlobal(pixels);}ClearLastError(0);int released=ReleaseDC(IntPtr.Zero,dc);string releaseError=LastError();'
		. 'Console.WriteLine("REGION_BITMAP_DC_RELEASE result="+released+" last_error="+releaseError);}}}'
		. "' -ErrorAction Stop;"
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
			_GSQ_RequireDibSection()
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
		; Observe only after the real acquisition, while its original lock is held.
		Acquire := "$bitmapHandle = [ErgoptiScreenshotClipboard]::GetClipboardData(2);"
		Script := _GSQ_ReplaceOnce(Script, Acquire,
			Acquire . "[ErgoptiRegionBitmapDiagnostic]::Observe($bitmapHandle);")
		StageLiteral := StrReplace(Stage, "'", "''")
		Script .= ";$received=[System.Drawing.Image]::FromFile('" . StageLiteral . "');"
			. "try{Write-Output ('PIXEL='+$received.GetPixel(0,0).R+','+$received.GetPixel(0,0).G+','+$received.GetPixel(0,0).B)}finally{$received.Dispose()}"
		FixtureType := "$ProgressPreference = 'SilentlyContinue';Add-Type -TypeDefinition 'public static class ErgoptiRegionFixtureClipboard {"
			. '[System.Runtime.InteropServices.DllImport("user32.dll")]public static extern uint GetClipboardSequenceNumber();}' . "' -ErrorAction Stop;"
		Args[Args.Length] := FixtureType . _GSQ_BitmapDiagnostics() . Script
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
		for DiagnosticLine in StrSplit(StrReplace(State.Output, "`r`n", "`n"), "`n") {
			if InStr(DiagnosticLine, "REGION_BITMAP_") == 1
				_TestAppendProgress("# " . DiagnosticLine)
		}
		AssertEqual(1, State.Calls, "the exact worker must settle once")
		if Mode == "after" {
			AssertTrue(RegExMatch(State.Output, "m)^OWNED_SEQUENCE=(\d+)\r?$", &Receipt),
				"the controlled native copy must report its own sequence: " . State.Output . State.ErrorText)
			OwnedSequence := Integer(Receipt[1])
		}
		if Mode == "before" || Mode == "unknown" {
			AssertTrue(State.Code != 0, "the worker must refuse lost clipboard custody: " . State.Output . State.ErrorText)
			; Tree-owned ShellRunner deliberately combines native stderr into stdout.
			AssertTrue(InStr(State.Output . State.ErrorText, "clipboard content changed") > 0,
				"the refusal must report its actual custody failure: " . State.Output . State.ErrorText)
			AssertFalse(FileExist(Stage), "refused custody must never create a staged image")
		} else {
			AssertEqual(0, State.Code, "the native worker must succeed: " . State.Output . State.ErrorText)
			AssertEqual("", State.ErrorText)
			AssertTrue(FileExist(Stage), "an admitted image must be saved")
			AssertTrue(InStr(State.Output, "PIXEL=255,0,0") > 0, "the stage must contain the selected red pixel")
			if Mode == "locked"
				AssertTrue(LockProbed && LockObserved, "another process cannot replace the bitmap during acquisition")
			if Mode == "delayed" {
				AssertEqual(1, Renderer.Calls, "the native delayed renderer must answer once")
				AssertEqual("", Renderer.ErrorText)
				AssertTrue(Renderer.Sequence > 0 && CB_GetSequenceNumber() > 0,
					"the real delayed owner must retain observable clipboard content")
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
