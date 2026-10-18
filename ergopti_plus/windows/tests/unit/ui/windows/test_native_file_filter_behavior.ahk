; tests/unit/ui/windows/test_native_file_filter_behavior.ahk

; ==============================================================================
; MODULE: Native File Filter Behaviour
; DESCRIPTION:
; The real IFileDialog filter is observed through UIA in a distinct owned
; client: shell items and All Files expose the no-filter mutation, and
; failure receipts keep their phase and call site.
; ==============================================================================

#Requires AutoHotkey v2.0





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
		. 'ObserverInitialItems := _NFO_WaitVisible(ObserverElement, ObserverTxtNames, ObserverWindow, ObserverProcess, ObserverView, ObserverType, ObserverStarted, ObserverWaitMs)' . "`n"
		. 'ObserverItems := ControlGetItems(ObserverType)' . "`n"
		. 'if ControlGetIndex(ObserverType) != 1' . "`n"
		. 'throw Error("The owned picker must begin on its first file type")' . "`n"
		. 'if ObserverItems.Length == 1 && ObserverItems[1] == "All Files (*.*)" {' . "`n"
		. '_NFO_WaitVisible(ObserverElement, ObserverBinNames, ObserverWindow, ObserverProcess, ObserverView, ObserverType, ObserverStarted, ObserverWaitMs)' . "`n"
		. 'throw Error("Owned BIN visible under the restricted file filter")' . "`n"
		. '}' . "`n"
		. '_NFO_Phase("restricted-bin", ObserverPhaseStarted)' . "`n"
		. 'if _NFO_Visible(ObserverInitialItems, ObserverBinNames, ObserverProcess)' . "`n"
		. 'throw Error("Owned BIN visible under the restricted file filter")' . "`n"
		. 'if ObserverItems.Length != 2 || ObserverItems[1] != ObserverExpectedItems[1] || ObserverItems[2] != ObserverExpectedItems[2]' . "`n"
		. 'throw Error("The native friendly names must match independently observed SetFileTypes labels")' . "`n"
		. 'ObserverInitialItems := 0' . "`n"
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
		. 'ObserverRestoredItems := ObserverElement.FindElements([{Type: "ListItem"}, {Type: "DataItem"}])' . "`n"
		. 'if ControlGetIndex(ObserverType) == 1 && _NFO_Visible(ObserverRestoredItems, ObserverTxtNames, ObserverProcess) && !_NFO_Visible(ObserverRestoredItems, ObserverBinNames, ObserverProcess)' . "`n"
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
		. '_NFO_Visible(OwnerItems, OwnerNames, OwnerProcess) {' . "`n"
		. 'for OwnerName in OwnerNames {' . "`n"
		. 'OwnerMatches := []' . "`n"
		. 'for OwnerCandidate in OwnerItems {' . "`n"
		. 'if OwnerCandidate.Name == OwnerName' . "`n"
		. 'OwnerMatches.Push(OwnerCandidate)' . "`n"
		. '}' . "`n"
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
		. 'OwnerItems := OwnerElement.FindElements([{Type: "ListItem"}, {Type: "DataItem"}])' . "`n"
		. 'if _NFO_Visible(OwnerItems, OwnerNames, OwnerProcess)' . "`n"
		. 'return OwnerItems' . "`n"
		. 'if ((A_TickCount - ObserverStarted) & 0xFFFFFFFF) >= ObserverWaitMs' . "`n"
		. 'throw Error("An exact owned file item did not become visible in the native shell view")' . "`n"
		. 'Sleep(10)' . "`n"
		. '}' . "`n"
		. '}' . "`n"
		. '_NFO_Error(ObserverFailure, *) {' . "`n"
		. 'ObserverErrorText := ObserverFailure.Message' . "`n"
		. 'if ObserverFailure is OSError {' . "`n"
		. 'ObserverErrorPhase := "not-started"' . "`n"
		. 'try {' . "`n"
		. 'if FileExist(A_Args[1] . ".phase")' . "`n"
		. 'ObserverErrorPhase := SubStr(FileRead(A_Args[1] . ".phase", "UTF-8"), 1, 128)' . "`n"
		. '} catch as PhaseFailure {' . "`n"
		. 'ObserverErrorPhase := "read-error:" . (PhaseFailure is OSError ? PhaseFailure.Number : Type(PhaseFailure))' . "`n"
		. '}' . "`n"
		. 'ObserverErrorText .= " | phase=" . ObserverErrorPhase . " | what=" . SubStr(ObserverFailure.What, 1, 128) . " | line=" . ObserverFailure.Line' . "`n"
		. '}' . "`n"
		. 'FileAppend(ObserverErrorText, A_Args[1] . ".failure", "UTF-8-RAW")' . "`n"
		. 'ExitApp(2)' . "`n"
		. '}' . "`n"
		. '#Include ' . UiaOwner . "`n"
}



/**
 * Executes the generated error callback without querying a desktop provider.
 * Numeric native failures keep their last phase and exact call site; semantic
 * refusal strings remain unchanged so the real no-filter mutation stays causal.
 */
