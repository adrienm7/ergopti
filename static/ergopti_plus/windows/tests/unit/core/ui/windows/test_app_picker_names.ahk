; tests/unit/core/ui/windows/test_app_picker_names.ahk

; ==============================================================================
; MODULE: Application Picker Names (PCK-21)
; DESCRIPTION:
; The application picker named a running process by the longest fragment of
; its window title, so a document name, a mail subject or a web page showed in
; the list. macOS shows bundle names and Linux application ids. A real window
; of this process, titled like a document, must show the executable's name.
; ==============================================================================

#Requires AutoHotkey v2.0

global _APN_PrivateTitle := "Quarterly salaries of the private team - Confidential draft"

_APN_NamesTheApplication() {
	global _APN_PrivateTitle
	Window := Gui("+ToolWindow", _APN_PrivateTitle)
	try {
		Window.Show("NoActivate w120 h80")
		Name := AppPicker_FriendlyName(Window.Hwnd)
		Expected := AppPicker_FileDescription(A_AhkPath)
		AssertTrue(Expected != "", "the AutoHotkey executable declares a description")
		AssertEqual(Expected, Name, "pck-21: a window shows its application's name")
		for Segment in StrSplit(_APN_PrivateTitle, " - ")
			AssertFalse(InStr(Name, Segment), "pck-21: no part of the window title is shown: " . Name)
		Rows := AppPicker_BuildRows(Map())
		for Row in Rows
			for Segment in StrSplit(_APN_PrivateTitle, " - ")
				AssertFalse(InStr(Row.display, Segment), "pck-21: no picker row shows a window title: " . Row.display)
	} finally Window.Destroy()
}
Test("app picker: a running application shows its name, never its window title (pck-21)", _APN_NamesTheApplication)

_APN_NoDescriptionShowsTheProcess() {
	AssertEqual("", AppPicker_FileDescription(A_WinDir . "\pck21-missing-executable.exe"),
		"a file without a version resource declares no description")
}
Test("app picker: a file without a description declares none (pck-21)", _APN_NoDescriptionShowsTheProcess)
