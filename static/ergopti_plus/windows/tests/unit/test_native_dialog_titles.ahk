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
 * @returns {string} Captured ASCII completion acknowledgement.
 */
_NDT_RunChild(Executable, Args, Ownership, ExpectedCode := 0) {
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
		while !Receipt.Calls && TickElapsed(Started) < 15000 {
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
		. 'for ControlHwnd in WinGetControlsHwnd("ahk_id " . Hwnd) {' . "`n"
		. 'ControlClass := WinGetClass("ahk_id " . ControlHwnd)' . "`n"
		. 'PickerControlCount += 1' . "`n"
		. 'if PickerControlCount <= 24 {' . "`n"
		. 'PickerControlId := DllCall("GetDlgCtrlID", "Ptr", ControlHwnd, "Int")' . "`n"
		. 'PickerControlShapes .= (PickerControlShapes == "" ? "" : "|") . SubStr(ControlClass, 1, 48) . ":" . PickerControlId' . "`n"
		. '}' . "`n"
		. 'if ControlClass != "ComboBox"' . "`n"
		. 'continue' . "`n"
		. 'for Item in ControlGetItems(ControlHwnd)' . "`n"
		. 'FilterDescription .= Item . "|"' . "`n"
		. '}' . "`n"
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
	for Kind in ["selected", "cancelled"] {
		AssertEqual(Spec.Expected, FileRead(PickerRoot . "\" . Kind . ".title", "UTF-8"),
			"the real file picker caption follows independent policy " . Index)
		Assert(InStr(FileRead(PickerRoot . "\" . Kind . ".filter", "UTF-8"), "Owned files (*.txt)") > 0,
			"the actual native picker retains the display label and filter pattern (" . Kind
				. ", policy " . Index . ", owned HWND control classes/IDs: "
				. FileRead(PickerRoot . "\" . Kind . ".controls", "UTF-8") . ")")
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
