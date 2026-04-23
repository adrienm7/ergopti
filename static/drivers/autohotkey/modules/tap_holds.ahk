; static/drivers/autohotkey/lib/tap_holds.ahk

; ==============================================================================
; MODULE: Tap-Holds, One-Shot Shift and Navigation Layer
; DESCRIPTION:
; Implements tap-hold behaviours for CapsLock, LShift, LCtrl, LAlt, Space,
; AltGr, RCtrl and Tab keys. Also contains the One-Shot Shift mechanism and
; the full navigation layer (arrows, window management, volume…).
; ==============================================================================




; ==============================
; ==============================
; ======= 1/ CAPSLOCK =======
; ==============================
; ==============================

; Fix for using the LAltCapsLockShortcut with LAlt remapped to OneShotShift and CapsLock not remapped
#HotIf (
	Features["TapHolds"]["LAlt"]["OneShotShift"].Enabled
	and not Features["TapHolds"]["CapsLock"]["BackSpace"]
	and not CapsLockRemappedCondition()
	and not LayerEnabled
)
SC03A:: {
	if (GetKeyState("SC038", "P")) {
		LAltCapsLockShortcut()
		return
	}
	ToggleCapsLock()
}
#HotIf

#HotIf Features["TapHolds"]["CapsLock"]["BackSpace"].Enabled and not LayerEnabled
*SC03A:: {
	if (GetKeyState("SC038", "P")) {
		LAltCapsLockShortcut()
		return
	}

	SendEvent("{Blind}{BackSpace}")
}
#HotIf

CapsLockRemappedCondition() {
	return (
		Features["TapHolds"]["CapsLock"]["BackSpaceCtrl"].Enabled
		or Features["TapHolds"]["CapsLock"]["CapsLockCtrl"].Enabled
		or Features["TapHolds"]["CapsLock"]["CapsWordCtrl"].Enabled
		or Features["TapHolds"]["CapsLock"]["CtrlBackSpaceCtrl"].Enabled
		or Features["TapHolds"]["CapsLock"]["CtrlDeleteCtrl"].Enabled
		or Features["TapHolds"]["CapsLock"]["DeleteCtrl"].Enabled
		or Features["TapHolds"]["CapsLock"]["EnterCtrl"].Enabled
		or Features["TapHolds"]["CapsLock"]["EscapeCtrl"].Enabled
		or Features["TapHolds"]["CapsLock"]["OneShotShiftCtrl"].Enabled
		or Features["TapHolds"]["CapsLock"]["TabCtrl"].Enabled
	)
}

#HotIf CapsLockRemappedCondition() and not LayerEnabled
*SC03A:: {
	CtrlActivated := False
	if (GetKeyState("SC01D", "P")) {
		CtrlActivated := True
	}

	if (GetKeyState("SC038", "P")) {
		; Fix for using the LAltCapsLockShortcut with LAlt remapped to OneShotShift and CapsLock remapped
		LAltCapsLockShortcut()
		return
	}

	SendEvent("{LCtrl Down}")
	tap := KeyWait("CapsLock", "T" . Features["TapHolds"]["CapsLock"]["__Configuration"].TimeActivationSeconds)
	if (tap and A_PriorKey == "LControl") {
		SendEvent("{LCtrl Up}")
		CapsLockShortcut(CtrlActivated)
	}
	SendEvent("{LCtrl Up}")
}
#HotIf

CapsLockShortcut(CtrlActivated) {
	if CtrlActivated {
		SendEvent("{LCtrl Down}")
	}

	if Features["TapHolds"]["CapsLock"]["BackSpaceCtrl"].Enabled {
		SendEvent("{Blind}{BackSpace}")
	} else if Features["TapHolds"]["CapsLock"]["CapsLockCtrl"].Enabled {
		ToggleCapsLock()
	} else if Features["TapHolds"]["CapsLock"]["CapsWordCtrl"].Enabled {
		ToggleCapsWord()
	} else if Features["TapHolds"]["CapsLock"]["CtrlBackSpaceCtrl"].Enabled {
		SendInput("^{BackSpace}")
	} else if Features["TapHolds"]["CapsLock"]["CtrlDeleteCtrl"].Enabled {
		SendInput("^{Delete}")
	} else if Features["TapHolds"]["CapsLock"]["DeleteCtrl"].Enabled {
		SendEvent("{Blind}{Delete}")
	} else if Features["TapHolds"]["CapsLock"]["EnterCtrl"].Enabled {
		SendEvent("{Blind}{Enter}")
		DisableCapsWord()
	} else if Features["TapHolds"]["CapsLock"]["EscapeCtrl"].Enabled {
		SendEvent("{Blind}{Escape}")
	} else if Features["TapHolds"]["CapsLock"]["OneShotShiftCtrl"].Enabled {
		OneShotShift()
	} else if Features["TapHolds"]["CapsLock"]["TabCtrl"].Enabled {
		SendEvent("{Blind}{Tab}")
	}

	SendEvent("{LCtrl Up}")
}


