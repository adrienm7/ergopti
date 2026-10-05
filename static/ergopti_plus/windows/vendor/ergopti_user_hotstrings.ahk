; vendor/ergopti_user_hotstrings.ahk

; ==============================================================================
; MODULE: Isolated Programmable Hotstring Worker
; DESCRIPTION:
; Runs an admitted user-source snapshot with the packaged AutoHotkey runtime.
; The generated wrapper includes the shared policy and user factory separately.
; Metadata and callback results use canonical UTF-8 hex framing on stdout.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
Persistent(true)
SetTimer(_UserCodeWorkerMain, -1)

/** Reads the cancellation event retained by the parent process owner. */
_UserCodeWorkerCancelled(EventHandle) {
	return DllCall("WaitForSingleObject", "Ptr", EventHandle, "UInt", 0, "UInt") == 0
}

/** Validates factory metadata and invokes exactly one explicitly requested rule. */
_UserCodeWorkerMain() {
	EventHandle := 0
	try {
		if A_Args.Length != 5
			throw Error("Invalid programmable hotstring worker arguments.")
		Mode := A_Args[1]
		Id := A_Args[2]
		EventHandle := DllCall("OpenEventW", "UInt", 0x00100000, "Int", false, "Str", A_Args[3], "Ptr")
		if !EventHandle
			throw Error("The programmable hotstring cancellation owner is unavailable.")
		if _UserCodeWorkerCancelled(EventHandle)
			throw Error("The programmable hotstring operation was cancelled.")
		Factory := ErgoptiDynamicHotstrings
		if !HasMethod(Factory, "Call")
			throw Error("The user source did not publish its factory.")
		Rules := Factory.Call(Map("platform", "windows"))
		Owned := UserCodeValidate(Rules, &Reason)
		if !(Owned is Array)
			throw Error("The user factory returned invalid metadata.")
		Output := "ERGOPTI_USER_HOTSTRINGS_V1`n"
		if Mode == "load" {
			for Rule in Owned
				Output .= UserCodeEncode(Rule["id"]) . "`t" . UserCodeEncode(Rule["suffix"]) . "`t" . UserCodeEncode(Rule["preview"]) . "`n"
		} else if Mode == "execute" {
			Selected := 0
			for Rule in Owned {
				if Rule["id"] == Id
					Selected := Rule
			}
			if !(Selected is Map) || !(Selected["suffix"] == UserCodeDecode(A_Args[4]))
				|| !(Selected["preview"] == UserCodeDecode(A_Args[5])) || _UserCodeWorkerCancelled(EventHandle)
				throw Error("The requested callback is unavailable.")
			Context := Map("id", Id, "suffix", Selected["suffix"], "cancelled", _UserCodeWorkerCancelled.Bind(EventHandle))
			Result := Selected["callback"].Call(Context)
			if Result is String {
				if !UserCodeTextValid(Result)
					throw Error("The callback returned invalid text.")
				Output .= "TEXT`t" . UserCodeEncode(Result) . "`n"
			} else if (Result is Integer) && Result == 1
				Output .= "ACTION`n"
			else if (Result is Integer) && Result == 0
				Output .= "CANCEL`n"
			else
				throw Error("The callback returned an invalid result.")
		} else
			throw Error("The worker mode is invalid.")
		if _UserCodeWorkerCancelled(EventHandle)
			throw Error("The programmable hotstring operation was cancelled.")
		Output .= "END`n"
		FileAppend(Output, "*", "UTF-8-RAW")
		ExitApp(0)
	} catch as Err {
		; User errors may include private contents. The parent owns a visible
		; localized failure; stderr transports only a stable refusal identifier.
		FileAppend("ERGOPTI_USER_HOTSTRINGS_FAILED`n", "**", "UTF-8-RAW")
		ExitApp(1)
	} finally {
		if EventHandle
			DllCall("CloseHandle", "Ptr", EventHandle)
	}
}
