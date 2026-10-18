; tests/unit/ui/windows/test_native_folder_orchestration.ahk

; ==============================================================================
; MODULE: Native Folder Picker Orchestration
; DESCRIPTION:
; The folder picker ABI orchestration keeps its prompt, selection and
; settlement, refuses invalid inputs and partial native refusals strictly,
; and rejects foreign callback cookies and HWND leases.
; ==============================================================================

#Requires AutoHotkey v2.0





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