; ==========================================
; ==========================================
; ======= 2/ LSHIFT AND LCTRL =======
; ==========================================
; ==========================================

#HotIf Features["TapHolds"]["LShiftCopy"].Enabled and not LayerEnabled
; Tap-hold on "LShift" : Ctrl + C on tap, Shift on hold
~$SC02A::
{
	TimeBefore := A_TickCount
	KeyWait("SC02A")
	TimeAfter := A_TickCount
	tap := ((TimeAfter - TimeBefore) <= Features["TapHolds"]["LShiftCopy"].TimeActivationSeconds * 1000)
	if (
		tap
		and (TimeAfter - TimeBefore) >= 50
		and A_PriorKey == "LShift"
	) { ; A_PriorKey is to be able to fire shortcuts very quickly, under the tap time
		SendInput("{LCtrl Down}c{LCtrl Up}")
	}
}
#HotIf

#HotIf Features["TapHolds"]["LCtrlPaste"].Enabled and not LayerEnabled
; This bug seems resolved now:
; « ~ must not be used here, otherwise [AltGr] [AltGr] … [AltGr], which is supposed to give Tab multiple times, will suddenly block and keep LCtrl activated »

; Tap-hold on "LControl" : Ctrl + V on tap, Ctrl on hold
~$SC01D::
{
	UpdateLastSentCharacter("LControl")
	TimeBefore := A_TickCount
	KeyWait("SC01D")
	TimeAfter := A_TickCount
	tap := ((TimeAfter - TimeBefore) <= Features["TapHolds"]["LCtrlPaste"].TimeActivationSeconds * 1000)
	if (
		tap
		and (TimeAfter - TimeBefore) >= 50
		and A_PriorKey == "LControl"
		and not GetKeyState("SC03A", "P") ; "CapsLock"
		and not GetKeyState("SC038", "P") ; "LAlt"
	) {
		SendInput("{LCtrl Down}v{LCtrl Up}")
	}
}
#HotIf


; ==============================
; ==============================
; ======= 3/ LALT =======
; ==============================
; ==============================

#HotIf Features["TapHolds"]["LAlt"]["OneShotShift"].Enabled and not LayerEnabled
; Tap-hold on "LAlt" : OneShotShift on tap, Shift on hold
SC038:: {
	if (
		GetKeyState("SC11D", "P")
		or GetKeyState("SC03A", "P")
		or GetKeyState("LShift", "P")
		or GetKeyState("LCtrl", "P")
	) {
		; Solves a problem where shorcuts consisting of another key (pressed first) + SC038 (pressed second) triggers the shortcut, but also OneShotShift()
		return
	}

	SendEvent("{LAlt Up}")
	OneShotShift()
	SendInput("{LShift Down}")
	KeyWait("SC038")
	SendInput("{LShift Up}")
}
#HotIf

#HotIf Features["TapHolds"]["LAlt"]["TabLayer"].Enabled and not LayerEnabled
; Tap-hold on "LAlt" : Tab on tap, Layer on hold
SC038::
{
	UpdateLastSentCharacter("LAlt")

	ActivateLayer()
	KeyWait("SC038")
	DisableLayer()

	Now := A_TickCount
	CharacterSentTime := LastSentCharacterKeyTime.Has("LAlt") ? LastSentCharacterKeyTime["LAlt"] : Now
	tap := (Now - CharacterSentTime <= Features["TapHolds"]["LAlt"]["TabLayer"].TimeActivationSeconds * 1000)
	if tap {
		SendEvent("{Tab}")
	}
}

SC02A & SC038:: SendInput("+{Tab}") ; On "LShift"
if Features["TapHolds"]["RCtrl"]["OneShotShift"].Enabled {
	SC11D & SC038:: {
		OneShotShiftFix()
		SendInput("+{Tab}")
	}
}
#SC038:: SendEvent("#{Tab}") ; Doesn't fire when SendInput is used
!SC038:: SendInput("!{Tab}")
#HotIf

