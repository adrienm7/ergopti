; tests/unit/test_native_dialog_titles.ahk
;
; ==============================================================================
; MODULE: Native Dialog Caption Regression
; DESCRIPTION:
; Executes the actual native caption owner and actual generated policy in private
; AHK children. Visible message/input captions are captured independently of the
; shared composer, alongside body, timeout and exact default-text receipts.
; Calls precede both owner #Includes, exercising their pre-bootstrap availability.
; ==============================================================================

/**
 * Settles one exact process tree before inspecting its completion observations.
 * @param {string} Executable - The native executable.
 * @param {Array} Args - Structured arguments.
 * @param {object} Ownership - Retains the fixture if exact child retirement fails.
 * @returns {string} Captured ASCII completion acknowledgement.
 */
_NDT_RunChild(Executable, Args, Ownership) {
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
		AssertEqual(0, Receipt.Code, "the actual native caption owner parses and runs: "
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
		. '_NDTReceipt := A_Args[1] . "\message"' . "`n"
		. 'SetTimer(_NDTCapture, 20)' . "`n"
		. 'MessageResult := Ui_MsgBox("Preserved message body", "Navigation layer", "YesNo Default2 Icon! T0.5")' . "`n"
		. 'SetTimer(_NDTCapture, 0)' . "`n"
		. 'FileAppend(MessageResult, A_Args[1] . "\message.result", "UTF-8-RAW")' . "`n"
		. '_NDTReceipt := A_Args[1] . "\input"' . "`n"
		. 'SetTimer(_NDTCapture, 20)' . "`n"
		. 'InputResult := Ui_InputBox("Preserved input body", "Navigation layer", "w320 h180 Password T0.5", " Secret value ")' . "`n"
		. 'SetTimer(_NDTCapture, 0)' . "`n"
		. 'FileAppend(InputResult.Result . "``n" . InputResult.Value, A_Args[1] . "\input.result", "UTF-8-RAW")' . "`n"
		. '_NDTReceipt := A_Args[1] . "\unnamed"' . "`n"
		. 'SetTimer(_NDTCapture, 20)' . "`n"
		. 'UnnamedResult := Ui_MsgBox("Preserved unnamed body", , "T0.5")' . "`n"
		. 'SetTimer(_NDTCapture, 0)' . "`n"
		. 'FileAppend(UnnamedResult, A_Args[1] . "\unnamed.result", "UTF-8-RAW")' . "`n"
		. '_NDTReceipt := A_Args[1] . "\cancelled"' . "`n"
		. 'SetTimer(_NDTCapture, 20)' . "`n"
		. 'CancelledResult := Ui_InputBox("Preserved cancelled body", "Navigation layer", "w320 h180 T2", " Secret value ")' . "`n"
		. 'SetTimer(_NDTCapture, 0)' . "`n"
		. 'FileAppend(CancelledResult.Result . "``n" . CancelledResult.Value, A_Args[1] . "\cancelled.result", "UTF-8-RAW")' . "`n"
		. 'FileAppend("dialogs-written", "*", "UTF-8-RAW")' . "`nExitApp(0)`n"
		. '_NDTCapture() {' . "`n"
		. 'global _NDTReceipt' . "`n"
		. 'for Hwnd in WinGetList("ahk_pid " . DllCall("GetCurrentProcessId", "UInt")) {' . "`n"
		. 'if Hwnd == A_ScriptHwnd || !DllCall("IsWindowVisible", "Ptr", Hwnd)' . "`ncontinue`n"
		. 'FileAppend(WinGetTitle("ahk_id " . Hwnd), _NDTReceipt . ".title", "UTF-8-RAW")' . "`n"
		. 'FileAppend(WinGetText("ahk_id " . Hwnd), _NDTReceipt . ".body", "UTF-8-RAW")' . "`n"
		. 'if InStr(_NDTReceipt, "\message") {' . "`n"
		. 'YesButton := DllCall("GetDlgItem", "Ptr", Hwnd, "Int", 6, "Ptr")' . "`n"
		. 'NoButton := DllCall("GetDlgItem", "Ptr", Hwnd, "Int", 7, "Ptr")' . "`n"
		. 'DefaultId := SendMessage(0x400, 0, 0, , "ahk_id " . Hwnd) & 0xFFFF' . "`n"
		. 'FileAppend((YesButton ? "yes" : "missing") . "|" . (NoButton ? "no" : "missing") . "|" . DefaultId, _NDTReceipt . ".buttons", "UTF-8-RAW")' . "`n}`n"
		. 'if InStr(_NDTReceipt, "\input") {' . "`n"
		. 'InputControlHwnd := ControlGetHwnd("Edit1", "ahk_id " . Hwnd)' . "`n"
		. 'FileAppend((WinGetStyle("ahk_id " . InputControlHwnd) & 0x20) ? "password" : "plain", _NDTReceipt . ".password", "UTF-8-RAW")' . "`n}`n"
		. 'SetTimer(_NDTCapture, 0)' . "`n"
		. 'if InStr(_NDTReceipt, "\cancelled")' . "`n"
		. 'PostMessage(0x10, 0, 0, , "ahk_id " . Hwnd)' . "`nreturn`n}`n}`n"
		. '_NDTProbeError(Err, *) {' . "`n"
		. 'FileAppend(Err.Message, "*", "UTF-8-RAW")' . "`nExitApp(2)`n}`n"
		. '#Include ' . Artifact . "`n"
		. '#Include ' . Owner . "`n"
}

/**
 * Runs native dialogs with independent captions for default and customized policy.
 * Both native return shapes and exact input defaults remain observable.
 */
_NDT_ActualNativeCaptionsAndResults() {
	global _StaticDir
	Root := A_Temp . "\ergopti_native_dialogs_" . A_ScriptHwnd . "_" . A_TickCount
	AssertFalse(DirExist(Root), "the native-dialog fixture must be privately owned")
	DirCreate(Root)
	Ownership := {CanRetire: true}
	Cases := [
		{Prefix: "ErgoptiPlus", Separator: " — ", Expected: "ErgoptiPlus — Navigation layer"},
		{Prefix: "", Separator: " — ", Expected: "Navigation layer"},
		{Prefix: "Other product", Separator: ": ", Expected: "Other product: Navigation layer"},
		{Prefix: 'Quoted "product" ``name``', Separator: "", Expected: 'Quoted "product" ``name``Navigation layer'},
		{Prefix: "Other `; product", Separator: " `; ", Expected: "Other `; product `; Navigation layer"}
	]
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
		Owner := _StaticDir . "\ergopti_plus\windows\infra\native_dialogs.ahk"
		for Index, Spec in Cases {
			Fixture := Root . "\" . Index
			Artifact := Fixture . "\static\ergopti_plus\windows\_generated\window_titles.ahk"
			Harness := Fixture . "\native_dialogs.ahk"
			FileAppend(_NDT_ProbeSource(Artifact, Owner), Harness, "UTF-8")
			AssertEqual("dialogs-written", _NDT_RunChild(A_AhkPath,
				["/ErrorStdOut", Harness, Fixture], Ownership), "native dialogs acknowledge private receipts with ASCII stdout")
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
	} finally {
		if Ownership.CanRetire
			DirDelete(Root, true)
	}
}
Test("native dialogs: actual captions and results follow customized shared policy (shared-window-titles)",
	_NDT_ActualNativeCaptionsAndResults)
