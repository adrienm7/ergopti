; tests/unit/test_native_dialog_titles.ahk
;
; ==============================================================================
; MODULE: Native Dialog Caption Regression
; DESCRIPTION:
; Executes the actual native caption owner and actual generated policy in private
; AHK children. Visible message/input captions are captured independently of the
; shared composer, alongside body, timeout and exact default-text receipts.
; Calls precede both owner #Includes, exercising their pre-bootstrap availability.
; Snapshot every native property before file I/O pumps the timeout dialog away.
; Return the capture callback before awaiting actual native timeout retirement.
; An expired-window mutation must reproduce the original exact native exception.
; ==============================================================================

/**
 * Settles one exact process tree before inspecting its completion observations.
 * @param {string} Executable - The native executable.
 * @param {Array} Args - Structured arguments.
 * @param {object} Ownership - Retains the fixture if exact child retirement fails.
 * @param {integer} ExpectedCode - Zero for real probes, two only for the expiry mutation.
 * @param {integer} TimeoutMs - Bound derived from the owned child observations.
 * @returns {string} Captured ASCII completion acknowledgement.
 */
_NDT_RunChild(Executable, Args, Ownership, ExpectedCode := 0, TimeoutMs := 15000) {
	Receipt := {Calls: 0, Code: -1, Output: "", Errors: ""}
	OnDone(Code, Output, Errors) {
		Receipt.Calls += 1
		Receipt.Code := Code
		Receipt.Output := Output
		Receipt.Errors := Errors
	}
	Handle := ShellRunner_SpawnTreeOwned(Executable, Args, OnDone)
	try {
		AssertTrue(Handle.start(), "the exact native-dialog child must start")
		Started := A_TickCount
		while !Receipt.Calls && TickElapsed(Started) < TimeoutMs {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Receipt.Calls, "the native-dialog child completes exactly once")
		AssertEqual(ExpectedCode, Receipt.Code, "the actual native caption owner parses and runs: "
			. Receipt.Output . Receipt.Errors)
		AssertEqual("", Receipt.Errors, "native dialog receipts contain no hidden errors")
		return Receipt.Output
	} finally {
		Settled := Handle.terminate()
		if !Settled
			Ownership.CanRetire := false
		AssertTrue(Settled, "the exact native-dialog process tree is retired")
	}
}

/**
 * Finds the production caption owner by its public symbol, surviving file moves.
 * @returns {string} The sole source owning every native dialog delegate.
 */
_NDT_NativeDialogOwner() {
	global _StaticDir
	Owners := []
	Loop Files, _StaticDir . "\ergopti_plus\windows\*.ahk", "R" {
		if !_DriverIsProductionSource(A_LoopFileFullPath)
			continue
		Source := FileRead(A_LoopFileFullPath, "UTF-8")
		if !_DriverFindFunctionDefinition(&Source, "Ui_MsgBox")
			continue
		AssertTrue(IsObject(_DriverFindFunctionDefinition(&Source, "Ui_InputBox")),
			"the public input delegate belongs to the same native caption owner")
		AssertTrue(IsObject(_DriverFindFunctionDefinition(&Source, "Ui_DirSelect")),
			"the public folder delegate belongs to the same native caption owner")
		Owners.Push(A_LoopFileFullPath)
	}
	AssertEqual(1, Owners.Length, "the native caption delegates have one production owner")
	return Owners[1]
}


/**
 * Parses the actual dialog include graph before opening any native window.
 * Strict stdout retains #Warn diagnostics rather than filtering them away.
 */
_NDT_NativeOwnersParseWithoutWarnings() {
	global _StaticDir
	Root := A_Temp . "\ergopti_dialog_parse_" . A_ScriptHwnd . "_" . A_TickCount
	AssertFalse(DirExist(Root), "the native parse fixture must be privately owned")
	DirCreate(Root)
	Ownership := {CanRetire: true}
	try {
		Artifact := _StaticDir . "\ergopti_plus\windows\_generated\window_titles.ahk"
		Owner := _NDT_NativeDialogOwner()
		Harness := Root . "\parse_dialog_owners.ahk"
		FileAppend('#Requires AutoHotkey v2.0' . "`n"
			. '#SingleInstance Off' . "`n"
			. '#Warn All, StdOut' . "`n"
			. 'Thread("NoTimers", false)' . "`n"
			. 'FileAppend("dialog-owners-parsed", "*", "UTF-8-RAW")' . "`n"
			. 'ExitApp(0)' . "`n"
			. '#Include ' . Artifact . "`n"
			. '#Include ' . Owner . "`n", Harness, "UTF-8")
		AssertEqual("dialog-owners-parsed", _NDT_RunChild(A_AhkPath,
			["/ErrorStdOut", Harness], Ownership),
			"the real native owners preserve Thread() and parse with no #Warn output")
	} finally {
		if Ownership.CanRetire
			DirDelete(Root, true)
	}
}
Test("native dialogs: actual owners parse without shadowing built-in Thread", _NDT_NativeOwnersParseWithoutWarnings)


/**
 * Builds a private probe which includes the real dialog owner without copying it.
 * Its timer records observations only; assertions belong to the completed parent.
 * @param {string} Artifact - Privately generated shared policy.
 * @param {string} Owner - Actual production native-dialog owner.
 * @returns {string} Complete AHK child source.
 */
_NDT_ProbeSource(Artifact, Owner) {
	return "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#Warn All, StdOut`n"
		. 'OnError(_NDTProbeError)' . "`n"
		. 'global _NDTReceipt := ""' . "`n"
		. 'global _NDTSnapshot := 0' . "`n"
		. '_NDTReceipt := A_Args[1] . "\message"' . "`n"
		. 'SetTimer(_NDTCapture, 20)' . "`n"
		. 'MessageResult := Ui_MsgBox("Preserved message body", "Navigation layer", "YesNo Default2 Icon! T0.5")' . "`n"
		. 'SetTimer(_NDTCapture, 0)' . "`n"
		. '_NDTPersist()' . "`n"
		. 'FileAppend(MessageResult, A_Args[1] . "\message.result", "UTF-8-RAW")' . "`n"
		. '_NDTReceipt := A_Args[1] . "\input"' . "`n"
		. 'SetTimer(_NDTCapture, 20)' . "`n"
		. 'InputResult := Ui_InputBox("Preserved input body", "Navigation layer", "w320 h180 Password T0.5", " Secret value ")' . "`n"
		. 'SetTimer(_NDTCapture, 0)' . "`n"
		. '_NDTPersist()' . "`n"
		. 'FileAppend(InputResult.Result . "``n" . InputResult.Value, A_Args[1] . "\input.result", "UTF-8-RAW")' . "`n"
		. '_NDTReceipt := A_Args[1] . "\unnamed"' . "`n"
		. 'SetTimer(_NDTCapture, 20)' . "`n"
		. 'UnnamedResult := Ui_MsgBox("Preserved unnamed body", , "T0.5")' . "`n"
		. 'SetTimer(_NDTCapture, 0)' . "`n"
		. '_NDTPersist()' . "`n"
		. 'FileAppend(UnnamedResult, A_Args[1] . "\unnamed.result", "UTF-8-RAW")' . "`n"
		. '_NDTReceipt := A_Args[1] . "\cancelled"' . "`n"
		. 'SetTimer(_NDTCapture, 20)' . "`n"
		. 'CancelledResult := Ui_InputBox("Preserved cancelled body", "Navigation layer", "w320 h180 T2", " Secret value ")' . "`n"
		. 'SetTimer(_NDTCapture, 0)' . "`n"
		. '_NDTPersist()' . "`n"
		. 'FileAppend(CancelledResult.Result . "``n" . CancelledResult.Value, A_Args[1] . "\cancelled.result", "UTF-8-RAW")' . "`n"
		. 'FileAppend("dialogs-written", "*", "UTF-8-RAW")' . "`nExitApp(0)`n"
		. '_NDTCapture() {' . "`n"
		. 'global _NDTReceipt, _NDTSnapshot' . "`n"
		. 'for Hwnd in WinGetList("ahk_pid " . DllCall("GetCurrentProcessId", "UInt")) {' . "`n"
		. 'if Hwnd == A_ScriptHwnd || !DllCall("IsWindowVisible", "Ptr", Hwnd)' . "`ncontinue`n"
		. 'Caption := WinGetTitle("ahk_id " . Hwnd)' . "`n"
		. 'Body := WinGetText("ahk_id " . Hwnd)' . "`n"
		. 'Buttons := ""' . "`n"
		. 'Password := ""' . "`n"
		. 'if InStr(_NDTReceipt, "\message") {' . "`n"
		. 'YesButton := DllCall("GetDlgItem", "Ptr", Hwnd, "Int", 6, "Ptr")' . "`n"
		. 'NoButton := DllCall("GetDlgItem", "Ptr", Hwnd, "Int", 7, "Ptr")' . "`n"
		. 'DefaultId := SendMessage(0x400, 0, 0, , "ahk_id " . Hwnd) & 0xFFFF' . "`n"
		. 'Buttons := (YesButton ? "yes" : "missing") . "|" . (NoButton ? "no" : "missing") . "|" . DefaultId' . "`n}`n"
		. 'if InStr(_NDTReceipt, "\input") {' . "`n"
		. 'InputControlHwnd := ControlGetHwnd("Edit1", "ahk_id " . Hwnd)' . "`n"
		. 'Password := (WinGetStyle("ahk_id " . InputControlHwnd) & 0x20) ? "password" : "plain"' . "`n}`n"
		. 'SetTimer(_NDTCapture, 0)' . "`n"
		. 'if InStr(_NDTReceipt, "\cancelled")' . "`n"
		. 'PostMessage(0x10, 0, 0, , "ahk_id " . Hwnd)' . "`n"
		. '_NDTSnapshot := {Hwnd: Hwnd, Caption: Caption, Body: Body, Buttons: Buttons, Password: Password}' . "`n"
		. 'return' . "`n}`n}`n"
		. '_NDTPersist() {' . "`n"
		. 'global _NDTReceipt, _NDTSnapshot' . "`n"
		. 'if !IsObject(_NDTSnapshot)' . "`n"
		. 'throw Error("The actual native dialog must publish its complete snapshot")' . "`n"
		. 'Captured := _NDTSnapshot' . "`n"
		. 'if InStr(_NDTReceipt, "\message") && A_Args[2] == "delay" {' . "`n"
		. 'Sleep(700)' . "`n"
		. 'FileAppend(DllCall("IsWindow", "Ptr", Captured.Hwnd) ? "live" : "retired", _NDTReceipt . ".retirement", "UTF-8-RAW")' . "`n}`n"
		. 'FileAppend(Captured.Caption, _NDTReceipt . ".title", "UTF-8-RAW")' . "`n"
		. 'FileAppend(Captured.Body, _NDTReceipt . ".body", "UTF-8-RAW")' . "`n"
		. 'if Captured.Buttons != ""' . "`n"
		. 'FileAppend(Captured.Buttons, _NDTReceipt . ".buttons", "UTF-8-RAW")' . "`n"
		. 'if Captured.Password != ""' . "`n"
		. 'FileAppend(Captured.Password, _NDTReceipt . ".password", "UTF-8-RAW")' . "`n"
		. '_NDTSnapshot := 0' . "`n}`n"
		. '_NDTProbeError(Err, *) {' . "`n"
		. 'FileAppend(Err.Message, "*", "UTF-8-RAW")' . "`nExitApp(2)`n}`n"
		. '#Include ' . Artifact . "`n"
		. '#Include ' . Owner . "`n"
}