#HotIf Features["TapHolds"]["LAlt"]["AltTabMonitor"].Enabled and not LayerEnabled
; Tap-hold on "LAlt" : AltTabMonitor on tap, Alt on hold
SC038::
{
	Send("{LAlt Down}")
	tap := KeyWait("SC038", "T" . Features["TapHolds"]["LAlt"]["AltTabMonitor"].TimeActivationSeconds)
	if tap {
		Send("{LAlt Up}")
		AltTabMonitor()
	} else {
		KeyWait("SC038")
		Send("{LAlt Up}")
	}
}
#HotIf

#HotIf Features["TapHolds"]["LAlt"]["BackSpace"].Enabled and not LayerEnabled
; "LAlt" becomes BackSpace, and Delete on Shift
*SC038::
{
	BackSpaceActionWithModifiers := BackSpaceLogic()
	if not BackSpaceActionWithModifiers {
		; If no modifier was pressed
		SendEvent("{BackSpace}") ; Event to be able to correct hostrings and still trigger them afterwards
		Sleep(300) ; Delay before repeating the key
		while GetKeyState("SC038", "P") {
			SendEvent("{BackSpace}")
			Sleep(100)
		}
	}
}
#HotIf

#HotIf Features["TapHolds"]["LAlt"]["BackSpaceLayer"].Enabled and not LayerEnabled
; Tap-hold on "LAlt" : BackSpace on tap, Layer on hold
*SC038::
{
	UpdateLastSentCharacter("LAlt")

	ActivateLayer()
	KeyWait("SC038")
	DisableLayer()

	Now := A_TickCount
	CharacterSentTime := LastSentCharacterKeyTime.Has("LAlt") ? LastSentCharacterKeyTime["LAlt"] : Now
	tap := (Now - CharacterSentTime <= Features["TapHolds"]["LAlt"]["BackSpaceLayer"].TimeActivationSeconds * 1000)

	if (
		tap
		and A_PriorKey == "LAlt" ; Prevents triggering BackSpace when the layer is quickly used and then released
		and not GetKeyState("SC03A", "P") ; Fix a sent BackSpace when triggering quickly "LAlt" + "CapsLock"
	) {
		BackSpaceActionWithModifiers := BackSpaceLogic()
		if not BackSpaceActionWithModifiers {
			; If no modifier was pressed
			SendEvent("{BackSpace}")
		}
	}
}
#HotIf

BackSpaceLogic() {
	if (
		GetKeyState("SC01D", "P")
		and GetKeyState("Shift", "P")
	) {
		; "LCtrl" and Shift
		SendInput("^{Delete}")
		return True
	} else if (
		GetKeyState("SC11D", "P")
		and not Features["TapHolds"]["RCtrl"]["OneShotShift"].Enabled
		and GetKeyState("Shift", "P")
	) {
		; "RCtrl" when it stays RCtrl and Shift
		SendInput("^{Delete}")
		return True
	} else if (
		GetKeyState("SC01D", "P")
		and Features["TapHolds"]["RCtrl"]["OneShotShift"].Enabled
		and GetKeyState("SC11D", "P")
	) {
		; "LCtrl" and Shift on "RCtrl"
		OneShotShiftFix()
		SendInput("^{Right}^{BackSpace}") ; = ^Delete, but we cannot simply use Delete, as it would do Ctrl + Alt + Delete and Windows would interpret it
		return True
	} else if (
		Features["TapHolds"]["RCtrl"]["OneShotShift"].Enabled
		and GetKeyState("SC11D", "P")
	) {
		; Shift on "RCtrl"
		OneShotShiftFix()
		SendInput("{Right}{BackSpace}") ; = Delete, but we cannot simply use Delete, as it would do Ctrl + Alt + Delete and Windows would interpret it
		return True
	} else if GetKeyState("Shift", "P") {
		; Shift
		SendInput("{Delete}")
		return True
	} else if GetKeyState("SC01D", "P") {
		; "LCtrl"
		SendInput("^{BackSpace}")
		return True
	} else if (
		not Features["TapHolds"]["RCtrl"]["OneShotShift"].Enabled
		and GetKeyState("SC11D", "P")
	) {
		; "RCtrl" when it stays RCtrl
		SendInput("^{BackSpace}")
		return True
	}
	return False
}


; ==============================
; ==============================
; ======= 4/ SPACE =======
; ==============================
; ==============================

