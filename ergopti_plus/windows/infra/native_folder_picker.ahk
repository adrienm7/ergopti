; infra/native_folder_picker.ahk
;
; ==============================================================================
; MODULE: Owned Native Folder Picker
; DESCRIPTION:
; Uses the same SHBrowseForFolderW dialog as the pinned AHK DirSelect owner.
; BROWSEINFO.lpszTitle remains explanatory body text. The exact initialization
; callback owns window chrome; per-invocation cookies, HWND identity and native
; resource receipts prevent retitling another dialog or retaining native memory.
; ==============================================================================

#Include %A_LineFile%\..\..\adapters\native_folder_picker.ahk

/**
 * Parses the native root/initial-folder notation without trimming real path text.
 * @param {string} RootDir - Optional root followed by an asterisk and initial path.
 * @returns {object} Separate navigation root and exact initial selection.
 */
_Ui_FolderPaths(RootDir) {
	Star := InStr(RootDir, "*")
	Root := Star ? SubStr(RootDir, 1, Star - 1) : RootDir
	Initial := Star ? SubStr(RootDir, Star + 1) : ""
	if Star && RegExMatch(Root, "[ `t]$")
		Root := SubStr(Root, 1, -1)
	if Trim(Root, " `t") == ""
		Root := ""
	return { Root: Root, Initial: Initial }
}

/**
 * Handles only the exact BROWSEINFO callback, retaining errors for the caller.
 * @param {object} State - Private native lease and caption initialization state.
 * @param {integer} Hwnd - HWND supplied by SHBrowseForFolderW itself.
 * @param {integer} Message - Native initialization/validation callback message.
 * @param {integer} _Parameter - Native message-specific payload.
 * @param {integer} Cookie - The per-invocation BROWSEINFO.lParam receipt.
 * @returns {integer} Native validation policy, or zero for other messages.
 */
_Ui_FolderCallback(State, Hwnd, Message, _Parameter, Cookie) {
	if !State.Active || State.Failure
		return 0
	try {
		if Cookie != State.Cookie.Ptr
			throw Error("The native folder callback does not own this invocation")
		if !State.Native.MatchesWindow(Hwnd, State.Process, State.Thread)
			throw Error("The native folder callback does not own this window")
		if Message == 1 {
			if State.Window
				throw Error("The native folder window was initialized twice")
			if !State.Native.ClaimWindow(Hwnd, Cookie)
				throw Error("The native folder callback could not claim its exact window")
			State.Window := Hwnd
			if !State.Native.SetCaption(Hwnd, State.Caption)
				throw Error("The native folder window refused its shared caption")
			if !State.Native.OwnsWindow(Hwnd, Cookie)
				throw Error("The native folder caption lost its exact window lease")
			if State.Initial != ""
				State.Native.SetInitial(Hwnd, State.Initial)
		} else if Message == 4 {
			if Hwnd != State.Window || !State.Native.OwnsWindow(Hwnd, Cookie)
				throw Error("Folder validation does not own the initialized window")
			; BFFM_VALIDATEFAILEDW keeps invalid typed paths in the dialog, as AHK does.
			return 1
		}
	} catch as CallbackError {
		if !State.Failure
			State.Failure := CallbackError
		; A foreign callback never authorizes closing or changing its target HWND.
		if State.Window && State.Native.MatchesWindow(State.Window, State.Process, State.Thread)
			&& State.Native.OwnsWindow(State.Window, State.Cookie.Ptr) {
			try {
				if !State.Native.Close(State.Window)
					throw Error("The refused native folder window could not be closed")
			} catch as CloseError {
				State.Failure.Message .= " | " . CloseError.Message
			}
		}
	}
	return 0
}

/**
 * Settles every independently acquired native resource even when one release fails.
 * @param {object} State - Per-invocation acquisition receipts.
 * @returns {Array} Release failures to report after all resources were attempted.
 */
_Ui_FolderSettle(State) {
	Failures := []
	State.Active := false
	if State.Window && State.Native.ExistsWindow(State.Window) {
		; A modal returning while its callback can still run is a violated native
		; receipt. Preserve every backing buffer/PIDL/callback instead of freeing
		; memory that the live HWND may use. Never close a recycled foreign HWND.
		if State.Native.MatchesWindow(State.Window, State.Process, State.Thread)
			&& State.Native.OwnsWindow(State.Window, State.Cookie.Ptr) {
			try {
				if !State.Native.Close(State.Window)
					Failures.Push("the exact unfinished folder modal refused cancellation")
			} catch as CloseError {
				Failures.Push("unfinished cancellation: " . CloseError.Message)
			}
		}
		Failures.Push("the native folder modal did not acknowledge window retirement")
		return Failures
	}
	for Field in ["SelectedPidl", "RootPidl", "Callback"] {
		Handle := State.%Field%
		if !Handle
			continue
		try {
			if Field == "Callback"
				State.Native.FreeCallback(Handle)
			else
				State.Native.FreePidl(Handle)
			State.%Field% := 0
		} catch as ReleaseError {
			Failures.Push(Field . ": " . ReleaseError.Message)
		}
	}
	; Break the bound-function/state cycle after retiring the native callback.
	State.CallbackFunction := 0
	if State.ComOwned {
		try {
			State.Native.ReleaseCom()
			State.ComOwned := false
		} catch as ReleaseError {
			Failures.Push("COM: " . ReleaseError.Message)
		}
	}
	return Failures
}