_NDT_FileFilterFailureDiagnostics() {
	Root := A_Temp . "\ergopti_filter_error_" . A_ScriptHwnd . "_" . A_TickCount
	AssertFalse(DirExist(Root), "the observer error fixture has one private root")
	DirCreate(Root)
	Ownership := {CanRetire: true}
	try {
		ObserverSource := _NDT_FileFilterObserverSource("unused-observer-library.ahk")
		Start := InStr(ObserverSource, "`n_NFO_Error(")
		Finish := InStr(ObserverSource, "`n#Include ", , Start)
		AssertTrue(Start > 0 && Finish > Start, "the actual generated error callback must exist")
		CallbackSource := SubStr(ObserverSource, Start + 1, Finish - Start)
		for CaseName in ["native", "no-phase", "unreadable-phase", "semantic"] {
			Receipt := Root . "\" . CaseName
			if CaseName == "unreadable-phase"
				DirCreate(Receipt . ".phase")
			else if CaseName != "no-phase"
				FileAppend("restricted-txt|elapsed_ms=501", Receipt . ".phase", "UTF-8-RAW")
			Harness := Receipt . ".ahk"
			FailureSource := CaseName == "semantic"
				? 'Error("Owned BIN visible under the restricted file filter")'
				: 'OSError(0x80131505, "_NFO_Visible")'
			FileAppend('#Requires AutoHotkey v2.0' . "`n#SingleInstance Off`n#NoTrayIcon`n#Warn All, StdOut`n"
				. 'try _NFO_Error(' . FailureSource . ')' . "`n"
				. 'catch' . "`n" . 'ExitApp(3)' . "`n" . CallbackSource,
				Harness, "UTF-8")
			AssertEqual("", _NDT_RunChild(A_AhkPath, ["/ErrorStdOut", Harness, Receipt], Ownership, 2),
				"a native error remains a failing child with no fabricated success output")
			Detail := FileRead(Receipt . ".failure", "UTF-8")
			if CaseName == "semantic" {
				AssertEqual("Owned BIN visible under the restricted file filter", Detail,
					"semantic mutation refusals retain their exact independent expected message")
			} else {
				Assert(InStr(Detail, "0x80131505") > 0, "the native HRESULT remains visible")
				if CaseName == "unreadable-phase" {
					Assert(RegExMatch(Detail, " \| phase=read-error:-?[0-9]+ \| what=_NFO_Visible \| line=[0-9]+") > 0,
						"an unreadable phase retains both the primary native failure and the numeric read refusal")
				} else {
					ExpectedPhase := CaseName == "native" ? "restricted-txt|elapsed_ms=501" : "not-started"
					Assert(InStr(Detail, " | phase=" . ExpectedPhase . " | what=_NFO_Visible | line=") > 0,
						"the error retains its native phase, call site and generated line")
				}
			}
		}
	} finally {
		if Ownership.CanRetire
			DirDelete(Root, true)
	}
}
Test("native file filter: generated failure receipts retain phase and call site", _NDT_FileFilterFailureDiagnostics)

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
		'if _NFPMode != "baseline" {' . "`n" . _NDT_FileFilterCaptureSource() . _NDT_FileFilterActionSource() . '}' . "`n" . ObserverBoundary, , &ObserverBoundaries)
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
	ExpectedSelection := FileRead(FilterRoot . "\owned.path", "UTF-8")
	ActualSelection := FileRead(FilterRoot . "\selected.result", "UTF-8")
	if !(ActualSelection == ExpectedSelection) {
		try {
			for FilterAction in ["selected", "cancelled"]
				if FileGetSize(FilterRoot . "\" . FilterAction . ".action") > 128
					throw Error("The owned action diagnostic exceeds its closed bound")
			FilterFacts := _NDT_FileFilterFailureFacts(Index,
				FileRead(FilterRoot . "\selected.action", "UTF-8"),
				FileRead(FilterRoot . "\cancelled.action", "UTF-8"), ActualSelection, ExpectedSelection,
				FileRead(FilterRoot . "\cancelled.result", "UTF-8"))
			FileAppend("::notice title=Windows native file filter diagnostic::" . FilterFacts
				. " caption_match=1 selected_retired=1 cancelled_retired=1`n", "*")
		} catch {
			FileAppend("::notice title=Windows native file filter diagnostic::diagnostic_refused=1`n", "*")
		}
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
 * Retains per-query settings and the established outer native observation caps.
 * A provider traversal can exceed one UIA transaction timeout. Each poll shares
 * its fresh item census between filename predicates, without reusing that census
 * after a filter change. The exact child owner still enforces the wall-clock cap.
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

/** The independent behavioral family runs even if the original label assertion fails. */
_NDT_ActualNativeFileFilterBehavior() {
	_NDT_RunPolicyFamily("file_filter_behavior", _NDT_CheckFileFilterBehaviorPolicy)
}
Test("native file filter: real shell items and All Files expose a no-filter mutation (shared-window-titles)",
	_NDT_ActualNativeFileFilterBehavior)