#HotIf Features["TapHolds"]["Space"]["Ctrl"].Enabled and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Ctrl on hold
SC039::
{
	ih := InputHook("L1 T" . Features["TapHolds"]["Space"]["Ctrl"].TimeActivationSeconds)
	ih.Start()
	ih.Wait()
	if ih.EndReason != "Timeout" {
		Text := ih.Input
		if ih.Input == " " {
			Text := "" ; To not send a double space
		}
		SendEvent("{Space}" Text)
		; SendEvent is used to be able to do testt{BS}★ ➜ test★ that will trigger the hotstring.
		; Otherwise, SendInput resets the hotstrings search
		UpdateLastSentCharacter(" ")
		return
	}

	SendEvent("{LCtrl Down}")
	KeyWait("SC039")
	SendEvent("{LCtrl Up}")
}
SC039 Up:: {
	if (
		A_PriorHotkey == "SC039"
		and not CapsWordEnabled ; Solves a bug of 2 sent Spaces when exiting CapsWord with a Space
		and A_TimeSinceThisHotkey <= Features["TapHolds"]["Space"]["Ctrl"].TimeActivationSeconds
	) {
		SendEvent("{Space}")
	}
}
#HotIf

#HotIf Features["TapHolds"]["Space"]["Layer"].Enabled and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Layer on hold
SC039::
{
	ih := InputHook("L1 T" . Features["TapHolds"]["Space"]["Layer"].TimeActivationSeconds)
	ih.Start()
	ih.Wait()
	if ih.EndReason != "Timeout" {
		Text := ih.Input
		if ih.Input == " " {
			Text := "" ; To not send a double space
		}
		SendEvent("{Space}" Text)
		; SendEvent is used to be able to do testt{BS}★ ➜ test★ that will trigger the hotstring.
		; Otherwise, SendInput resets the hotstrings search
		UpdateLastSentCharacter(" ")
		return
	}

	ActivateLayer()
	KeyWait("SC039")
	DisableLayer()
}
SC039 Up:: {
	if (
		A_PriorHotkey == "SC039"
		and not CapsWordEnabled ; Solves a bug of 2 sent Spaces when exiting CapsWord with a Space
		and A_TimeSinceThisHotkey <= Features["TapHolds"]["Space"]["Layer"].TimeActivationSeconds
	) {
		SendEvent("{Space}")
		UpdateLastSentCharacter(" ")
	}
}
#HotIf

#HotIf Features["TapHolds"]["Space"]["Shift"].Enabled and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Shift on hold
SC039::
{
	ih := InputHook("L1 T" . Features["TapHolds"]["Space"]["Shift"].TimeActivationSeconds)
	ih.Start()
	ih.Wait()
	if ih.EndReason != "Timeout" {
		Text := ih.Input
		if ih.Input == " " {
			Text := "" ; To not send a double space
		}
		SendEvent("{Space}" Text)
		; SendEvent is used to be able to do testt{BS}★ ➜ test★ that will trigger the hotstring.
		; Otherwise, SendInput resets the hotstrings search
		UpdateLastSentCharacter(" ")
		return
	}

	SendEvent("{LShift Down}")
	KeyWait("SC039")
	SendEvent("{LShift Up}")
}
SC039 Up:: {
	if (
		A_PriorHotkey == "SC039"
		and not CapsWordEnabled ; Solves a bug of 2 sent Spaces when exiting CapsWord with a Space
		and A_TimeSinceThisHotkey <= Features["TapHolds"]["Space"]["Shift"].TimeActivationSeconds
	) {
		SendEvent("{Space}")
	}
}
#HotIf


; ==============================
; ==============================
; ======= 5/ ALTGR =======
; ==============================
; ==============================