/**
 * Builds a real IFileDialog probe with exact caption, filter and result receipts.
 * Native observations finish before any file I/O or owned dialog cancellation.
 * @param {string} Artifact - Actual privately generated shared caption policy.
 * @param {string} Owner - Actual native caption owner, including the file picker.
 * @returns {string} Complete native child source.
 */
_NDT_FilePickerProbeSource(Artifact, Owner) {
	return '#Requires AutoHotkey v2.0' . "`n"
		. '#SingleInstance Off' . "`n"
		. '#Warn All, StdOut' . "`n"
		. 'OnError(_NFPError)' . "`n"
		. 'global _NFPRoot := A_Args[1]' . "`n"
		. 'global _NFPMode := ""' . "`n"
		. 'global _NFPOwnedFile := _NFPRoot . "\selected.txt"' . "`n"
		. 'FileAppend("Owned fixture contents", _NFPOwnedFile, "UTF-8-RAW")' . "`n"
		. 'CanonicalBuffer := Buffer(65536, 0)' . "`n"
		. 'CanonicalLength := DllCall("GetLongPathNameW", "Str", _NFPOwnedFile, "Ptr", CanonicalBuffer, "UInt", 32768, "UInt")' . "`n"
		. 'if !CanonicalLength || CanonicalLength >= 32768' . "`n"
		. 'throw Error("The privately owned fixture path must resolve")' . "`n"
		. '_NFPOwnedFile := StrGet(CanonicalBuffer, CanonicalLength, "UTF-16")' . "`n"
		. 'FileAppend(_NFPOwnedFile, _NFPRoot . "\owned.path", "UTF-8-RAW")' . "`n"
		. '_NFPMode := "baseline"' . "`n"
		. 'SetTimer(_NFPCapture, 20)' . "`n"
		. '_NFPBaseline := FileSelect(35, _NFPOwnedFile, "Owned native baseline", "Owned files (*.txt)")' . "`n"
		. 'SetTimer(_NFPCapture, 0)' . "`n"
		. 'FileAppend(Type(_NFPBaseline) . "|" . _NFPBaseline, _NFPRoot . "\baseline.result", "UTF-8-RAW")' . "`n"
		. '_NFPMode := "selected"' . "`n"
		. 'SetTimer(_NFPCapture, 20)' . "`n"
		. '_NFPSelected := Ui_FileSelect(35, _NFPOwnedFile, "Navigation layer", "Owned files (*.txt)")' . "`n"
		. 'SetTimer(_NFPCapture, 0)' . "`n"
		. 'FileAppend(_NFPSelected, _NFPRoot . "\selected.result", "UTF-8-RAW")' . "`n"
		. '_NFPMode := "cancelled"' . "`n"
		. 'SetTimer(_NFPCapture, 20)' . "`n"
		. '_NFPCancelled := Ui_FileSelect("M35", _NFPOwnedFile, "Navigation layer", "Owned files (*.txt)")' . "`n"
		. 'SetTimer(_NFPCapture, 0)' . "`n"
		. 'FileAppend(Type(_NFPCancelled) . "|" . (_NFPCancelled is Array ? _NFPCancelled.Length : "wrong-shape"), _NFPRoot . "\cancelled.result", "UTF-8-RAW")' . "`n"
		. 'FileAppend("file-picker-written", "*", "UTF-8-RAW")' . "`n"
		. 'ExitApp(0)' . "`n"
		. '_NFPCapture() {' . "`n"
		. 'global _NFPRoot, _NFPMode' . "`n"
		. 'for Hwnd in WinGetList("ahk_pid " . DllCall("GetCurrentProcessId", "UInt")) {' . "`n"
		. 'if Hwnd == A_ScriptHwnd || !DllCall("IsWindowVisible", "Ptr", Hwnd)' . "`n"
		. 'continue' . "`n"
		. 'if WinGetClass("ahk_id " . Hwnd) != "#32770"' . "`n"
		. 'continue' . "`n"
		. 'Caption := WinGetTitle("ahk_id " . Hwnd)' . "`n"
		. 'FilterDescription := ""' . "`n"
		. 'PickerControlCount := 0' . "`n"
		. 'PickerControlShapes := ""' . "`n"
		. 'PickerTypeCombo := 0' . "`n"
		. 'for ControlHwnd in WinGetControlsHwnd("ahk_id " . Hwnd) {' . "`n"
		. 'ControlClass := WinGetClass("ahk_id " . ControlHwnd)' . "`n"
		. 'PickerControlCount += 1' . "`n"
		. 'PickerControlId := DllCall("GetDlgCtrlID", "Ptr", ControlHwnd, "Int")' . "`n"
		. 'if ControlClass == "ComboBox" && PickerControlId == 1136 {' . "`n"
		. 'if PickerTypeCombo' . "`n"
		. 'throw Error("The owned native picker must have one file-type ComboBox")' . "`n"
		. 'PickerTypeCombo := ControlHwnd' . "`n"
		. '}' . "`n"
		. 'if PickerControlCount <= 24 {' . "`n"
		. 'PickerControlShapes .= (PickerControlShapes == "" ? "" : "|") . SubStr(ControlClass, 1, 48) . ":" . PickerControlId' . "`n"
		. '}' . "`n"
		. '}' . "`n"
		. 'if !PickerTypeCombo || !DllCall("IsChild", "Ptr", Hwnd, "Ptr", PickerTypeCombo) || WinGetClass("ahk_id " . PickerTypeCombo) != "ComboBox"' . "`n"
		. 'throw Error("The owned native picker requires its file-type ComboBox")' . "`n"
		. 'PickerTypeItems := ControlGetItems(PickerTypeCombo)' . "`n"
		. 'PickerTypeIndex := ControlGetIndex(PickerTypeCombo)' . "`n"
		. 'PickerTypeChoice := ControlGetChoice(PickerTypeCombo)' . "`n"
		. 'PickerTypeReceipt := "items=" . PickerTypeItems.Length . ",truncated=" . Max(0, PickerTypeItems.Length - 4) . ",selected=" . PickerTypeIndex' . "`n"
		. 'for PickerTypeItemIndex, PickerTypeItem in PickerTypeItems {' . "`n"
		. 'FilterDescription .= PickerTypeItem . "|"' . "`n"
		. 'if PickerTypeItemIndex <= 4' . "`n"
		. 'PickerTypeReceipt .= "|" . PickerTypeItemIndex . ":" . SubStr(StrReplace(StrReplace(PickerTypeItem, "``r", "\r"), "``n", "\n"), 1, 128)' . "`n"
		. '}' . "`n"
		. 'PickerTypeReceipt .= "|choice:" . SubStr(StrReplace(StrReplace(PickerTypeChoice, "``r", "\r"), "``n", "\n"), 1, 128)' . "`n"
		. 'SetTimer(_NFPCapture, 0)' . "`n"
		. 'if _NFPMode == "selected" {' . "`n"
		. 'OpenButton := DllCall("GetDlgItem", "Ptr", Hwnd, "Int", 1, "Ptr")' . "`n"
		. 'if !OpenButton || !DllCall("IsWindowEnabled", "Ptr", OpenButton)' . "`n"
		. 'throw Error("The native picker requires its enabled default Open button")' . "`n"
		. 'PostMessage(0xF5, 0, 0, , "ahk_id " . OpenButton)' . "`n}`n"
		. 'else' . "`n"
		. 'PostMessage(0x10, 0, 0, , "ahk_id " . Hwnd)' . "`n"
		. 'FileAppend(Caption, _NFPRoot . "\" . _NFPMode . ".title", "UTF-8-RAW")' . "`n"
		. 'FileAppend(FilterDescription, _NFPRoot . "\" . _NFPMode . ".filter", "UTF-8-RAW")' . "`n"
		. 'PickerDiagnostic := "controls=" . PickerControlCount . ",truncated=" . Max(0, PickerControlCount - 24) . ";" . PickerControlShapes' . "`n"
		. 'FileAppend(PickerDiagnostic, _NFPRoot . "\" . _NFPMode . ".controls", "UTF-8-RAW")' . "`n"
		. 'FileAppend(PickerTypeReceipt, _NFPRoot . "\" . _NFPMode . ".types", "UTF-8-RAW")' . "`n"
		. 'return' . "`n"
		. '}' . "`n"
		. '}' . "`n"
		. '_NFPError(ProbeError, *) {' . "`n"
		. 'FileAppend(ProbeError.Message, "*", "UTF-8-RAW")' . "`n"
		. 'ExitApp(2)' . "`n"
		. '}' . "`n"
		. '#Include ' . Artifact . "`n"
		. '#Include ' . Owner . "`n"
}


