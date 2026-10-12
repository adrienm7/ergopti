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
#Include ../support/altgr_probe_ordinary_owner.ahk

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
global ProbeFailed := false
global ProbeDiagnosticError := ""
OnError(ProbeFailure)
OnExit(ProbeRelease)
SetTimer(ProbeDeadline, -5000)
try {
	ProbeDiagnostic("started")
	ProbeRun()
	ProbeDiagnostic("exit-success")
	ExitApp(0)
} catch Error as Err {
	ProbeFailure(Err, "main")
}

; Keep exactly the main driver's input level and source include order.
#InputLevel 2
#Include ../../platform/remap/key_combination_keys.ahk
#Include ../../platform/remap/altgr.ahk
#InputLevel 0

; Write directly to the owned evidence path: a timed-out parent deliberately
; detaches its completion callback and cannot recover child streams through it.
ProbeDiagnostic(Stage, Detail := "") {
	global ProbePid, ProbeHkl, ProbeOwned
	FileAppend("stage=" . Stage . " pid=" . ProbePid . " hkl=" . Format("{:X}", ProbeHkl)
		. " pending=" . ProbeOwned.Count . " critical=" . A_IsCritical . "`n" . Detail,
		A_Args[1] . ".diagnostics.txt", "UTF-8-RAW")
}

ProbeFailure(Err, Mode) {
	global ProbeFailed
	ProbeFailed := true
	ProbeDiagnostic("error-" . Mode, Err.Message . "`n" . Err.Stack . "`n")
	FileAppend(Err.Message . "`n" . Err.Stack . "`n", "**", "UTF-8")
	ExitApp(1)
	; An outstanding release may veto exit, but no new input is then admitted.
	return 1
}

ProbeDeadline() {
	global ProbeFailed
	ProbeFailed := true
	ProbeDiagnostic("deadline")
	ExitApp(124)
}

ProbeRun() {
	global ProbeWindow, ProbePair, ProbeNative, ProbeCounts, ProbeReceipt
	global ProbePid, ProbeThread, ProbeHkl, ProbeOwned
	if ProbeHkl != 0x04090409
		throw Error("The controlled hook probe requires the existing exact US HKL.")
	ProbeWindow := Gui("+ToolWindow", "Owned key-combination hook probe")
	ProbeWindow.AddEdit("w180 h30")
	ProbeWindow.Show("w200 h70")
	if !WinWaitActive("ahk_id " . ProbeWindow.Hwnd, , 1) || !ProbeAdmission()
		throw Error("The controlled hook probe could not admit its exact owned foreground.")
	ProbeDiagnostic("foreground-admitted")
	ProbeReceipt := A_Args[2] . "|" . ProbePid . "|" . ProbeThread . "|" . ProbeWindow.Hwnd
		. "|" . Format("{:08X}", ProbeHkl) . "|injected-registration`n"
	try {
		for _, Scenario in ["suppress", "native", "fallback"] {
			ProbeDiagnostic("scenario-" . Scenario)
			ProbePair := Scenario != "fallback"
			ProbeNative := Scenario == "native"
			for Kind in ProbeCounts
				ProbeCounts[Kind] := 0
			ProbeDown("LCtrl", "SC01D")
			ProbeDown("RAlt", "SC138")
			ProbeReleaseDiagnostic("sleep-before-release-enter")
			Sleep(80)
			ProbeReleaseDiagnostic("sleep-before-release-return")
			if ProbeRelease() != 0
				throw Error("The controlled hook probe retained injected modifier release debt.")
			ProbeReleaseDiagnostic("sleep-after-release-enter")
			Sleep(80)
			ProbeReleaseDiagnostic("sleep-after-release-return")
			if !ProbeAdmission()
				throw Error("The controlled hook observation lost its exact source/foreground fence.")
			ProbeReceipt .= Scenario . "|" . ProbeCounts["suppress"] . "|" . ProbeCounts["native"]
				. "|" . ProbeCounts["ordinary"] . "|" . ProbeCounts["fallback"] . "|" . ProbeOwned.Count . "`n"
		}
		FileAppend(ProbeReceipt, A_Args[1], "UTF-8-RAW")
	} finally {
		if ProbeRelease() == 0
			ProbeWindow.Destroy()
	}
}

ProbeAdmission() {
	global ProbeWindow, ProbePid, ProbeThread, ProbeHkl, ProbeOwned, ProbeFailed
	if ProbeFailed || !IsObject(ProbeWindow) || DllCall("GetForegroundWindow", "ptr") != ProbeWindow.Hwnd
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
	ProbeDiagnostic("down-" . Name)
}

ProbeRelease(*) {
	global ProbeOwned
	DiagnosticOk := ProbeReleaseDiagnostic("release-enter")
	for _, Name in ["RAlt", "LCtrl"] {
		if !ProbeOwned.Has(Name)
			continue
		try {
			SendLevel(3)
			if !ProbeReleaseDiagnostic("release-edge-begin-" . Name)
				DiagnosticOk := false
			SendEvent("{Blind}{" . (Name == "RAlt" ? "SC138" : "SC01D") . " Up}")
			if !ProbeReleaseDiagnostic("release-edge-return-" . Name)
				DiagnosticOk := false
			ProbeOwned.Delete(Name)
		} catch Error as Err {
			if !ProbeReleaseDiagnostic("release-failed-" . Name, Err.Message . "`n")
				DiagnosticOk := false
		}
	}
	if !ProbeReleaseDiagnostic("release-complete")
		DiagnosticOk := false
	return ProbeOwned.Count == 0 && DiagnosticOk ? 0 : 1
}

; A runtime error inside OnExit terminates the process instead of honoring its
; release-debt veto. A refused observer therefore latches failure and returns;
; it must not throw, call ExitApp or prevent remaining owned Up attempts.
ProbeReleaseDiagnostic(Stage, Detail := "") {
	global ProbeFailed, ProbeDiagnosticError
	try ProbeDiagnostic(Stage, Detail)
	catch Error as Err {
		ProbeFailed := true
		ProbeDiagnosticError := Err.Message
		return false
	}
	return true
}

ProbeHasFocus() {
	global ProbeWindow, ProbePid, ProbeThread, ProbeHkl, ProbeFailed
	if ProbeFailed || !IsObject(ProbeWindow) || DllCall("GetForegroundWindow", "ptr") != ProbeWindow.Hwnd
		return false
	Pid := 0
	Thread := DllCall("GetWindowThreadProcessId", "ptr", ProbeWindow.Hwnd, "uint*", &Pid, "uint")
	return Pid == ProbePid && Thread == ProbeThread
		&& ProbeHkl == 0x04090409 && DllCall("GetKeyboardLayout", "uint", 0, "ptr") == ProbeHkl
}

KeyCombinationOwnsHotkey() {
	return _KCT_ProbeOrdinaryOwner(A_ThisHotkey, ProbeHasFocus())
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