#HotIf (
	not LayerEnabled
	and (
		Features["TapHolds"]["AltGr"]["BackSpace"].Enabled
		or Features["TapHolds"]["AltGr"]["CapsLock"].Enabled
		or Features["TapHolds"]["AltGr"]["CapsWord"].Enabled
		or Features["TapHolds"]["AltGr"]["CtrlBackSpace"].Enabled
		or Features["TapHolds"]["AltGr"]["CtrlDelete"].Enabled
		or Features["TapHolds"]["AltGr"]["Delete"].Enabled
		or Features["TapHolds"]["AltGr"]["Enter"].Enabled
		or Features["TapHolds"]["AltGr"]["Escape"].Enabled
		or Features["TapHolds"]["AltGr"]["OneShotShift"].Enabled
		or Features["TapHolds"]["AltGr"]["Tab"].Enabled
	)
)
; Tap-hold on "AltGr"
SC01D & ~SC138:: ; LControl & RAlt is the only way to make it fire on tap directly
RAlt:: ; Necessary to work on layouts like QWERTY
{
	tap := KeyWait("RAlt", "T" . Features["TapHolds"]["AltGr"]["__Configuration"].TimeActivationSeconds)
	if (tap and (A_PriorKey == "RAlt" or A_PriorKey == "^")) {
		DisableCapsWord()
		if Features["TapHolds"]["AltGr"]["BackSpace"].Enabled {
			SendEvent("{Blind}{BackSpace}") ; SendEvent be able to trigger hotstrings
			UpdateLastSentCharacter("BackSpace")
		} else if Features["TapHolds"]["AltGr"]["CapsLock"].Enabled {
			ToggleCapsLock()
		} else if Features["TapHolds"]["AltGr"]["CapsWord"].Enabled {
			ToggleCapsWord()
		} else if Features["TapHolds"]["AltGr"]["CtrlBackSpace"].Enabled {
			SendEvent("{Blind}^{BackSpace}")
			UpdateLastSentCharacter("")
		} else if Features["TapHolds"]["AltGr"]["CtrlDelete"].Enabled {
			SendEvent("{Blind}^{Delete}")
			UpdateLastSentCharacter("")
		} else if Features["TapHolds"]["AltGr"]["Delete"].Enabled {
			SendEvent("{Blind}{Delete}")
			UpdateLastSentCharacter("Delete")
		} else if Features["TapHolds"]["AltGr"]["Enter"].Enabled {
			SendEvent("{Blind}{Enter}") ; SendEvent be able to trigger hotstrings with a Enter ending character
			UpdateLastSentCharacter("Enter")
		} else if Features["TapHolds"]["AltGr"]["Escape"].Enabled {
			SendEvent("{Escape}")
		} else if Features["TapHolds"]["AltGr"]["OneShotShift"].Enabled {
			OneShotShift()
		} else if Features["TapHolds"]["AltGr"]["Tab"].Enabled {
			SendEvent("{Blind}{Tab}") ; SendEvent be able to trigger hotstrings with a Tab ending character
			UpdateLastSentCharacter("Tab")
		}
	}
}

SC01D & ~SC138 Up::
RAlt Up:: {
	UpdateLastSentCharacter("")
}
#HotIf


; ==============================
; ==============================
; ======= 6/ RCTRL =======
; ==============================
; ==============================

#HotIf Features["TapHolds"]["RCtrl"]["BackSpace"].Enabled and not LayerEnabled
; RCtrl becomes BackSpace, and Delete on Shift
SC11D::
{
	if GetKeyState("LShift", "P") {
		SendInput("{Delete}")
	} else if Features["TapHolds"]["LAlt"]["OneShotShift"].Enabled and GetKeyState("SC038", "P") {
		OneShotShiftFix()
		SendInput("{Right}{BackSpace}") ; = Delete, but we cannot simply use Delete, as it would do Ctrl + Alt + Delete and Windows would interpret it
	} else {
		SendEvent("{BackSpace}") ; Event to be able to correct hostrings and still trigger them afterwards
		Sleep(300) ; Delay before repeating the key
		while GetKeyState("SC11D", "P") {
			SendEvent("{BackSpace}")
			Sleep(100)
		}
	}
}
#HotIf

#HotIf Features["TapHolds"]["RCtrl"]["Tab"].Enabled and not LayerEnabled
; Tap-hold on "RCtrl" : Tab on tap, Ctrl on hold
~SC11D:: {
	tap := KeyWait("RControl", "T" . Features["TapHolds"]["RCtrl"]["Tab"].TimeActivationSeconds)
	if (tap and A_PriorKey == "RControl") {
		SendEvent("{RCtrl Up}")
		SendEvent("{Tab}") ; To be able to trigger hotstrings with a Tab ending character
	}
}

+SC11D:: SendInput("+{Tab}")
^SC11D:: SendInput("^{Tab}")
^+SC11D:: SendInput("^+{Tab}")
#SC11D:: SendEvent("#{Tab}") ; SendInput doesn't work in that case
#HotIf