/** Checks actual generated statement boundaries without opening any native UI. */
_NDT_FilePickerProbeStatementSeparators() {
	Probe := _NDT_FilePickerProbeSource("Owned policy", "Owned caption owner")
	StrReplace(Probe, "128)" . "`n", "", , &StatementBoundaries)
	AssertEqual(2, StatementBoundaries,
		"both bounded filter receipt statements require real generated LF separators")
	AssertFalse(InStr(Probe, "128)" . Chr(96) . "n") > 0,
		"a literal backtick-n cannot separate generated native AHK statements")
	AssertContains(Probe, '"' . Chr(96) . 'r", "\r"',
		"the child still escapes captured carriage returns inside its own string literal")
	AssertContains(Probe, '"' . Chr(96) . 'n", "\n"',
		"the child still escapes captured linefeeds inside its own string literal")
}
Test("native file picker: generated receipt statements retain LF and escaped text", _NDT_FilePickerProbeStatementSeparators)


/**
 * Resolves the actual vendored UIA include through its production entry graph.
 * @returns {string} The unique native library included by the real entry.
 */
_NDT_FileFilterUiaOwner() {
	global _StaticDir
	UiaOwners := []
	Loop Files, _StaticDir . "\ergopti_plus\windows\*.ahk" {
		UiaSource := FileRead(A_LoopFileFullPath, "UTF-8")
		if !RegExMatch(UiaSource, "m)^#Include \*i ([^\r\n]+?UIA\.ahk)(?: |$)", &UiaInclude)
			continue
		SplitPath(A_LoopFileFullPath, , &UiaEntryDirectory)
		UiaLibrary := UiaEntryDirectory . "\" . UiaInclude[1]
		AssertTrue(FileExist(UiaLibrary) != "", "the actual native UIA entry include must exist")
		UiaOwners.Push(UiaLibrary)
	}
	AssertEqual(1, UiaOwners.Length, "the native UIA observer has one real entry include owner")
	return UiaOwners[1]
}


/**
 * Runs real UIA queries in a distinct client of the owned modal shell view.
 * Exact normal shell names account for the OS setting that hides extensions.
 * No foreign UI names, filenames, paths or tree/sidebar content are collected.
 * @param {string} UiaOwner - Vendor include resolved from the production entry.
 * @returns {string} Complete private observer with bounded native queries.
 */
_NDT_FileFilterObserverSource(UiaOwner) {
	return '#Requires AutoHotkey v2.0' . "`n"
		. '#SingleInstance Off' . "`n"
		. '#NoTrayIcon' . "`n"
		. '#Warn All, StdOut' . "`n"
		. 'global IUIAutomationActivateScreenReader := 0' . "`n"
		. 'OnError(_NFO_Error)' . "`n"
		. '_NFO_Main(A_Args)' . "`n"
		. 'ExitApp(0)' . "`n"
		. '_NFO_Main(ObserverArgs) {' . "`n"
		. 'ObserverReceipt := ObserverArgs[1]' . "`n"
		. 'ObserverPhaseStarted := A_TickCount' . "`n"
		. '_NFO_Phase("entry", ObserverPhaseStarted)' . "`n"
		. 'ObserverWindow := Integer(ObserverArgs[2])' . "`n"
		. 'ObserverProcess := Integer(ObserverArgs[3])' . "`n"
		. 'ObserverView := Integer(ObserverArgs[4])' . "`n"
		. 'ObserverType := Integer(ObserverArgs[5])' . "`n"
		. 'ObserverWaitMs := Integer(ObserverArgs[9])' . "`n"
		. 'ObserverUiaTimeoutMs := Integer(ObserverArgs[10])' . "`n"
		. 'ObserverExpectedItems := StrSplit(FileRead(ObserverArgs[8], "UTF-8"), "|")' . "`n"
		. 'if ObserverExpectedItems.Length != 3 || ObserverExpectedItems[1] == "" || ObserverExpectedItems[2] != "All Files (*.*)" || ObserverExpectedItems[3] != ""' . "`n"
		. 'throw Error("The direct native baseline must publish two exact nonempty filter labels")' . "`n"
		. 'if ObserverProcess == DllCall("GetCurrentProcessId", "UInt")' . "`n"
		. 'throw Error("The owned UIA observer must be a separate client process")' . "`n"
		. '_NFO_Phase("com", ObserverPhaseStarted)' . "`n"
		. 'ObserverCom := DllCall("ole32\CoInitializeEx", "Ptr", 0, "UInt", 2, "Int")' . "`n"
		. 'if ObserverCom != 0 && ObserverCom != 1' . "`n"
		. 'throw Error("The owned observer cannot acquire its COM apartment")' . "`n"
		. 'try {' . "`n"
		. '_NFO_Phase("shell-items", ObserverPhaseStarted)' . "`n"
		. 'ObserverTxtNames := _NFO_ShellNames(ObserverArgs[6])' . "`n"
		. 'ObserverBinNames := _NFO_ShellNames(ObserverArgs[7])' . "`n"
		. 'UIA.ConnectionTimeout := ObserverUiaTimeoutMs' . "`n"
		. 'UIA.TransactionTimeout := ObserverUiaTimeoutMs' . "`n"
		. '_NFO_Fence(ObserverWindow, ObserverProcess, ObserverView, ObserverType)' . "`n"
		. '_NFO_Phase("uia-provider", ObserverPhaseStarted)' . "`n"
		. 'ObserverElement := UIA.ElementFromHandle(ObserverView, , false)' . "`n"
		. 'if ObserverElement.ProcessId != ObserverProcess' . "`n"
		. 'throw Error("The owned shell-view UIA element must match its native process")' . "`n"
		. 'ObserverStarted := A_TickCount' . "`n"
		. '_NFO_Phase("restricted-txt", ObserverPhaseStarted)' . "`n"
		. '_NFO_WaitVisible(ObserverElement, ObserverTxtNames, ObserverWindow, ObserverProcess, ObserverView, ObserverType, ObserverStarted, ObserverWaitMs)' . "`n"
		. 'ObserverItems := ControlGetItems(ObserverType)' . "`n"
		. 'if ControlGetIndex(ObserverType) != 1' . "`n"
		. 'throw Error("The owned picker must begin on its first file type")' . "`n"
		. 'if ObserverItems.Length == 1 && ObserverItems[1] == "All Files (*.*)" {' . "`n"
		. '_NFO_WaitVisible(ObserverElement, ObserverBinNames, ObserverWindow, ObserverProcess, ObserverView, ObserverType, ObserverStarted, ObserverWaitMs)' . "`n"
		. 'throw Error("Owned BIN visible under the restricted file filter")' . "`n"
		. '}' . "`n"
		. '_NFO_Phase("restricted-bin", ObserverPhaseStarted)' . "`n"
		. 'if _NFO_Visible(ObserverElement, ObserverBinNames, ObserverProcess)' . "`n"
		. 'throw Error("Owned BIN visible under the restricted file filter")' . "`n"
		. 'if ObserverItems.Length != 2 || ObserverItems[1] != ObserverExpectedItems[1] || ObserverItems[2] != ObserverExpectedItems[2]' . "`n"
		. 'throw Error("The native friendly names must match independently observed SetFileTypes labels")' . "`n"
		. '_NFO_Phase("all-files", ObserverPhaseStarted)' . "`n"
		. 'ControlChooseIndex(2, ObserverType)' . "`n"
		. 'ObserverStarted := A_TickCount' . "`n"
		. '_NFO_WaitVisible(ObserverElement, ObserverBinNames, ObserverWindow, ObserverProcess, ObserverView, ObserverType, ObserverStarted, ObserverWaitMs)' . "`n"
		. 'if ControlGetIndex(ObserverType) != 2' . "`n"
		. 'throw Error("The owned native All Files selection must be acknowledged")' . "`n"
		. '_NFO_Phase("restored", ObserverPhaseStarted)' . "`n"
		. 'ControlChooseIndex(1, ObserverType)' . "`n"
		. 'ObserverStarted := A_TickCount' . "`n"
		. 'loop {' . "`n"
		. '_NFO_Fence(ObserverWindow, ObserverProcess, ObserverView, ObserverType)' . "`n"
		. 'if ControlGetIndex(ObserverType) == 1 && _NFO_Visible(ObserverElement, ObserverTxtNames, ObserverProcess) && !_NFO_Visible(ObserverElement, ObserverBinNames, ObserverProcess)' . "`n"
		. 'break' . "`n"
		. 'if ((A_TickCount - ObserverStarted) & 0xFFFFFFFF) >= ObserverWaitMs' . "`n"
		. 'throw Error("The restored native file filter must show TXT and hide BIN")' . "`n"
		. 'Sleep(10)' . "`n"
		. '}' . "`n"
		. '_NFO_Fence(ObserverWindow, ObserverProcess, ObserverView, ObserverType)' . "`n"
		. '_NFO_Phase("complete", ObserverPhaseStarted)' . "`n"
		. 'FileAppend("txt-visible|bin-hidden|all-files-bin-visible|restored-txt-visible|restored-bin-hidden|separate-client|owner-fenced", ObserverReceipt . ".behavior", "UTF-8-RAW")' . "`n"
		. 'FileAppend("owned-filter-observed", ObserverReceipt . ".ack", "UTF-8-RAW")' . "`n"
		. 'FileAppend("owned-filter-observed", "*", "UTF-8-RAW")' . "`n"
		. '} finally {' . "`n"
		. 'DllCall("ole32\CoUninitialize")' . "`n"
		. '}' . "`n"
		. '}' . "`n"
		. '_NFO_Phase(ObserverPhaseToken, ObserverPhaseStarted) {' . "`n"
		. 'ObserverPhaseFile := FileOpen(A_Args[1] . ".phase", "w", "UTF-8-RAW")' . "`n"
		. 'if !IsObject(ObserverPhaseFile)' . "`n"
		. 'throw Error("The owned observer phase receipt must open")' . "`n"
		. 'try {' . "`n"
		. 'ObserverPhaseFile.Write(ObserverPhaseToken . "|elapsed_ms=" . ((A_TickCount - ObserverPhaseStarted) & 0xFFFFFFFF))' . "`n"
		. '} finally {' . "`n"
		. 'ObserverPhaseFile.Close()' . "`n"
		. '}' . "`n"
		. '}' . "`n"
		. '_NFO_ShellNames(OwnedPath) {' . "`n"
		. 'ObserverIid := Buffer(16)' . "`n"
		. 'if DllCall("ole32\CLSIDFromString", "Str", "{43826D1E-E718-42EE-BC55-A1E261C37BFE}", "Ptr", ObserverIid, "Int") != 0' . "`n"
		. 'throw Error("The owned shell-item interface must parse")' . "`n"
		. 'ObserverItem := 0' . "`n"
		. 'if DllCall("shell32\SHCreateItemFromParsingName", "Str", OwnedPath, "Ptr", 0, "Ptr", ObserverIid, "Ptr*", &ObserverItem, "Int") < 0 || !ObserverItem' . "`n"
		. 'throw Error("The owned file must have an authoritative shell item")' . "`n"
		. 'ObserverDisplay := 0' . "`n"
		. 'try {' . "`n"
		. 'ComCall(5, ObserverItem, "UInt", 0, "Ptr*", &ObserverDisplay)' . "`n"
		. 'if !ObserverDisplay' . "`n"
		. 'throw Error("The owned file must have a normal shell display name")' . "`n"
		. 'ObserverName := StrGet(ObserverDisplay, "UTF-16")' . "`n"
		. 'SplitPath(OwnedPath, &ObserverTypedName)' . "`n"
		. 'if ObserverName == "" || ObserverTypedName == ""' . "`n"
		. 'throw Error("The owned file name baseline cannot be empty")' . "`n"
		. 'return ObserverName == ObserverTypedName ? [ObserverName] : [ObserverName, ObserverTypedName]' . "`n"
		. '} finally {' . "`n"
		. 'if ObserverDisplay' . "`n"
		. 'DllCall("ole32\CoTaskMemFree", "Ptr", ObserverDisplay)' . "`n"
		. 'ObjRelease(ObserverItem)' . "`n"
		. '}' . "`n"
		. '}' . "`n"
		. '_NFO_Fence(OwnerWindow, OwnerProcess, OwnerView, OwnerType) {' . "`n"
		. 'for OwnerHandle in [OwnerWindow, OwnerView, OwnerType] {' . "`n"
		. 'if !DllCall("IsWindow", "Ptr", OwnerHandle) || WinGetPID("ahk_id " . OwnerHandle) != OwnerProcess' . "`n"
		. 'throw Error("The native filter observer lost its exact owned window")' . "`n"
		. '}' . "`n"
		. 'if WinGetClass("ahk_id " . OwnerWindow) != "#32770"' . "`n"
		. 'throw Error("The owned picker requires its native dialog class")' . "`n"
		. 'if !DllCall("IsChild", "Ptr", OwnerWindow, "Ptr", OwnerView) || WinGetClass("ahk_id " . OwnerView) != "SHELLDLL_DefView" || DllCall("GetDlgCtrlID", "Ptr", OwnerView, "Int") != 1121' . "`n"
		. 'throw Error("The owned filter observations require the native shell-view descendant")' . "`n"
		. 'if !DllCall("IsChild", "Ptr", OwnerWindow, "Ptr", OwnerType) || WinGetClass("ahk_id " . OwnerType) != "ComboBox" || DllCall("GetDlgCtrlID", "Ptr", OwnerType, "Int") != 1136' . "`n"
		. 'throw Error("The owned filter observations require the native file-type descendant")' . "`n"
		. '}' . "`n"
		. '_NFO_Visible(OwnerElement, OwnerNames, OwnerProcess) {' . "`n"
		. 'for OwnerName in OwnerNames {' . "`n"
		. 'OwnerMatches := OwnerElement.FindElements([{Type: "ListItem", Name: OwnerName}, {Type: "DataItem", Name: OwnerName}])' . "`n"
		. 'if OwnerMatches.Length > 1' . "`n"
		. 'throw Error("An exact owned filename must identify at most one native file item")' . "`n"
		. 'for OwnerMatch in OwnerMatches {' . "`n"
		. 'if OwnerMatch.ProcessId != OwnerProcess' . "`n"
		. 'throw Error("A native file item cannot cross the owned process fence")' . "`n"
		. 'if !OwnerMatch.IsOffscreen' . "`n"
		. 'return true' . "`n"
		. '}' . "`n"
		. '}' . "`n"
		. 'return false' . "`n"
		. '}' . "`n"
		. '_NFO_WaitVisible(OwnerElement, OwnerNames, OwnerWindow, OwnerProcess, OwnerView, OwnerType, ObserverStarted, ObserverWaitMs) {' . "`n"
		. 'loop {' . "`n"
		. '_NFO_Fence(OwnerWindow, OwnerProcess, OwnerView, OwnerType)' . "`n"
		. 'if _NFO_Visible(OwnerElement, OwnerNames, OwnerProcess)' . "`n"
		. 'return' . "`n"
		. 'if ((A_TickCount - ObserverStarted) & 0xFFFFFFFF) >= ObserverWaitMs' . "`n"
		. 'throw Error("An exact owned file item did not become visible in the native shell view")' . "`n"
		. 'Sleep(10)' . "`n"
		. '}' . "`n"
		. '}' . "`n"
		. '_NFO_Error(ObserverFailure, *) {' . "`n"
		. 'FileAppend(ObserverFailure.Message, A_Args[1] . ".failure", "UTF-8-RAW")' . "`n"
		. 'ExitApp(2)' . "`n"
		. '}' . "`n"
		. '#Include ' . UiaOwner . "`n"
}


