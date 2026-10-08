; tests/fixtures/key_combination_altgr_suffix_probe.ahk

; ==============================================================================
; MODULE: Interpreted AltGr Custom-Suffix Hook Probe
; DESCRIPTION:
; Registers the actual remap files in production order. Explicit injected scan
; edges and independent criterion/effect ports isolate AHK variant priority.
; The owned US-layout window and native process receipts qualify this controlled
; registration boundary; they do not establish physical AltGr generation.
;
; FEATURES & RATIONALE:
; 1. Both custom pair variants precede the independently eligible ordinary and
;    later AltGr owners; bypassing pair admission must select the later owner.
; 2. Every Down requires the exact owned foreground HWND/PID/thread and original
;    US HKL, with no other physical or logical modifier held.
; 3. Exit cleanup retracts only issued single-edge Down obligations. No layout
;    activation, ambient key-up pulse or foreign-window Down is allowed.
; ==============================================================================

#Requires AutoHotkey v2.0
#Warn VarUnset, Off
#SingleInstance Off

global TapHold := Map()
global LayerEnabled := false
global ProbeEnabled := A_Args[3] == "candidate"
global ProbePair := true
global ProbeNative := false
global ProbeWindow := 0
global ProbePid := DllCall("GetCurrentProcessId", "uint")
global ProbeThread := DllCall("GetCurrentThreadId", "uint")
global ProbeHkl := DllCall("GetKeyboardLayout", "uint", 0, "ptr")
global ProbeOwned := Map()
global ProbeCounts := Map("suppress", 0, "native", 0, "ordinary", 0, "fallback", 0)
global ProbeReceipt := ""
global ProbeObservationGeneration := A_Args.Length >= 4 && RegExMatch(A_Args[4], "^[1-9][0-9]{0,8}$")
	? Integer(A_Args[4]) : 0
global ProbeObservationSerial := 0
global ProbeObservationScenario := 0
global ProbeObservationWriting := false
global ProbeObservationFailed := false
OnExit(ProbeRelease)
SetTimer(() => ExitApp(124), -5000)
if ProbeObservationGeneration {
	OnError(ProbeObserveUnhandled)
	OnExit(ProbeObserveExit)
	ProbeObservePhase(1)
}
try {
	ProbeRun()
	ExitApp(0)
} catch Error as Err {
	PobCaughtFacts := ProbeObservationErrorFacts(Err)
	ProbeObservePhase(15, PobCaughtFacts[1], PobCaughtFacts[2], PobCaughtFacts[3])
	FileAppend(Err.Message . "`n" . Err.Stack . "`n", "**", "UTF-8")
	ExitApp(1)
}

; Keep exactly the main driver's input level and source include order.
#InputLevel 2
#Include ../../platform/remap/key_combination_keys.ahk
#Include ../../platform/remap/altgr.ahk
#InputLevel 0

ProbeRun() {
	global ProbeWindow, ProbePair, ProbeNative, ProbeCounts, ProbeReceipt
	global ProbePid, ProbeThread, ProbeHkl, ProbeOwned, ProbeObservationScenario
	ProbeObservePhase(2)
	if ProbeHkl != 0x04090409
		throw Error("The controlled hook probe requires the existing exact US HKL.")
	ProbeObservePhase(3)
	ProbeWindow := Gui("+ToolWindow", "Owned key-combination hook probe")
	ProbeWindow.AddEdit("w180 h30")
	ProbeWindow.Show("w200 h70")
	ProbeObservePhase(4)
	if !WinWaitActive("ahk_id " . ProbeWindow.Hwnd, , 1) || !ProbeAdmission()
		throw Error("The controlled hook probe could not admit its exact owned foreground.")
	ProbeObservePhase(5)
	ProbeReceipt := A_Args[2] . "|" . ProbePid . "|" . ProbeThread . "|" . ProbeWindow.Hwnd
		. "|" . Format("{:08X}", ProbeHkl) . "|injected-registration`n"
	try {
		for _, Scenario in ["suppress", "native", "fallback"] {
			ProbeObservationScenario += 1
			ProbePair := Scenario != "fallback"
			ProbeNative := Scenario == "native"
			for Kind in ProbeCounts
				ProbeCounts[Kind] := 0
			ProbeObservePhase(6)
			ProbeDown("LCtrl", "SC01D")
			ProbeObservePhase(7)
			ProbeObservePhase(8)
			ProbeDown("RAlt", "SC138")
			ProbeObservePhase(9)
			Sleep(80)
			ProbeObservePhase(10)
			if ProbeRelease() != 0
				throw Error("The controlled hook probe retained injected modifier release debt.")
			ProbeObservePhase(11)
			Sleep(80)
			if !ProbeAdmission()
				throw Error("The controlled hook observation lost its exact source/foreground fence.")
			ProbeReceipt .= Scenario . "|" . ProbeCounts["suppress"] . "|" . ProbeCounts["native"]
				. "|" . ProbeCounts["ordinary"] . "|" . ProbeCounts["fallback"] . "|" . ProbeOwned.Count . "`n"
			ProbeObservePhase(12)
		}
		FileAppend(ProbeReceipt, A_Args[1], "UTF-8-RAW")
		ProbeObservePhase(13)
	} finally {
		if ProbeRelease() == 0
			ProbeWindow.Destroy()
	}
}