#HotIf Features["TapHolds"]["RCtrl"]["OneShotShift"].Enabled and not LayerEnabled
; Tap-hold on "RCtrl" : OneShotShift on tap, Shift on hold
SC11D:: {
	OneShotShift()
	SendEvent("{LShift Down}")
	KeyWait("SC11D")
	SendEvent("{LShift Up}")
}
#HotIf


; ==============================
; ==============================
; ======= 7/ TAB =======
; ==============================
; ==============================

#HotIf Features["TapHolds"]["TabAlt"].Enabled and not LayerEnabled
; Tap-hold on "Tab": Alt + Tab on tap, Alt on hold
SC00F::LAlt
SC00F::
{
	SendInput("{LAlt Down}")
	tap := KeyWait("SC00F", "T" . Features["TapHolds"]["TabAlt"].TimeActivationSeconds)
	if tap {
		if Features["TapHolds"]["LAlt"]["TabLayer"].Enabled and GetKeyState("SC038", "P") {
			SendInput("!{Tab}")
		} else {
			SendInput("{LAlt Up}")
			AltTabMonitor()
		}

	}
}
SC00F Up:: SendInput("{LAlt Up}")
#HotIf

AltTabMonitor() {
	CoordMode("Mouse", "Screen")
	MouseGetPos(&MousePosX, &MousePosY)
	MonitorNum := GetMonitorFromPoint(MousePosX, MousePosY)
	if MonitorNum == 0 {
		return ; No monitor found
	}

	CurrentWindowId := WinExist("A")
	AppWindowsOnMonitorFiltered := []

	for WindowId in WinGetList() {
		; Skip the currently active window
		if WindowId == CurrentWindowId {
			continue
		}

		; Get window position and size
		WinGetPos(&x, &y, &w, &h, WindowId)

		; Filter out windows that are too small to be usable
		if (w < 100 || h < 100) {
			continue
		}

		; Determine which monitor contains the center of the window
		CenterX := x + w // 2
		CenterY := y + h // 2
		if GetMonitorFromPoint(CenterX, CenterY) != MonitorNum {
			continue ; Window is not on the target monitor
		}

		; Skip windows with no title — often tooltips, overlays, or hidden UI elements, and when dragging files, and windows when a file operation is happening
		if WinGetTitle(WindowId) == "" or WinGetTitle(WindowId) == "Drag" or WinGetClass(WindowId) ==
		"OperationStatusWindow" {
			continue
		}

		; Exclude known system window classes:
		; - Shell_TrayWnd: Windows taskbar
		; - Progman: desktop background
		; - WorkerW: hidden background windows
		if ["Shell_TrayWnd", "Progman", "WorkerW"].Has(WinGetClass(WindowId)) {
			continue
		}

		; WindowId passed all filters — add to list
		AppWindowsOnMonitorFiltered.Push(WindowId)
	}

	; Activate the first relevant window found
	if AppWindowsOnMonitorFiltered.Length > 0 {
		WinActivate(AppWindowsOnMonitorFiltered[1])
	}
}

GetMonitorFromPoint(X, Y) {
	MonitorCount := MonitorGetCount()

	loop MonitorCount {
		; Get the monitor's rectangle bounding coordinates, for monitor number A_Index
		MonitorGet(A_Index, &MonitorLeft, &MonitorTop, &MonitorRight, &MonitorBottom)

		; Check if the mouse is inside the monitor
		if (X >= MonitorLeft && X < MonitorRight && Y >= MonitorTop && Y <
			MonitorBottom) {
			return A_Index
		}
	}

	return 0 ; No monitor found
}


; ========================================
; ========================================
; ======= 8/ ONE-SHOT SHIFT =======
; ========================================
; ========================================