/**
 * Pumps the modal provider while the distinct owned observer captures both streams.
 * The already-owned process job contains both the picker and this descendant.
 * @returns {string} Bounded observer invocation before the native modal closes.
 */
_NDT_FileFilterCaptureSource() {
	return 'SetTimer(_NFPCapture, 0)' . "`n"
		. 'PickerShellView := 0' . "`n"
		. 'for PickerViewCandidate in WinGetControlsHwnd("ahk_id " . Hwnd) {' . "`n"
		. 'if WinGetClass("ahk_id " . PickerViewCandidate) == "SHELLDLL_DefView" && DllCall("GetDlgCtrlID", "Ptr", PickerViewCandidate, "Int") == 1121 {' . "`n"
		. 'if PickerShellView' . "`n"
		. 'throw Error("The owned picker must have one native shell view")' . "`n"
		. 'PickerShellView := PickerViewCandidate' . "`n"
		. '}' . "`n"
		. '}' . "`n"
		. 'if !PickerShellView || !DllCall("IsChild", "Ptr", Hwnd, "Ptr", PickerShellView)' . "`n"
		. 'throw Error("The real filter proof requires the owned shell-view descendant")' . "`n"
		. '_NFPLastHwnd := Hwnd' . "`n"
		. 'PickerObserverReceipt := _NFPRoot . "\" . _NFPMode . ".observer"' . "`n"
		. 'FileAppend("", PickerObserverReceipt . ".failure", "UTF-8-RAW")' . "`n"
		. 'PickerObserverArguments := [A_AhkPath, "/ErrorStdOut", _NFPObserverPath, PickerObserverReceipt, Hwnd, DllCall("GetCurrentProcessId", "UInt"), PickerShellView, PickerTypeCombo, _NFPOwnedFile, _NFPBinFile, _NFPRoot . "\baseline.filter", _NFPViewWaitMs, _NFPUiaTimeoutMs]' . "`n"
		. 'PickerObserverCommand := ""' . "`n"
		. 'for PickerObserverArgument in PickerObserverArguments {' . "`n"
		. 'if InStr(PickerObserverArgument, Chr(34))' . "`n"
		. 'throw Error("The private native observer argument cannot contain a quote")' . "`n"
		. 'PickerObserverCommand .= (PickerObserverCommand == "" ? "" : " ") . Chr(34) . PickerObserverArgument . Chr(34)' . "`n"
		. '}' . "`n"
		. 'PickerObserverHandle := ComObject("WScript.Shell").Exec(PickerObserverCommand)' . "`n"
		. 'try {' . "`n"
		. 'PickerObserverStarted := A_TickCount' . "`n"
		. 'while PickerObserverHandle.Status == 0 && ((A_TickCount - PickerObserverStarted) & 0xFFFFFFFF) < _NFPObserverBudgetMs' . "`n"
		. 'Sleep(10)' . "`n"
		. 'if PickerObserverHandle.Status == 0 {' . "`n"
		. 'PickerObserverPhase := FileExist(PickerObserverReceipt . ".phase") ? SubStr(FileRead(PickerObserverReceipt . ".phase", "UTF-8"), 1, 128) : "not-started"' . "`n"
		. 'throw Error("The exact owned UIA client did not finish within its bounded observation window (" . _NFPMode . ", " . PickerObserverPhase . ")")' . "`n"
		. '}' . "`n"
		. 'PickerObserverExit := PickerObserverHandle.ExitCode' . "`n"
		. 'PickerObserverOutput := PickerObserverHandle.StdOut.ReadAll()' . "`n"
		. 'PickerObserverErrors := PickerObserverHandle.StdErr.ReadAll()' . "`n"
		. 'if PickerObserverErrors != ""' . "`n"
		. 'throw Error("The owned UIA client reported unexpected stderr: " . PickerObserverErrors)' . "`n"
		. 'PickerObserverFailure := FileRead(PickerObserverReceipt . ".failure", "UTF-8")' . "`n"
		. 'if PickerObserverExit != 0 {' . "`n"
		. 'if PickerObserverOutput != ""' . "`n"
		. 'throw Error("The failing owned UIA client reported unexpected stdout: " . PickerObserverOutput)' . "`n"
		. 'throw Error(PickerObserverFailure == "" ? "The owned native observer failed before its receipt" : PickerObserverFailure)' . "`n"
		. '}' . "`n"
		. 'if PickerObserverOutput != "owned-filter-observed" || PickerObserverFailure != ""' . "`n"
		. 'throw Error("The owned UIA client must acknowledge exact successful completion without warnings")' . "`n"
		. 'if FileRead(PickerObserverReceipt . ".ack", "UTF-8") != "owned-filter-observed"' . "`n"
		. 'throw Error("The distinct native observer must acknowledge exact completion")' . "`n"
		. '} finally {' . "`n"
		. 'if PickerObserverHandle.Status == 0 {' . "`n"
		. 'PickerObserverHandle.Terminate()' . "`n"
		. 'if PickerObserverHandle.Status == 0' . "`n"
		. 'throw Error("The exact owned UIA client did not acknowledge termination")' . "`n"
		. '}' . "`n"
		. '}' . "`n"
}


