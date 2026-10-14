; tests/fixtures/nav_owner_lifecycle_receiving_fixture.ahk

; ==============================================================================
; MODULE: Explicit Native Navigation Owner Lifecycle Receiving
; DESCRIPTION:
; Loads the actual DLL through the original adapter and receives repeated real
; keyboard-hook start/join cycles. Requires an idle desktop with other input
; drivers stopped. Does not emit input or qualify physical events, captured
; FIFO settlement, retained registration custody or a production backend.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, StdOut
#Warn VarUnset, Off

if A_Args.Length != 1 || A_Args[1] != "--allow-native-nav-owner-lifecycle" {
	FileAppend("REFUSED: one explicit --allow-native-nav-owner-lifecycle flag is required before native loading.`n", "**")
	ExitApp(2)
}
if A_AhkVersion != "2.0.26" || A_PtrSize != 8 {
	FileAppend("REFUSED: pinned AutoHotkey2.0.26 x64 is required.`n", "**")
	ExitApp(2)
}

#Include %A_LineFile%\..\..\..\modules\keymap\keylayout\keylayout_parser.ahk
#Include %A_LineFile%\..\..\..\modules\keymap\keylayout\keylayout_tables.ahk
#Include %A_LineFile%\..\..\..\modules\keymap\keylayout\keylayout_emulation.ahk
#Include %A_LineFile%\..\..\..\adapters\llm_nav_event_owner.ahk

global _VendorDir := A_ScriptDir . "\..\..\vendor"
global _NNL := {Outstanding: false, Stop: 0, Starts: 0, Joins: 0, Reports: []}
OnExit(_NNL_Exit)

; Observe the original decoder's diagnostics without replacing any native port.
LoggerError(Category, Message, Args*) {
	global _NNL
	_NNL.Reports.Push({Category: Category, Message: Message, Args: Args})
}

_NNL_Require(Value, Message) {
	if !Value
		throw Error(Message)
}

_NNL_Idle() {
	Loop 254
		_NNL_Require(!(DllCall("User32\GetAsyncKeyState", "Int", A_Index, "Short") & 0x8000),
			"Release all keys and keep the desktop idle during native lifecycle receiving.")
}

_NNL_Exit(Reason, Code) {
	global _NNL
	if _NNL.Outstanding {
		NativeStatus := _NNL.Stop ? DllCall(_NNL.Stop, "Int") : -1
		if NativeStatus != 0 && NativeStatus != 10 {
			FileAppend("RETAINED native_stop=" . NativeStatus . " natural_exit=false`n", "**")
			return 1
		}
		_NNL.Outstanding := false
	}
	FileAppend("NATURAL_EXIT code=" . Code . " starts=" . _NNL.Starts . " joins=" . _NNL.Joins
		. " native_calls=real physical_qualified=false fifo_qualified=false custody_retirement_qualified=false production_qualified=false`n", "*")
	return 0
}

_NNL_Run() {
	global _NNL
	try {
		_NNL_Idle()
		_NNL_Require(_LLM_NavEventOwnerNativeEnsureLoaded(), "The original native loader refused.")
		NativeStart := _LLM_NavEventOwnerNativeExport("ErgoptiNav_Start")
		_NNL.Stop := _LLM_NavEventOwnerNativeExport("ErgoptiNav_Stop")
		NativeError := _LLM_NavEventOwnerNativeExport("ErgoptiNav_GetLastOsError")
		for Mode in ["raw", "default-ahk-decoder"] {
			_NNL_Idle()
			_NNL.Outstanding := true
			StartStatus := DllCall(NativeStart, "UInt64", A_ScriptHwnd, "UInt", 0x8057, "Int")
			StartError := DllCall(NativeError, "UInt")
			FileAppend("START mode=" . Mode . " status=" . StartStatus . " os_error=" . StartError . "`n", "*")
			_NNL_Require(StartStatus == 0 && StartError == 0, "The real native hook did not start.")
			_NNL.Starts += 1
			StopStatus := Mode == "raw" ? DllCall(_NNL.Stop, "Int") : _LLM_NavEventOwnerNativeStop()
			ExpectedStop := Mode == "raw" ? 0 : 1
			_NNL_Require(StopStatus is Integer && StopStatus == ExpectedStop, "The real native join was not acknowledged.")
			_NNL_Require(DllCall(NativeError, "UInt") == 0 && _NNL.Reports.Length == 0, "A clean join retained a native diagnostic.")
			_NNL.Outstanding := false
			_NNL.Joins += 1
			FileAppend("JOINED mode=" . Mode . " returned=" . StopStatus . "`n", "*")
		}
		_NNL_Require(!_LLM_NavEventOwnerTerminalRouteCoverage["cohort_complete"]
			&& !_LLM_NavEventOwnerTerminalRouteCoverage["transformed_output_enabled"], "Lifecycle receiving cannot enable an unqualified output cohort.")
	} catch as Failure {
		FileAppend("FAILED native_lifecycle_receiving: " . Failure.Message . "`n", "**")
		ExitApp(1)
		Persistent()
		return
	}
}
_NNL_Run()
ExitApp(0)