ProbeAdmission() {
	global ProbeWindow, ProbePid, ProbeThread, ProbeHkl, ProbeOwned
	if !IsObject(ProbeWindow) || DllCall("GetForegroundWindow", "ptr") != ProbeWindow.Hwnd
		return false
	Pid := 0
	Thread := DllCall("GetWindowThreadProcessId", "ptr", ProbeWindow.Hwnd, "uint*", &Pid, "uint")
	if Pid != ProbePid || Thread != ProbeThread
		return false
	if ProbeHkl != 0x04090409 || DllCall("GetKeyboardLayout", "uint", 0, "ptr") != ProbeHkl
		return false
	for _, Name in ["LCtrl", "RCtrl", "LAlt", "RAlt", "LShift", "RShift", "LWin", "RWin"] {
		if GetKeyState(Name, "P") || (GetKeyState(Name) && !ProbeOwned.Has(Name))
			return false
	}
	return true
}

ProbeDown(Name, Scan) {
	global ProbeOwned
	if !ProbeAdmission() || ProbeOwned.Has(Name)
		throw Error("The controlled hook probe lost foreground/layout/modifier admission before Down.")
	; One issued send has one release debt, including an uncertain native send.
	; Startup/admission failures issue no send and therefore own no Up.
	Edge := "{Blind}{" . Scan . " Down}"
	SendLevel(3)
	ProbeOwned[Name] := true
	SendEvent(Edge)
}

ProbeRelease(*) {
	global ProbeOwned
	for _, Name in ["RAlt", "LCtrl"] {
		if !ProbeOwned.Has(Name)
			continue
		try {
			SendLevel(3)
			SendEvent("{Blind}{" . (Name == "RAlt" ? "SC138" : "SC01D") . " Up}")
			ProbeOwned.Delete(Name)
		} catch Error as Err {
			FileAppend("Injected release debt: " . Name . " " . Err.Message . "`n", "**", "UTF-8")
		}
	}
	return ProbeOwned.Count == 0 ? 0 : 1
}

ProbeHasFocus() {
	global ProbeWindow, ProbePid, ProbeThread, ProbeHkl
	if !IsObject(ProbeWindow) || DllCall("GetForegroundWindow", "ptr") != ProbeWindow.Hwnd
		return false
	Pid := 0
	Thread := DllCall("GetWindowThreadProcessId", "ptr", ProbeWindow.Hwnd, "uint*", &Pid, "uint")
	return Pid == ProbePid && Thread == ProbeThread
		&& ProbeHkl == 0x04090409 && DllCall("GetKeyboardLayout", "uint", 0, "ptr") == ProbeHkl
}

KeyCombinationOwnsHotkey() {
	return ProbeHasFocus()
}

KeyCombinationFireHotkey() {
	global ProbeCounts
	if RegExMatch(A_ThisHotkey, "i)SC138$")
		ProbeCounts["ordinary"] += 1
}

KeyCombinationOwnsAltGrSuffix(Passthrough) {
	global ProbeEnabled, ProbePair, ProbeNative
	return ProbeHasFocus() && ProbeEnabled && ProbePair && ProbeNative == Passthrough
}

KeyCombinationFireAltGrSuffix(Passthrough) {
	global ProbeCounts
	ProbeCounts[Passthrough ? "native" : "suppress"] += 1
}

AltGrOwnerPassesThrough(Kana) {
	global ProbeNative
	return ProbeHasFocus() && !Kana && ProbeNative
}

AltGrOwnerHolds(Kana) {
	global ProbeNative
	return ProbeHasFocus() && !Kana && !ProbeNative
}

TapHoldAltGrTakesItsLCtrl(Passthrough) {
	return true
}

