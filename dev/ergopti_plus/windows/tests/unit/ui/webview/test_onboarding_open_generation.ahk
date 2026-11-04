; tests/unit/ui/webview/test_onboarding_open_generation.ahk
;
; ==============================================================================
; MODULE: Onboarding Opening Generation Tests
; DESCRIPTION:
; Drives the actual wizard, native Gui and SDK Promise await while browser COM
; effects complete after a close or a replacement. Exact sessions own results.
; ==============================================================================

#Requires AutoHotkey v2.0

; A native window child binds the one UI delay its host reads, with the value the
; suite loaded from the shared registry; any other key is refused.
_WebViewChildTimingBinding(Key) {
	return "TimingsGet(Section, Key) {`n"
		. "if Section != " . Chr(34) . "ui" . Chr(34) . " || Key != " . Chr(34) . Key . Chr(34) . "`n"
		. "throw Error(" . Chr(34) . "This child binds only " . Key . "." . Chr(34) . ")`n"
		. "return " . TimingsGet("ui", Key) . "`n}`n"
}

_OWOC_Source(Root) {
	global _DriverDir
	Source := _EDOT_Source(Root)
	Footer := "#Include " . _DriverDir . "\tests\fixtures\error_dialog_startup_owner_body.ahk`n"
	AssertTrue(SubStr(Source, StrLen(Source) - StrLen(Footer) + 1) == Footer,
		"The shared native diagnostics source must expose its exact fixture footer.")
	Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
	Source := StrReplace(Source, "_EDOS_", "_OWOC_")
	for Symbol in ["JsonParse", "OnboardingReadCurrentValues", "_Onboarding_ShowError", "WMPresentWindow"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "The wizard child requires its genuine whole owner: " . Symbol)
		Source .= "#Include " . Owner . "`n"
	}
	return Source . _WebViewChildTimingBinding("webview_host_safety_flush_ms")
		. "#Include " . _DriverDir . "\ui\onboarding\core.ahk`n"
		. "#Include " . _DriverDir . "\ui\onboarding\translate.ahk`n"
		. "#Include " . _DriverDir . "\ui\onboarding\webview.ahk`n"
		. "#Include " . _DriverDir . "\tests\fixtures\onboarding_open_generation_body.ahk`n"
}

_OWOC_Assets(Root) {
	global _DriverDir, _SharedDir
	_EDOT_Assets(Root)
	FSCreateDirectoryExclusiveStrict(Root . "\shared\ui")
	FileCopy(_SharedDir . "\ui\apps.manifest.json", Root . "\shared\ui\apps.manifest.json", false)
	Loader := Root . "\vendor\64bit\WebView2Loader.dll"
	FSDeleteStrict(Loader)
	FileCopy(_DriverDir . "\vendor\64bit\WebView2Loader.dll", Loader, false)
	AssertEqual(CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\vendor\64bit\WebView2Loader.dll")),
		CryptoSha256Bytes(FSReadBytesStrict(Loader)), "The private availability input is the actual shipped SDK loader.")
}

_OWOC_Done(State, Code, Output, ErrorText) {
	State.Calls += 1, State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}

_OWOC_Case(Mode) {
	static Serial := 0, Debt := 0
	AssertFalse(IsObject(Debt), "A previous unretired child prevents another component")
	Root := A_Temp . "\ergopti_onboarding_open_" . A_ScriptHwnd . "_" . ++Serial
	FSCreateDirectoryExclusiveStrict(Root)
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0
	Retired := false, AtDeadline := 0, ExportFailure := 0, PreviousCritical := Critical("Off")
	try {
		_OWOC_Assets(Root)
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, _OWOC_Source(Root)))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode, Root], _OWOC_Done.Bind(State))
		AssertTrue(Handle.start(), "The exact onboarding opening component must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed64(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The onboarding opening child did not settle within 15000 ms.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Ack := IsObject(Handle) ? Handle.terminate() : 1
			Retired := Ack is Integer && Ack == 1
			if Retired
				DirDelete(Root, true)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				Debt := {Handle: Handle, Root: Root}
			Critical(PreviousCritical)
		}
	}
	try {
		if Retired {
			_TestPrint("# onboarding-opening terminal calls=" . State.Calls . " code=" . State.Code
				. " capture_delivered=" . (State.Calls == 1) . " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# onboarding-opening combined_native_capture " . Line)
			} else
				_TestPrint("# onboarding-opening combined_native_capture UNKNOWN")
		}
	} catch Any as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls, "The component must settle once: " . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "The completion diagnostic must be empty: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The onboarding opening violated startup ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS onboarding-open-generation " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _OWOC_Mode in ["cold-success", "cold-refusal", "close-refusal", "close-reopen-refusal", "close-success", "close-reopen-success"]
	Test("Onboarding opening generation: " . _OWOC_Mode . " preserves the current window (onboarding-open-generation)", _OWOC_Case.Bind(_OWOC_Mode))