/**
 * Extends the actual file probe without changing its original independent case.
 * Each edit has one exact source boundary, and every native delegate is retained.
 * @param {string} Artifact - Privately generated shared caption policy.
 * @param {string} Owner - Actual public native caption delegate.
 * @param {string} Observer - The separately executed owned UIA client.
 * @returns {string} Complete native picker with genuine filter behavior checks.
 */
_NDT_FileFilterBehaviorProbeSource(Artifact, Owner, Observer) {
	FilterBudgets := _NDT_FileFilterBudgets()
	BehaviorSource := _NDT_FilePickerProbeSource(Artifact, Owner)
	BehaviorSource := StrReplace(BehaviorSource, 'global _NFPMode := ""',
		'global _NFPMode := ""' . "`n"
			. 'global _NFPObserverBudgetMs := ' . FilterBudgets.ObserverMs . "`n"
			. 'global _NFPViewWaitMs := ' . FilterBudgets.ViewWaitMs . "`n"
			. 'global _NFPUiaTimeoutMs := ' . FilterBudgets.UiaTimeoutMs, , &BudgetBoundaries)
	AssertEqual(1, BudgetBoundaries, "the native picker owns one complete derived observer budget")
	BehaviorSource := StrReplace(BehaviorSource, 'global _NFPOwnedFile := _NFPRoot . "\selected.txt"',
		'DirCreate(_NFPRoot . "\items")' . "`n"
			. 'global _NFPOwnedFile := _NFPRoot . "\items\visible-filter-owned.txt"' . "`n"
			. 'global _NFPBinFile := _NFPRoot . "\items\hidden-filter-owned.bin"' . "`n"
			. 'global _NFPLastHwnd := 0' . "`n"
			. 'global _NFPObserverPath := ' . Chr(34) . StrReplace(Observer, Chr(96), Chr(96) . Chr(96)) . Chr(34) . "`n"
			. 'FileAppend("Owned binary fixture", _NFPBinFile, "UTF-8-RAW")', , &FixtureBoundaries)
	AssertEqual(1, FixtureBoundaries, "the genuine filter proof adds one distinct controlled binary file")
	BehaviorSource := StrReplace(BehaviorSource, 'global _NFPRoot, _NFPMode',
		'global _NFPRoot, _NFPMode, _NFPOwnedFile, _NFPBinFile, _NFPLastHwnd, _NFPObserverPath, _NFPObserverBudgetMs, _NFPViewWaitMs, _NFPUiaTimeoutMs', , &CallbackBoundaries)
	AssertEqual(1, CallbackBoundaries, "the capture owns its exact file and observer state")
	ObserverBoundary := 'SetTimer(_NFPCapture, 0)' . "`n" . 'if _NFPMode == "selected" {'
	BehaviorSource := StrReplace(BehaviorSource, ObserverBoundary,
		'if _NFPMode != "baseline" {' . "`n" . _NDT_FileFilterCaptureSource() . '}' . "`n" . ObserverBoundary, , &ObserverBoundaries)
	AssertEqual(1, ObserverBoundaries, "the real view is queried once before either native action")
	for ResultMode in ["Selected", "Cancelled"] {
		RetirementBoundary := 'FileAppend(_NFPSelected, _NFPRoot . "\selected.result", "UTF-8-RAW")'
		if ResultMode == "Cancelled"
			RetirementBoundary := 'FileAppend(Type(_NFPCancelled) . "|" . (_NFPCancelled is Array ? _NFPCancelled.Length : "wrong-shape"), _NFPRoot . "\cancelled.result", "UTF-8-RAW")'
		BehaviorSource := StrReplace(BehaviorSource, RetirementBoundary,
			'if !_NFPLastHwnd || DllCall("IsWindow", "Ptr", _NFPLastHwnd)' . "`n"
				. 'throw Error("The exact observed native file dialog must retire before persistence")' . "`n"
				. 'FileAppend("retired", _NFPRoot . "\" . _NFPMode . ".retirement", "UTF-8-RAW")' . "`n"
				. RetirementBoundary, , &RetirementBoundaries)
		AssertEqual(1, RetirementBoundaries, "each original modal return precedes its exact HWND retirement receipt")
	}
	return BehaviorSource
}


/**
 * Qualifies both real modal results after the observer has retired independently.
 * The no-filter mutation runs only after all five genuine policy cases complete.
 */