TapHoldHoldLayer(State, KeyId) {
	return ""
}

_AltGrHoldModKey() {
	return "RAlt"
}

TapHoldDuration(State, KeyId) {
	return 0.2
}

KS_AltGrKeyName() {
	return "RAlt"
}

TapHoldOwnImmediateModifier(*) {
	global ProbeCounts
	ProbeCounts["fallback"] += 1
	return Map("tap", false)
}

TapHoldPressIsOwned(KeyId) {
	return false
}

TextSendMenuMask() {
	return true
}


/** Records only declared scalar phases in the parent's pinned diagnostic file. */
ProbeObservePhase(PobStage, PobErrorKind := 0, PobErrorSource := 0, PobErrorLine := 0, PobExitCode := -1) {
	global ProbeObservationGeneration, ProbeObservationSerial, ProbeObservationScenario
	global ProbeObservationWriting, ProbeObservationFailed, ProbePid, ProbeThread, ProbeOwned, ProbeEnabled
	if !ProbeObservationGeneration || ProbeObservationWriting || ProbeObservationSerial >= 128 || ProbeObservationFailed
		return
	ProbeObservationWriting := true
	try {
		ProbeObservationSerial += 1
		PobRow := A_Args[2] . "|" . ProbePid . "|" . ProbeThread . "|" . ProbeObservationGeneration
			. "|" . (ProbeEnabled ? 1 : 2) . "|" . ProbeObservationSerial . "|" . PobStage
			. "|" . ProbeObservationScenario . "|" . ProbeOwned.Count . "|" . PobErrorKind
			. "|" . PobErrorSource . "|" . PobErrorLine . "|" . PobExitCode . "`n"
		; FileAppend excludes all sharing and conflicts with the parent's identity pin.
		PobStream := FileOpen(A_Args[1] . ".observation", "a-d", "UTF-8-RAW")
		try {
			if PobStream.Write(PobRow) != StrLen(PobRow)
				throw Error("Incomplete observation append")
		} finally PobStream.Close()
	} catch Any {
		; Optional observation refusal cannot replace any original effect or verdict.
		ProbeObservationFailed := true
	} finally {
		ProbeObservationWriting := false
	}
}

/** Reads only native data descriptors; custom exception getters are never invoked. */
ProbeObservationErrorFacts(PobThrown) {
	PobKind := 0, PobSource := 0, PobLine := 0
	if !IsObject(PobThrown)
		return [0, 0, 0]
	for PobIndex, PobPrototype in [Error.Prototype, ValueError.Prototype, TypeError.Prototype,
		UnsetError.Prototype, OSError.Prototype, TargetError.Prototype, TimeoutError.Prototype, MemoryError.Prototype] {
		if ObjGetBase(PobThrown) == PobPrototype {
			PobKind := PobIndex
			break
		}
	}
	if !PobKind
		return [0, 0, 0]
	try {
		PobGetDescriptor := GetMethod(Object.Prototype, "GetOwnPropDesc")
		PobFile := PobGetDescriptor.Call(PobThrown, "File")
		PobNumber := PobGetDescriptor.Call(PobThrown, "Line")
		if ObjHasOwnProp(PobFile, "Value") && PobFile.Value is String && StrLen(PobFile.Value) <= 2048
			&& ObjHasOwnProp(PobNumber, "Value") && PobNumber.Value is Integer
			&& PobNumber.Value > 0 && PobNumber.Value <= 65535 {
			SplitPath(PobFile.Value, &PobLeaf)
			for PobIndex, PobName in ["key_combination_altgr_suffix_probe.ahk", "key_combination_keys.ahk", "altgr.ahk"] {
				if PobLeaf == PobName {
					PobSource := PobIndex
					PobLine := PobNumber.Value
					break
				}
			}
		}
	} catch Any {
		PobSource := 0, PobLine := 0
	}
	return [PobKind, PobSource, PobLine]
}

/** Observes unhandled errors without suppressing the original native handler. */
ProbeObserveUnhandled(PobThrown, PobMode) {
	try {
		PobFacts := ProbeObservationErrorFacts(PobThrown)
		ProbeObservePhase(16, PobFacts[1], PobFacts[2], PobFacts[3])
	} catch Any {
		; An optional observer cannot replace default native error propagation.
	}
	return 0
}

/** Exit notification does not alter the original release callback or exit code. */
ProbeObserveExit(PobReason, PobCode) {
	ProbeObservePhase(14, 0, 0, 0, PobCode)
	return 0
}