OneShotShift() {
	global OneShotShiftEnabled := True
	ihvText := InputHook("L1 T2 E", "=%$.', " . ScriptInformation["MagicKey"])
	ihvText.KeyOpt("{BackSpace}{Enter}{Delete}", "E") ; End keys to not swallow
	ihvText.Start()
	ihvText.Wait()
	SpecialCharacter := ""

	if (ihvText.EndKey == "=") {
		SpecialCharacter := "º"
	} else if (ihvText.EndKey == "%") {
		SpecialCharacter := " %"
	} else if (ihvText.EndKey == "$") {
		SpecialCharacter := " €"
	} else if (ihvText.EndKey == ".") {
		SpecialCharacter := " :"
	} else if (ihvText.EndKey == ScriptInformation["MagicKey"]) {
		SpecialCharacter := "J" ; OneShotShift + ★ gives J directly
	} else if (ihvText.EndKey == ",") {
		SpecialCharacter := " " Chr(0x3B) ; Chr avoids AHK parser misreading ";" as comment
	} else if (ihvText.EndKey == "'") {
		SpecialCharacter := " ?"
	} else if (ihvText.EndKey == " ") {
		SpecialCharacter := "-"
	}

	if (ihvText == "Timeout") {
		return
	} else if SpecialCharacter != "" {
		if OneShotShiftEnabled {
			ActivateHotstrings()
			SendNewResult(SpecialCharacter)
		} else {
			SendNewResult(ihvText.EndKey)
		}
	} else {
		if OneShotShiftEnabled {
			TitleCaseText := Format("{:T}", ihvText.Input)
			SendNewResult(TitleCaseText)
		} else {
			SendNewResult(ihvText.Input)
		}
	}
}

OneShotShiftFix() {
	; This function and global variable solves a problem when we use the OneShotShift key as a modifier.
	; In that case, we first press this key, thus firing the OneShotShift() function that will uppercase the next character in the next 2 seconds.
	; The only way to disable it after it has fired is to modify this global variable by setting global OneShotShiftEnabled := False.
	; That way, calling this function OneShotShiftFix() won't uppercase the next character in our shortcuts involving the OneShotShift key.
	global OneShotShiftEnabled := False
}

ToggleCapsLock() {
	global CapsWordEnabled := False
	if GetKeyState("CapsLock", "T") {
		SetCapsLockState("Off")
	} else {
		SetCapsLockState("On")
	}
}


; ==========================================
; ==========================================
; ======= 9/ NAVIGATION LAYER =======
; ==========================================
; ==========================================

ActivateLayer() {
	global LayerEnabled := True
	ResetNumberOfRepetitions()
	UpdateCapsLockLED()
}
DisableLayer() {
	global LayerEnabled := False
	A_MaxHotkeysPerInterval := 150 ; Restore old value
	UpdateCapsLockLED()
}
ResetNumberOfRepetitions() {
	SetNumberOfRepetitions(1)
}
SetNumberOfRepetitions(NewNumber) {
	global NumberOfRepetitions := NewNumber
}
ActionLayer(action) {
	SendInput(action)
	ResetNumberOfRepetitions()
}

; Fix to get the CapsWord shortcut working when pressing "LAlt" activates the layer
#HotIf (LayerEnabled
	and (
		Features["TapHolds"]["LAlt"]["BackSpaceLayer"].Enabled
		or Features["TapHolds"]["LAlt"]["TabLayer"].Enabled
	) and (
		Features["Shortcuts"]["LAltCapsLock"]["BackSpace"].Enabled
		or Features["Shortcuts"]["LAltCapsLock"]["CapsLock"].Enabled
		or Features["Shortcuts"]["LAltCapsLock"]["CapsWord"].Enabled
		or Features["Shortcuts"]["LAltCapsLock"]["CtrlBackSpace"].Enabled
		or Features["Shortcuts"]["LAltCapsLock"]["CtrlDelete"].Enabled
		or Features["Shortcuts"]["LAltCapsLock"]["Delete"].Enabled
		or Features["Shortcuts"]["LAltCapsLock"]["OneShotShift"].Enabled
	)
)
; Overrides the "BackSpace" shortcut on the layer
SC03A:: {
	DisableLayer() LAltCapsLockShortcut()
}
#HotIf

; Fix when LAlt triggers the layer
#HotIf (
	Features["TapHolds"]["LAlt"]["BackSpaceLayer"].Enabled
	and LayerEnabled
)
SC038:: SendInput("{LAlt Up}") ; Necessary to do this, otherwise multicursor triger in VSCode when scrolling in the layer and then leaving it
#HotIf

; Fix when Space triggers the layer
#HotIf (
	Features["TapHolds"]["Space"]["Layer"].Enabled
	and LayerEnabled
)
SC039:: return ; Necessary to do this, otherwise Space keeps being sent while it is held to get the layer
#HotIf

#HotIf LayerEnabled
; The base layer will become this one when the navigation layer variable is set to True

*WheelUp:: {
	A_MaxHotkeysPerInterval := 1000 ; Reduce messages saying too many hotkeys pressed in the interval
	ActionLayer("{Volume_Up " . NumberOfRepetitions . "}") ; Turn on the volume by scrolling up
}
*WheelDown:: {
	A_MaxHotkeysPerInterval := 1000 ; Reduce messages saying too many hotkeys pressed in the interval
	ActionLayer("{Volume_Down " . NumberOfRepetitions . "}") ; Turn down the volume by scrolling down
}

