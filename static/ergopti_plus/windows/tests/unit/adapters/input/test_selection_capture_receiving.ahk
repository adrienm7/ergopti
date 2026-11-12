; tests/unit/adapters/input/test_selection_capture_receiving.ahk

; ==============================================================================
; MODULE: Selection Capture Receiving Scenarios
; DESCRIPTION:
; The native receiving scenario of WCP-001 (docs/audits/platform-parity/
; 2026-11-04-flows/windows-clipboard): a selection transform starts on one real
; window, the real foreground changes to another one while the real clipboard
; snapshot is taken, and the capture must refuse before it clears the real
; clipboard or sends its copy chord. The copy chord is the one recorded port:
; the scenario never types into the desktop; the window, focus, clipboard,
; snapshot, owned transaction and restore are all the real ones.
; The control keeps the foreground: the capture clears the clipboard, a copy
; arrives the way an application answers Ctrl+C, the text is delivered and the
; user's clipboard comes back.
; Registered as interactive: they take the foreground and the clipboard.
; ==============================================================================

#Requires AutoHotkey v2.0

; How long a window may take to become the foreground one, in seconds.
global PWRS_ACTIVATE_TIMEOUT_S := 3
; How long the control's capture may take to deliver and restore, in ms.
global PWRS_CAPTURE_TIMEOUT_MS := 5000

; Two real top-level windows of this process, the first one with its text
; field focused; restores the user's clipboard and foreground afterwards.
_PWRS_WithWindows(Body) {
	global PWRS_ACTIVATE_TIMEOUT_S
	ReceivingProfileRoot()
	Previous := WinExist("A")
	SavedClipboard := ClipboardAll()
	Source := Gui("+AlwaysOnTop", "Ergopti receiving selection source")
	Field := Source.AddEdit("w300", "receiving selected text")
	Other := Gui("+AlwaysOnTop", "Ergopti receiving other window")
	Other.AddText(, "another application")
	try {
		Source.Show("x40 y40 NoActivate")
		Other.Show("x420 y40 NoActivate")
		WinActivate("ahk_id " . Source.Hwnd)
		AssertTrue(WinWaitActive("ahk_id " . Source.Hwnd, , PWRS_ACTIVATE_TIMEOUT_S), "positive control: the source window is the foreground")
		Field.Focus()
		Body(Source, Other)
	} finally {
		Source.Destroy()
		Other.Destroy()
		A_Clipboard := SavedClipboard
		if Previous && WinExist("ahk_id " . Previous)
			WinActivate("ahk_id " . Previous)
	}
}

; The foreground moves to another window while the snapshot is taken: the
; capture refuses with no clear, no copy chord and no delivery.
_PWRS_ForegroundChangeRefusesFirst() {
	_PWRS_WithWindows(Body)
	Body(Source, Other) {
		global PWRS_ACTIVATE_TIMEOUT_S
		Sentinel := "receiving-user-copy-" . A_TickCount
		A_Clipboard := Sentinel
		Sequence := DllCall("GetClipboardSequenceNumber", "UInt")
		Sends := []
		Delivered := []
		Switched := false
		SaveThenSwitch() {
			Snapshot := CB_SaveAll()
			WinActivate("ahk_id " . Other.Hwnd)
			Switched := WinWaitActive("ahk_id " . Other.Hwnd, , PWRS_ACTIVATE_TIMEOUT_S) != 0
			return Snapshot
		}
		Ports := Map("save", SaveThenSwitch, "send", () => Sends.Push(WinExist("A")))
		Started := GetSelectionAsync((Text, *) => Delivered.Push(Text), Ports)
		AssertTrue(Switched, "positive control: the real foreground changed during the snapshot")
		AssertFalse(Started, "the capture refuses before touching the clipboard (WCP-001)")
		AssertEqual(0, Sends.Length, "no copy chord went to the new foreground window")
		AssertEqual(Sequence, DllCall("GetClipboardSequenceNumber", "UInt"), "the real clipboard was never cleared or written")
		AssertEqual(Sentinel, A_Clipboard, "the user's copy is intact")
		Sleep(200)
		AssertEqual(0, Delivered.Length, "nothing is delivered")
	}
}
Test("selection capture receiving: a real foreground change during the snapshot refuses before the clipboard (phys-w-receiving-selection-focus)",
	_PWRS_ForegroundChangeRefusesFirst, true)

; Control: the foreground stays; the capture clears the real clipboard, the
; copy arrives as an application's answer to Ctrl+C, the text is delivered
; and the user's clipboard is restored.
_PWRS_UnchangedForegroundDelivers() {
	_PWRS_WithWindows(Body)
	Body(Source, Other) {
		global PWRS_CAPTURE_TIMEOUT_MS
		Sentinel := "receiving-user-copy-" . A_TickCount
		A_Clipboard := Sentinel
		Sends := []
		Delivered := []
		Answer() {
			Sends.Push(WinExist("A"))
			AssertEqual("", A_Clipboard, "the clipboard was cleared before the copy chord")
			A_Clipboard := "receiving selected text"
		}
		Started := GetSelectionAsync((Text, *) => Delivered.Push(Text), Map("send", Answer))
		AssertTrue(Started, "the capture starts")
		AssertEqual(1, Sends.Length, "one copy chord")
		AssertEqual(Source.Hwnd, Sends[1], "aimed at the source window")
		Begin := A_TickCount
		while ((Delivered.Length == 0 || A_Clipboard !== Sentinel) && A_TickCount - Begin < PWRS_CAPTURE_TIMEOUT_MS)
			Sleep(20)
		AssertEqual(1, Delivered.Length, "the selection is delivered once")
		AssertEqual("receiving selected text", Delivered[1], "with the copied text")
		AssertEqual(Sentinel, A_Clipboard, "the user's clipboard is restored")
	}
}
Test("selection capture receiving: an unchanged foreground delivers the copy and restores the clipboard (phys-w-receiving-selection-focus)",
	_PWRS_UnchangedForegroundDelivers, true)