/**
 * Runs the owned native folder modal with exact prompt, root and cancellation data.
 * The caller supplies HWND ownership explicitly; AHK's private THREAD_DIALOG_OWNER
 * cannot be inferred through a public API. Current application callers own none.
 * @param {string} RootDir - Native root/asterisk/initial-folder notation.
 * @param {integer} Options - The native creation, edit-box and old-dialog bits.
 * @param {string} Prompt - Exact explanatory body text, independent of branding.
 * @param {string} Caption - Already composed shared-policy native caption.
 * @param {integer} OwnerHwnd - Explicit owning HWND, or zero for an unowned modal.
 * @param {object|integer} Native - Windows ABI owner, or an isolated unit port.
 * @returns {string} The native filesystem path, or empty on cancellation.
 */
_Ui_FolderSelect(RootDir, Options, Prompt, Caption, OwnerHwnd, Native := 0) {
	for Text in [RootDir, Prompt, Caption] {
		if !(Text is String) || RegExMatch(Text, "\x00")
			throw ValueError("Native folder text must be a string without a NUL")
	}
	if !IsInteger(Options) || Options < 0 || Options > 7
		throw ValueError("Native folder options must contain only the three supported bits")
	if !IsInteger(OwnerHwnd) || OwnerHwnd < 0
		throw ValueError("The native folder owner must be an explicit HWND or zero")
	if !IsObject(Native) {
		if !(Native is Integer) || Native != 0
			throw ValueError("The native folder ABI owner must be an object or default zero")
		Native := _Ui_FolderNative
	}
	OwnerProcessId := Native.ProcessId(), OwnerThreadId := Native.ThreadId()
	if OwnerHwnd && !Native.MatchesWindow(OwnerHwnd, OwnerProcessId, OwnerThreadId)
		throw ValueError("The native folder owner belongs to another window context")
	Paths := _Ui_FolderPaths(RootDir)
	State := { Native: Native, Caption: Caption, Initial: Paths.Initial,
		Process: OwnerProcessId, Thread: OwnerThreadId, Cookie: Buffer(A_PtrSize, 0),
		Active: false, Window: 0, Failure: 0, ComOwned: false,
		RootPidl: 0, SelectedPidl: 0, Callback: 0, CallbackFunction: 0,
		Info: 0, Body: 0, Display: 0 }
	Selected := ""
	try {
		ComStatus := Native.InitCom()
		if ComStatus != 0 && ComStatus != 1
			throw Error("The native folder picker could not acquire its COM apartment: " . ComStatus)
		State.ComOwned := true
		if Paths.Root != "" {
			RootPidl := 0
			try RootStatus := Native.ParseRoot(Paths.Root, &RootPidl)
			finally State.RootPidl := RootPidl
			if RootStatus != 0 || !RootPidl
				throw Error("The native folder navigation root could not be resolved: " . RootStatus)
		}
		State.CallbackFunction := _Ui_FolderCallback.Bind(State)
		State.Callback := Native.MakeCallback(State.CallbackFunction)
		if !State.Callback
			throw Error("The native folder callback could not be acquired")
		Display := State.Display := Buffer(520, 0)
		Body := State.Body := Buffer((StrLen(Prompt) + 1) * 2, 0)
		StrPut(Prompt, Body, "UTF-16")
		Info := State.Info := Buffer(A_PtrSize * 8, 0)
		Flags := ((Options & 4) ? 0 : 0x40) | ((Options & 1) ? 0 : 0x200) | ((Options & 2) ? 0x10 : 0)
		NumPut("Ptr", OwnerHwnd, Info, 0)
		NumPut("Ptr", State.RootPidl, Info, A_PtrSize)
		NumPut("Ptr", Display.Ptr, Info, A_PtrSize * 2)
		NumPut("Ptr", Body.Ptr, Info, A_PtrSize * 3)
		NumPut("UInt", Flags, Info, A_PtrSize * 4)
		NumPut("Ptr", State.Callback, Info, A_PtrSize * 5)
		NumPut("Ptr", State.Cookie.Ptr, Info, A_PtrSize * 6)
		State.Active := true
		State.SelectedPidl := Native.Browse(Info)
		State.Active := false
		if State.Failure
			throw State.Failure
		if State.SelectedPidl {
			Selected := Native.PathFromPidl(State.SelectedPidl)
			if !(Selected is String)
				throw Error("The native folder picker returned a non-string filesystem path")
		}
	} catch as SelectionError {
		State.Failure := SelectionError
	}
	for Detail in _Ui_FolderSettle(State) {
		if State.Failure
			State.Failure.Message .= " | settlement " . Detail
		else
			State.Failure := Error("Native folder ownership settlement failed: " . Detail)
	}
	if State.Failure
		throw State.Failure
	return Selected
}