SC01D & ~SC138:: ; RAlt
RAlt:: ; RAlt on QWERTY
{
	ActionLayer("{Escape " . NumberOfRepetitions . "}")
}

; === Number row ===
SC002:: SetNumberOfRepetitions(1) ; On key 1
SC003:: SetNumberOfRepetitions(2) ; On key 2
SC004:: SetNumberOfRepetitions(3) ; On key 3
SC005:: SetNumberOfRepetitions(4) ; On key 4
SC006:: SetNumberOfRepetitions(5) ; On key 5
SC007:: SetNumberOfRepetitions(6) ; On key 6
SC008:: SetNumberOfRepetitions(7) ; On key 7
SC009:: SetNumberOfRepetitions(8) ; On key 8
SC00A:: SetNumberOfRepetitions(9) ; On key 9
SC00B:: SetNumberOfRepetitions(10) ; On key 0

; ======= Left hand =======

; === Top row ===
SC010:: ActionLayer("^+{Home}") ; Select to the beginning of the document
SC011:: ActionLayer("^{Home}") ; Go to the beginning of the document
SC012:: ActionLayer("^{End}") ; Go to the end of the document
SC013:: ActionLayer("^+{End}") ; Select to the end of the document
SC014:: ActionLayer("{F2}")

; === Middle row ===
SC03A:: ActionLayer(Format("{BackSpace {1}}", NumberOfRepetitions)) ; "CapsLock" becomes BackSpace
SC01E:: ActionLayer(Format("^+{Up {1}}", NumberOfRepetitions))
SC01F:: ActionLayer(Format("{Up {1}}", NumberOfRepetitions)) ; ⇧
SC020:: ActionLayer(Format("{Down {1}}", NumberOfRepetitions)) ; ⇩
SC021:: ActionLayer(Format("^+{Down {1}}", NumberOfRepetitions))
SC022:: ActionLayer("{F12}")

; === Bottom row ===
SC056:: ActionLayer(Format("!+{Up {1}}", NumberOfRepetitions))  ; Duplicate the line up
SC02C:: ActionLayer(Format("!{Up {1}}", NumberOfRepetitions)) ; Move the line up
SC02D:: ActionLayer(Format("!{Down {1}}", NumberOfRepetitions)) ; Move the line down
SC02E:: ActionLayer(Format("!+{Down {1}}", NumberOfRepetitions)) ; Duplicate the line down
SC02F:: ActionLayer(Format("{End}{Enter {1}}", NumberOfRepetitions)) ; Start a new line below the cursor
; SC030:: ; On K

; ======= Right hand =======

; === Top row ===
SC015:: ActionLayer("+{Home}") ; Select everything to the beginning of the line
SC016:: ActionLayer(Format("^+{Left {1}}", NumberOfRepetitions)) ; Select the previous word
SC017:: ActionLayer(Format("+{Left {1}}", NumberOfRepetitions)) ; Select the previous character
SC018:: ActionLayer(Format("+{Right {1}}", NumberOfRepetitions)) ; Select the next character
SC019:: ActionLayer(Format("^+{Right {1}}", NumberOfRepetitions)) ; Select the next word
SC01A:: ActionLayer("+{End}") ; Select everything to the end of the line

; === Middle row ===
SC023:: ActionLayer("#+{Left}") ; Move the window to the left screen
SC024:: ActionLayer(Format("^{Left {1}}", NumberOfRepetitions)) ; Move to the previous word
SC025:: ActionLayer(Format("{Left {1}}", NumberOfRepetitions)) ; ⇦
SC026:: ActionLayer(Format("{Right {1}}", NumberOfRepetitions)) ; ⇨
SC027:: ActionLayer(Format("^{Right {1}}", NumberOfRepetitions)) ; Move to the next word
SC028:: ActionLayer("#+{Right}") ; Move the window to the right screen

; === Bottom row ===
SC031:: WinMaximize("A") ; Make the window fullscreen
SC032:: ActionLayer("{Home}") ; Go to the beginning of the line
SC033:: ActionLayer("#{Left}") ; Move the window to the left of the current screen
SC034:: ActionLayer("#{Right}") ; Move the window to the right of the current screen
SC035:: ActionLayer("{End}") ; Go to the end of the line
#HotIf