_NDT_CheckFileFilterBehaviorPolicy(Index, Spec, Fixture, Artifact, Owner, Ownership) {
	FilterBudgets := _NDT_FileFilterBudgets()
	FilterRoot := Fixture . "\file_behavior"
	DirCreate(FilterRoot)
	FilterObserver := FilterRoot . "\observer.ahk"
	FileAppend(_NDT_FileFilterObserverSource(_NDT_FileFilterUiaOwner()), FilterObserver, "UTF-8")
	FilterHarness := FilterRoot . "\file_behavior.ahk"
	FilterSource := _NDT_FileFilterBehaviorProbeSource(Artifact, Owner, FilterObserver)
	FileAppend(FilterSource, FilterHarness, "UTF-8")
	AssertEqual("file-picker-written", _NDT_RunChild(A_AhkPath,
		["/ErrorStdOut", FilterHarness, FilterRoot], Ownership, 0, FilterBudgets.ChildMs),
		"genuine native filtering completes without hidden observer errors")
	for FilterKind in ["selected", "cancelled"] {
		AssertEqual(Spec.Expected, FileRead(FilterRoot . "\" . FilterKind . ".title", "UTF-8"),
			"genuine native filter observations preserve caption policy " . Index)
		AssertEqual("txt-visible|bin-hidden|all-files-bin-visible|restored-txt-visible|restored-bin-hidden|separate-client|owner-fenced",
			FileRead(FilterRoot . "\" . FilterKind . ".observer.behavior", "UTF-8"),
			"the exact shell-view file items prove both restricted and native All Files behavior")
		AssertEqual("retired", FileRead(FilterRoot . "\" . FilterKind . ".retirement", "UTF-8"),
			"each exact observed native picker retires before persistence")
	}
	AssertEqual(FileRead(FilterRoot . "\owned.path", "UTF-8"),
		FileRead(FilterRoot . "\selected.result", "UTF-8"), "genuine filtering preserves the exact selected TXT path")
	AssertEqual("Array|0", FileRead(FilterRoot . "\cancelled.result", "UTF-8"),
		"genuine native filtering preserves multiselect cancellation")
	if Index != 5
		return
	LabelMutationRoot := Fixture . "\filter_label_mutation"
	DirCreate(LabelMutationRoot)
	LabelMutationHarness := LabelMutationRoot . "\changed_label.ahk"
	FileAppend(_NDT_MutateDelegatedFilter(FilterSource, "Changed label (*.txt)"), LabelMutationHarness, "UTF-8")
	AssertEqual("The native friendly names must match independently observed SetFileTypes labels",
		_NDT_RunChild(A_AhkPath, ["/ErrorStdOut", LabelMutationHarness, LabelMutationRoot], Ownership, 2, FilterBudgets.ChildMs),
		"changing only delegated friendly labels must fail against the untouched native baseline")
	MutationRoot := Fixture . "\unfiltered_mutation"
	DirCreate(MutationRoot)
	MutationSource := _NDT_MutateDelegatedFilter(FilterSource, "")
	MutationHarness := MutationRoot . "\unfiltered.ahk"
	FileAppend(MutationSource, MutationHarness, "UTF-8")
	AssertEqual("Owned BIN visible under the restricted file filter", _NDT_RunChild(A_AhkPath,
		["/ErrorStdOut", MutationHarness, MutationRoot], Ownership, 2, FilterBudgets.ChildMs),
		"removing the real native filter must expose the controlled BIN rather than pass vacuously")
}


/**
 * Derives process bounds from three independently settling native view transitions.
 * Each filename has at most two shell spellings. A visible spelling requires
 * FindElements, ProcessId and IsOffscreen; absence only requires FindElements.
 * A final synchronous query can cross its polling deadline, so its complete
 * request bound belongs to the outer owner. Modal setup keeps its existing bound.
 * @returns {object} Canonical per-query, per-transition and process bounds.
 */
_NDT_FileFilterBudgets() {
	UiaTimeoutMs := 500
	ViewWaitMs := 4000
	ShellSpellings := 2
	VisibleCalls := ShellSpellings * 3
	AbsentCalls := ShellSpellings
	TransitionCalls := VisibleCalls * 2 + VisibleCalls + AbsentCalls
	SetupCalls := 2
	ObserverMs := 3 * ViewWaitMs + (TransitionCalls + AbsentCalls + SetupCalls) * UiaTimeoutMs
	return {UiaTimeoutMs: UiaTimeoutMs, ViewWaitMs: ViewWaitMs, ObserverMs: ObserverMs,
		ChildMs: 15000 + 2 * ObserverMs}
}


/** Mutates only the public delegate filter, leaving its native baseline intact. */
_NDT_MutateDelegatedFilter(ProbeSource, Replacement) {
	for NativeOptions in ["35", '"M35"'] {
		Boundary := 'Ui_FileSelect(' . NativeOptions . ', _NFPOwnedFile, "Navigation layer", "Owned files (*.txt)")'
		Changed := 'Ui_FileSelect(' . NativeOptions . ', _NFPOwnedFile, "Navigation layer", "' . Replacement . '")'
		ProbeSource := StrReplace(ProbeSource, Boundary, Changed, , &Mutations)
		AssertEqual(1, Mutations, "each public delegate filter mutation has one exact call boundary")
	}
	return ProbeSource
}


/**
 * Captures real SHBrowseForFolderW captions, body and option-dependent controls.
 * Persistence follows actual modal completion, preserving strict HWND retirement.
 * @param {string} Artifact - Privately generated shared title policy.
 * @param {string} Owner - Actual native dialog and folder callback owner.
 * @returns {string} Complete private native folder probe.
 */
_NDT_FolderPickerProbeSource(Artifact, Owner) {
		return '#Requires AutoHotkey v2.0' . "`n"
		. '#SingleInstance Off' . "`n"
		. '#Warn All, StdOut' . "`n"
		. 'OnError(_NDFFailure)' . "`n"
		. 'global _NDFRoot := A_Args[1]' . "`n"
		. 'global _NDFMode := ""' . "`n"
		. 'global _NDFSnapshot := 0' . "`n"
		. '_NDFFolder := _NDFRoot . "\owned_folder"' . "`n"
		. 'DirCreate(_NDFFolder)' . "`n"
		. '_NDFCanonicalBuffer := Buffer(65536, 0)' . "`n"
		. '_NDFCanonicalLength := DllCall("GetLongPathNameW", "Str", _NDFFolder, "Ptr", _NDFCanonicalBuffer, "UInt", 32768, "UInt")' . "`n"
		. 'if !_NDFCanonicalLength || _NDFCanonicalLength >= 32768' . "`n"
		. 'throw Error("The privately owned folder must resolve")' . "`n"
		. '_NDFFolder := StrGet(_NDFCanonicalBuffer, _NDFCanonicalLength, "UTF-16")' . "`n"
		. 'FileAppend(_NDFFolder, _NDFRoot . "\owned.path", "UTF-8-RAW")' . "`n"
		. '_NDFMode := "selected"' . "`n"
		. 'SetTimer(_NDFCapture, 20)' . "`n"
		. '_NDFSelected := Ui_DirSelect("*" . _NDFFolder, 1, "ErgoptiPlus — preserved folder body", "Navigation layer", 0)' . "`n"
		. 'SetTimer(_NDFCapture, 0)' . "`n"
		. '_NDFPersist()' . "`n"
		. 'FileAppend(_NDFSelected, _NDFRoot . "\selected.result", "UTF-8-RAW")' . "`n"
		. '_NDFMode := "cancelled"' . "`n"
		. 'SetTimer(_NDFCapture, 20)' . "`n"
		. '_NDFCancelled := Ui_DirSelect("*" . _NDFFolder, 3, "ErgoptiPlus — preserved folder body", "Navigation layer", 0)' . "`n"
		. 'SetTimer(_NDFCapture, 0)' . "`n"
		. '_NDFPersist()' . "`n"
		. 'FileAppend(Type(_NDFCancelled) . "|" . _NDFCancelled, _NDFRoot . "\cancelled.result", "UTF-8-RAW")' . "`n"
		. 'FileAppend("folders-written", "*", "UTF-8-RAW")' . "`n"
		. 'ExitApp(0)' . "`n"
		. '_NDFCapture() {' . "`n"
		. 'global _NDFMode, _NDFSnapshot' . "`n"
		. 'for FolderHwnd in WinGetList("ahk_pid " . DllCall("GetCurrentProcessId", "UInt")) {' . "`n"
		. 'if FolderHwnd == A_ScriptHwnd || !DllCall("IsWindowVisible", "Ptr", FolderHwnd)' . "`n"
		. 'continue' . "`n"
		. 'Lease := DllCall("GetPropW", "Ptr", FolderHwnd, "Str", "NativeFolderPickerLease", "Ptr")' . "`n"
		. 'if !Lease' . "`n"
		. 'continue' . "`n"
		. 'ConfirmButton := DllCall("GetDlgItem", "Ptr", FolderHwnd, "Int", 1, "Ptr")' . "`n"
		. 'if !ConfirmButton || !DllCall("IsWindowEnabled", "Ptr", ConfirmButton)' . "`n"
		. 'continue' . "`n"
		. 'Caption := WinGetTitle("ahk_id " . FolderHwnd)' . "`n"
		. 'Body := WinGetText("ahk_id " . FolderHwnd)' . "`n"
		. 'EditCount := 0' . "`n"
		. 'for FolderControlHwnd in WinGetControlsHwnd("ahk_id " . FolderHwnd) {' . "`n"
		. 'if WinGetClass("ahk_id " . FolderControlHwnd) == "Edit" && DllCall("IsWindowVisible", "Ptr", FolderControlHwnd)' . "`n"
		. 'EditCount += 1' . "`n"
		. '}' . "`n"
		. '_NDFSnapshot := {Hwnd: FolderHwnd, Caption: Caption, Body: Body, Lease: Lease, Edits: EditCount}' . "`n"
		. 'SetTimer(_NDFCapture, 0)' . "`n"
		. 'if _NDFMode == "selected"' . "`n"
		. 'PostMessage(0xF5, 0, 0, , "ahk_id " . ConfirmButton)' . "`n"
		. 'else' . "`n"
		. 'PostMessage(0x10, 0, 0, , "ahk_id " . FolderHwnd)' . "`n"
		. 'return' . "`n"
		. '}' . "`n"
		. '}' . "`n"
		. '_NDFPersist() {' . "`n"
		. 'global _NDFRoot, _NDFMode, _NDFSnapshot' . "`n"
		. 'if !IsObject(_NDFSnapshot)' . "`n"
		. 'throw Error("The actual native folder must publish its caption and body")' . "`n"
		. 'CapturedFolder := _NDFSnapshot' . "`n"
		. 'FileAppend(CapturedFolder.Caption, _NDFRoot . "\" . _NDFMode . ".title", "UTF-8-RAW")' . "`n"
		. 'FileAppend(CapturedFolder.Body, _NDFRoot . "\" . _NDFMode . ".body", "UTF-8-RAW")' . "`n"
		. 'FileAppend(CapturedFolder.Lease, _NDFRoot . "\" . _NDFMode . ".lease", "UTF-8-RAW")' . "`n"
		. 'FileAppend(CapturedFolder.Edits, _NDFRoot . "\" . _NDFMode . ".edits", "UTF-8-RAW")' . "`n"
		. 'FileAppend(DllCall("IsWindow", "Ptr", CapturedFolder.Hwnd) ? "live" : "retired", _NDFRoot . "\" . _NDFMode . ".retirement", "UTF-8-RAW")' . "`n"
		. '_NDFSnapshot := 0' . "`n"
		. '}' . "`n"
		. '_NDFFailure(FolderProbeError, *) {' . "`n"
		. 'FileAppend(FolderProbeError.Message, "*", "UTF-8-RAW")' . "`n"
		. 'ExitApp(2)' . "`n"
		. '}' . "`n"
		. '#Include ' . Artifact . "`n"
		. '#Include ' . Owner . "`n"
}

/** Returns fresh independent expected captions for every supported policy variant. */
_NDT_PolicyCases() {
	return [
		{Prefix: "ErgoptiPlus", Separator: " — ", Expected: "ErgoptiPlus — Navigation layer"},
		{Prefix: "", Separator: " — ", Expected: "Navigation layer"},
		{Prefix: "Other product", Separator: ": ", Expected: "Other product: Navigation layer"},
		{Prefix: 'Quoted "product" ``name``', Separator: "", Expected: 'Quoted "product" ``name``Navigation layer'},
		{Prefix: "Other `; product", Separator: " `; ", Expected: "Other `; product `; Navigation layer"}
	]
}


/**
 * Owns generated artifacts and exact child retirement for one native UI family.
 * @param {string} Family - Distinct privately owned fixture namespace.
 * @param {Func} CheckPolicy - Performs every original assertion for one policy.
 */
_NDT_RunPolicyFamily(Family, CheckPolicy) {
	global _StaticDir
	Root := A_Temp . "\ergopti_native_" . Family . "_" . A_ScriptHwnd . "_" . A_TickCount
	AssertFalse(DirExist(Root), "the native-dialog fixture must be privately owned")
	DirCreate(Root)
	Ownership := {CanRetire: true}
	Cases := _NDT_PolicyCases()
	try {
		Policies := "["
		for Index, Spec in Cases {
			if Index > 1
				Policies .= ","
			Policies .= '{"prefix":' . JsonStringLiteral(Spec.Prefix)
				. ',"separator":' . JsonStringLiteral(Spec.Separator) . '}'
		}
		FileAppend(Policies . "]", Root . "\policies.json", "UTF-8-RAW")
		Bootstrap := Root . "\generate.cjs"
		FileAppend('const fs = require("node:fs"); const path = require("node:path");' . "`n"
			. 'const root = process.argv[2]; const generator = require(process.argv[3]);' . "`n"
			. 'const policies = require(path.join(root, "policies.json"));' . "`n"
			. 'for (const [index, policy] of policies.entries()) {' . "`n"
			. 'const target = path.join(root, String(index + 1)); const source = path.join(target, generator.SOURCE);' . "`n"
			. 'fs.mkdirSync(path.dirname(source), {recursive:true});' . "`n"
			. 'fs.writeFileSync(source, JSON.stringify({window_title:policy, apps:{}}));' . "`n"
			. 'generator.main(target); } process.stdout.write(String(policies.length));' . "`n",
			Bootstrap, "UTF-8-RAW")
		Generator := _StaticDir . "\..\tools\codegen\codegen-window-titles.cjs"
		AssertEqual("5", _NDT_RunChild("node.exe", [Bootstrap, Root, Generator], Ownership),
			"the actual generator owns every private dialog policy")
		Owner := _NDT_NativeDialogOwner()
		for Index, Spec in Cases {
			Fixture := Root . "\" . Index
			Artifact := Fixture . "\static\ergopti_plus\windows\_generated\window_titles.ahk"
			CheckPolicy.Call(Index, Spec, Fixture, Artifact, Owner, Ownership)
		}
	} finally {
		if Ownership.CanRetire
			DirDelete(Root, true)
	}
}


/** Preserves all actual message/input, timeout and expired-read assertions. */
_NDT_CheckDialogPolicy(Index, Spec, Fixture, Artifact, Owner, Ownership) {
	Harness := Fixture . "\native_dialogs.ahk"
	FileAppend(_NDT_ProbeSource(Artifact, Owner), Harness, "UTF-8")
	AssertEqual("dialogs-written", _NDT_RunChild(A_AhkPath,
		["/ErrorStdOut", Harness, Fixture, Index == 1 ? "delay" : "immediate"], Ownership), "native dialogs acknowledge private receipts with ASCII stdout")
	for Kind in ["message", "input", "unnamed", "cancelled"] {
		Caption := Fixture . "\" . Kind . ".title"
		Body := Fixture . "\" . Kind . ".body"
		AssertTrue(FileExist(Caption), "an actual visible native " . Kind . " window was captured")
		Expected := Kind == "unnamed" ? Spec.Prefix : Spec.Expected
		AssertEqual(Expected, FileRead(Caption, "UTF-8"),
			"actual " . Kind . " caption follows independent private policy " . Index)
		Assert(InStr(FileRead(Body, "UTF-8"), "Preserved " . Kind . " body") > 0,
			"branding never changes the native dialog body")
	}
	AssertEqual("Timeout", FileRead(Fixture . "\message.result", "UTF-8"),
		"message button/options forwarding preserves the native timeout result")
	if Index == 1 {
		AssertEqual("retired", FileRead(Fixture . "\message.retirement", "UTF-8"),
			"native observations survive persistence after the exact dialog has timed out")
		; Move one native read across the actual modal completion boundary.
		; The same T0.5 result acknowledges retirement before persistence,
		; so the original target exception must reject the independent read.
		MutantRoot := Fixture . "\expired_read"
		DirCreate(MutantRoot)
		Mutant := StrReplace(_NDT_ProbeSource(Artifact, Owner),
			'Captured := _NDTSnapshot',
			'Captured := _NDTSnapshot' . "`n"
				. 'if InStr(_NDTReceipt, "\message")' . "`n"
				. 'WinGetText("ahk_id " . Captured.Hwnd)', , &Mutations)
		AssertEqual(1, Mutations, "the expiry mutation changes one exact native observation")
		MutantHarness := MutantRoot . "\expired_read.ahk"
		FileAppend(Mutant, MutantHarness, "UTF-8")
		AssertEqual("Target window not found.", _NDT_RunChild(A_AhkPath,
			["/ErrorStdOut", MutantHarness, MutantRoot, "immediate"], Ownership, 2),
			"the independent expired-window mutation reproduces the original rejected target query")
	}
	AssertEqual("yes|no|7", FileRead(Fixture . "\message.buttons", "UTF-8"),
		"the native message retains Yes/No buttons and the second default button")
	AssertEqual("Timeout`n Secret value ", FileRead(Fixture . "\input.result", "UTF-8"),
		"password/size/timeout forwarding preserves result and exact default text")
	AssertEqual("password", FileRead(Fixture . "\input.password", "UTF-8"),
		"the actual native input control preserves password masking")
	AssertEqual("Timeout", FileRead(Fixture . "\unnamed.result", "UTF-8"),
		"an omitted caption preserves native options and return values")
	AssertEqual("Cancel`n Secret value ", FileRead(Fixture . "\cancelled.result", "UTF-8"),
		"closing the native input window preserves cancellation and exact entered text")
}


/** Preserves all actual file captions, filters, selection and cancellation assertions. */
_NDT_CheckFilePickerPolicy(Index, Spec, Fixture, Artifact, Owner, Ownership) {
	PickerRoot := Fixture . "\file_picker"
	DirCreate(PickerRoot)
	PickerHarness := PickerRoot . "\file_picker.ahk"
	FileAppend(_NDT_FilePickerProbeSource(Artifact, Owner), PickerHarness, "UTF-8")
	AssertEqual("file-picker-written", _NDT_RunChild(A_AhkPath,
		["/ErrorStdOut", PickerHarness, PickerRoot], Ownership),
		"the actual native file picker completes without hidden errors")
	AssertEqual("String|", FileRead(PickerRoot . "\baseline.result", "UTF-8"),
		"the independently observed direct native baseline cancels with its original String result")
	AssertContains(FileRead(PickerRoot . "\baseline.types", "UTF-8"), "items=2,truncated=0,selected=1|",
		"the direct native baseline contains exactly two filters and selects the first")
	for Kind in ["selected", "cancelled"] {
		AssertEqual(Spec.Expected, FileRead(PickerRoot . "\" . Kind . ".title", "UTF-8"),
			"the real file picker caption follows independent policy " . Index)
		; Windows renders the native friendly name and pattern together.
		; Compare exact native observations against the direct built-in baseline.
		AssertEqual(FileRead(PickerRoot . "\baseline.filter", "UTF-8"),
			FileRead(PickerRoot . "\" . Kind . ".filter", "UTF-8"),
			"the actual native picker retains the exact friendly labels (" . Kind
				. ", policy " . Index . ", owned HWND control classes/IDs: "
				. FileRead(PickerRoot . "\" . Kind . ".controls", "UTF-8")
				. "; owned file-type ComboBox items/selection: "
				. FileRead(PickerRoot . "\" . Kind . ".types", "UTF-8") . ")")
		AssertEqual(FileRead(PickerRoot . "\baseline.types", "UTF-8"),
			FileRead(PickerRoot . "\" . Kind . ".types", "UTF-8"),
			"the owned native file-type control selects the supplied friendly name")
	}
	AssertEqual(FileRead(PickerRoot . "\owned.path", "UTF-8"),
		FileRead(PickerRoot . "\selected.result", "UTF-8"),
		"native options, initial file and default name select the exact privately owned path")
	AssertEqual("Array|0", FileRead(PickerRoot . "\cancelled.result", "UTF-8"),
		"multiselect cancellation retains the original empty native Array shape")
}


/** Preserves all actual folder captions, controls, leases and retirement assertions. */
_NDT_CheckFolderPickerPolicy(Index, Spec, Fixture, Artifact, Owner, Ownership) {
	FolderRoot := Fixture . "\folder_picker"
	DirCreate(FolderRoot)
	FolderHarness := FolderRoot . "\folder_picker.ahk"
	FileAppend(_NDT_FolderPickerProbeSource(Artifact, Owner), FolderHarness, "UTF-8")
	AssertEqual("folders-written", _NDT_RunChild(A_AhkPath,
		["/ErrorStdOut", FolderHarness, FolderRoot], Ownership),
		"actual folder callbacks complete without hidden errors")
	for Kind in ["selected", "cancelled"] {
		AssertEqual(Spec.Expected, FileRead(FolderRoot . "\" . Kind . ".title", "UTF-8"),
			"the real folder caption follows independent shared policy " . Index)
		Assert(InStr(FileRead(FolderRoot . "\" . Kind . ".body", "UTF-8"),
			"ErgoptiPlus — preserved folder body") > 0, "caption changes never rewrite the explanatory folder body")
		Assert(Integer(FileRead(FolderRoot . "\" . Kind . ".lease", "UTF-8")) > 0,
			"the visible native folder carries its exact initialization lease")
		AssertEqual("retired", FileRead(FolderRoot . "\" . Kind . ".retirement", "UTF-8"),
			"native selection and cancellation acknowledge actual modal HWND retirement")
	}
	AssertEqual(FileRead(FolderRoot . "\owned.path", "UTF-8"),
		FileRead(FolderRoot . "\selected.result", "UTF-8"),
		"initial-only navigation selects the exact independently canonical native folder")
	AssertEqual("String|", FileRead(FolderRoot . "\cancelled.result", "UTF-8"),
		"folder cancellation preserves its original empty String result")
	AssertEqual("0", FileRead(FolderRoot . "\selected.edits", "UTF-8"),
		"option1 retains the native dialog without an edit box")
	Assert(Integer(FileRead(FolderRoot . "\cancelled.edits", "UTF-8")) > 0,
		"option3 retains the native edit-box control")
}


/** Actual message/input qualification remains independent of either picker. */
_NDT_ActualNativeCaptionsAndResults() {
	_NDT_RunPolicyFamily("dialogs", _NDT_CheckDialogPolicy)
}
Test("native dialogs: actual captions and results follow customized shared policy (shared-window-titles)",
	_NDT_ActualNativeCaptionsAndResults)


/** An exact file-filter refusal cannot prevent the real folder family from running. */
_NDT_ActualNativeFilePickerCaptionsAndResults() {
	_NDT_RunPolicyFamily("file_picker", _NDT_CheckFilePickerPolicy)
}
Test("native file picker: actual captions, filters and results follow customized shared policy (shared-window-titles)",
	_NDT_ActualNativeFilePickerCaptionsAndResults)


/** The independent behavioral family runs even if the original label assertion fails. */
_NDT_ActualNativeFileFilterBehavior() {
	_NDT_RunPolicyFamily("file_filter_behavior", _NDT_CheckFileFilterBehaviorPolicy)
}
Test("native file filter: real shell items and All Files expose a no-filter mutation (shared-window-titles)",
	_NDT_ActualNativeFileFilterBehavior)


/** Every folder policy executes through the actual owned SHBrowseForFolderW ABI. */
_NDT_ActualNativeFolderPickerCaptionsAndResults() {
	_NDT_RunPolicyFamily("folder_picker", _NDT_CheckFolderPickerPolicy)
}
Test("native folder picker: actual captions, leases and retirement follow customized shared policy (shared-window-titles)",
	_NDT_ActualNativeFolderPickerCaptionsAndResults)



/**
 * Records the actual folder ABI orchestration without performing desktop I/O.
 * Failures are observed outside production callback exception boundaries.
 */
class _NDF_Port {
	__New() {
		this.Events := []
		this.Failure := ""
		this.Selected := true
		this.Alive := false
		this.Lease := 0
		this.Callback := 0
		this.SeenPrompt := ""
		this.SeenInitial := ""
		this.SeenCaption := ""
		this.SeenRoot := ""
		this.SeenFlags := -1
		this.SeenOwner := -1
		this.Validation := -1
	}
	InitCom() {
		this.Events.Push("com.acquire")
		return this.Failure == "com" ? -1 : 0
	}
	ReleaseCom() {
		this.Events.Push("com.release")
	}
	ProcessId() {
		return 11
	}
	ThreadId() {
		return 12
	}
	ExistsWindow(Hwnd) {
		return Hwnd == 77 && this.Alive
	}
	MatchesWindow(Hwnd, ProcessId, ThreadId) {
		return this.ExistsWindow(Hwnd) && ProcessId == 11 && ThreadId == 12
	}
	ClaimWindow(Hwnd, Cookie) {
		this.Events.Push("window.claim")
		if this.Lease
			return false
		this.Lease := Cookie
		return true
	}
	OwnsWindow(Hwnd, Cookie) {
		return this.ExistsWindow(Hwnd) && this.Lease == Cookie
	}
	ParseRoot(Path, &Pidl) {
		this.Events.Push("root.parse")
		this.SeenRoot := Path
		Pidl := 101
		if this.Failure == "root"
			throw Error("injected root refusal")
		return 0
	}
	FreePidl(Pidl) {
		this.Events.Push("pidl.free." . Pidl)
		if this.Failure == "release" && Pidl == 202
			throw Error("injected selected-PIDL release refusal")
	}
	MakeCallback(Function) {
		this.Events.Push("callback.acquire")
		if this.Failure == "callback"
			return 0
		this.Callback := Function
		return 303
	}
	FreeCallback(Address) {
		this.Events.Push("callback.free." . Address)
		this.Callback := 0
	}
	Browse(Info) {
		this.Events.Push("modal.enter")
		this.SeenOwner := NumGet(Info, 0, "Ptr")
		this.SeenFlags := NumGet(Info, A_PtrSize * 4, "UInt")
		this.SeenPrompt := StrGet(NumGet(Info, A_PtrSize * 3, "Ptr"), "UTF-16")
		Cookie := NumGet(Info, A_PtrSize * 6, "Ptr")
		this.Alive := true
		this.Callback.Call(77, 1, 0, Cookie)
		this.Validation := this.Callback.Call(77, 4, 0, Cookie)
		this.Alive := false
		this.Events.Push("modal.retired")
		return this.Selected ? 202 : 0
	}
	SetCaption(Hwnd, Caption) {
		this.Events.Push("caption.set")
		this.SeenCaption := Caption
		return this.Failure != "caption"
	}
	SetInitial(Hwnd, Initial) {
		this.Events.Push("initial.set")
		this.SeenInitial := Initial
	}
	Close(Hwnd) {
		this.Events.Push("modal.cancel")
		return true
	}
	PathFromPidl(Pidl) {
		this.Events.Push("path.project." . Pidl)
		return "C:\owned\selected"
	}
}

/**
 * Retains a production refusal, then asserts it outside the caught action.
 * @param {Func} Action - The actual native folder orchestration call.
 * @param {string} Needle - Independently expected refusal detail.
 */
_NDF_AssertRefused(Action, Needle) {
	Failure := 0
	try Action.Call()
	catch as Refusal {
		Failure := Refusal
	}
	AssertTrue(IsObject(Failure), "the native folder ownership violation must refuse")
	Assert(InStr(Failure.Message, Needle) > 0,
		"the native folder refusal retains its actual cause: " . Failure.Message)
}

/** Preserves exact root, explanatory body, options and resource-release receipts. */
_NDF_ActualOrchestration() {
	Port := _NDF_Port()
	Selected := _Ui_FolderSelect("C:\root * C:\initial ", 3, "ErgoptiPlus — preserved body", "Independent caption", 0, Port)
	AssertEqual("C:\owned\selected", Selected, "the exact native filesystem projection is returned")
	AssertEqual("C:\root", Port.SeenRoot, "one pre-asterisk separator is removed from the native root")
	AssertEqual(" C:\initial ", Port.SeenInitial, "literal initial-folder whitespace remains unchanged")
	AssertEqual("ErgoptiPlus — preserved body", Port.SeenPrompt, "branding never rewrites explanatory body text")
	AssertEqual("Independent caption", Port.SeenCaption, "the native caption receives its independent composed value")
	AssertEqual(0, Port.SeenOwner, "current unowned application dialogs preserve the explicit null owner")
	AssertEqual(0x50, Port.SeenFlags, "option3 keeps creation, edit box and the new dialog style")
	AssertEqual(1, Port.Validation, "invalid typed native paths keep the exact initialized dialog open")
	AssertEqual("com.acquire|root.parse|callback.acquire|modal.enter|window.claim|caption.set|initial.set|modal.retired|path.project.202|pidl.free.202|pidl.free.101|callback.free.303|com.release",
		ArrayJoin(Port.Events, "|"), "every acquired native resource settles after exact modal retirement")
	CancelPort := _NDF_Port()
	CancelPort.Selected := false
	AssertEqual("", _Ui_FolderSelect("*C:\initial", 1, "Body", "Caption", 0, CancelPort),
		"native cancellation preserves the original empty String result")
	AssertEqual(0x40, CancelPort.SeenFlags, "option1 retains creation and omits the edit-box flag")
	AssertEqual("", CancelPort.SeenRoot, "an initial-only path does not constrain the navigation root")
	AssertFalse(InStr(ArrayJoin(CancelPort.Events, "|"), "pidl.free.202"),
		"cancellation never releases a selection PIDL that was not acquired")
}
Test("native folder: actual ABI orchestration preserves prompt, selection and settlement", _NDF_ActualOrchestration)

/** Rejects invalid arguments before native acquisition and settles partial receipts. */
_NDF_RefusalAndSettlement() {
	for Arguments in [
		[Map(), 3, "Body", "Caption", 0],
		["", 8, "Body", "Caption", 0],
		["", 3, "Body", "Caption", -1],
		["", 3, "Body", "Caption", 88]
	] {
		Port := _NDF_Port()
		_NDF_AssertRefused(_Ui_FolderSelect.Bind(Arguments[1], Arguments[2], Arguments[3],
			Arguments[4], Arguments[5], Port), "native folder")
		AssertEqual(0, Port.Events.Length, "invalid inputs acquire no COM, PIDL or callback")
	}
	for Stage in ["com", "root", "callback", "caption", "release"] {
		Port := _NDF_Port()
		Port.Failure := Stage
		_NDF_AssertRefused(_Ui_FolderSelect.Bind("C:\root*Initial", 3, "Body", "Caption", 0, Port),
			Stage == "com" ? "COM apartment" : Stage == "caption" ? "shared caption"
				: Stage == "callback" ? "callback" : "refusal")
		Events := ArrayJoin(Port.Events, "|")
		if Stage != "com"
			Assert(InStr(Events, "com.release") > 0, "partial acquisitions still release their exact COM lease")
		if Stage != "com"
			Assert(InStr(Events, "pidl.free.101") > 0, "partial root PIDLs are retained and released even when parsing throws")
		if Stage == "caption" {
			Assert(InStr(Events, "modal.cancel") > 0, "caption refusal closes only its initialized native modal")
			AssertFalse(InStr(Events, "initial.set"), "a refused caption authorizes no later initial selection")
		}
		if Stage == "release" {
			Assert(InStr(Events, "callback.free.303") > 0, "one release refusal does not skip callback settlement")
			Assert(InStr(Events, "pidl.free.101") > 0, "one release refusal does not skip root-PIDL settlement")
		}
	}
}
Test("native folder: invalid inputs and partial native refusals retain strict receipts", _NDF_RefusalAndSettlement)

/** A foreign or recycled HWND cannot acquire a caption or authorize any close. */
_NDF_CallbackOwnership() {
	Port := _NDF_Port()
	Port.Alive := true
	State := { Native: Port, Process: 11, Thread: 12, Cookie: Buffer(A_PtrSize, 0),
		Active: true, Window: 0, Failure: 0, Caption: "Caption", Initial: "Initial",
		SelectedPidl: 202, RootPidl: 101, Callback: 303, CallbackFunction: 0, ComOwned: true }
	AssertEqual(0, _Ui_FolderCallback(State, 77, 1, 0, State.Cookie.Ptr + 1),
		"foreign initialization retains the native neutral callback result")
	AssertTrue(IsObject(State.Failure), "an incorrect invocation cookie is an owned refusal")
	AssertEqual(0, Port.Events.Length, "an incorrect cookie cannot retitle or cancel the foreign window")
	State.Failure := 0
	AssertEqual(0, _Ui_FolderCallback(State, 77, 1, 0, State.Cookie.Ptr),
		"the actual initialized window is claimed once")
	AssertEqual("Caption", Port.SeenCaption, "only the claimed invocation receives its caption")
	Port.Lease := State.Cookie.Ptr + 1
	Before := Port.Events.Length
	AssertEqual(0, _Ui_FolderCallback(State, 77, 4, 0, State.Cookie.Ptr),
		"a recycled HWND loses the previous folder lease")
	AssertEqual(Before, Port.Events.Length, "the new window lease authorizes no old-instance operation")
	Failures := _Ui_FolderSettle(State)
	AssertEqual(1, Failures.Length, "an unretired modal is a settlement refusal")
	AssertEqual(Before, Port.Events.Length, "a recycled HWND cannot be closed and its callback memory stays retained")
	AssertEqual(303, State.Callback, "unsafe retirement never frees the reachable native callback")
	AssertEqual(101, State.RootPidl, "unsafe retirement never frees the reachable root PIDL")
	AssertTrue(State.ComOwned, "unsafe retirement never releases the reachable COM apartment")
	Port.Alive := false
	AssertEqual(0, _Ui_FolderSettle(State).Length, "actual window retirement permits exact retained-resource cleanup")
	AssertEqual(0, State.Callback, "acknowledged retirement releases the native callback")
	AssertFalse(State.ComOwned, "acknowledged retirement releases the COM apartment")
	Before := Port.Events.Length
	AssertEqual(0, _Ui_FolderCallback(State, 77, 1, 0, State.Cookie.Ptr), "late retired callbacks do nothing")
	AssertEqual(Before, Port.Events.Length, "late callbacks cannot resurrect a retired owner")
}
Test("native folder: callback cookies and HWND leases reject foreign ownership", _NDF_CallbackOwnership)
