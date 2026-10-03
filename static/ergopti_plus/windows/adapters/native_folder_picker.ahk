; adapters/native_folder_picker.ahk
;
; ==============================================================================
; MODULE: Native Folder Picker ABI Adapter
; DESCRIPTION:
; Owns Windows folder-dialog ABI calls and native resource primitives.
; Caption policy, callback provenance and invocation settlement remain in infra.
; ==============================================================================

#Requires AutoHotkey v2.0

/**
 * Owns the Windows ABI; application caption policy lives in Ui_DirSelect.
 */
class _Ui_FolderNative {
	static InitCom() {
		return DllCall("Ole32\CoInitializeEx", "Ptr", 0, "UInt", 2, "Int")
	}
	static ReleaseCom() {
		DllCall("Ole32\CoUninitialize")
	}
	static ProcessId() {
		return DllCall("Kernel32\GetCurrentProcessId", "UInt")
	}
	static ThreadId() {
		return DllCall("Kernel32\GetCurrentThreadId", "UInt")
	}
	static ExistsWindow(Hwnd) {
		return Hwnd && DllCall("User32\IsWindow", "Ptr", Hwnd)
	}
	static ClaimWindow(Hwnd, Cookie) {
		if DllCall("User32\GetPropW", "Ptr", Hwnd, "Str", "NativeFolderPickerLease", "Ptr")
			return false
		return DllCall("User32\SetPropW", "Ptr", Hwnd,
			"Str", "NativeFolderPickerLease", "Ptr", Cookie, "Int") != 0
	}
	static OwnsWindow(Hwnd, Cookie) {
		return DllCall("User32\GetPropW", "Ptr", Hwnd,
			"Str", "NativeFolderPickerLease", "Ptr") == Cookie
	}
	static MatchesWindow(Hwnd, ProcessId, ThreadId) {
		if !Hwnd || !DllCall("User32\IsWindow", "Ptr", Hwnd)
			return false
		WindowProcess := 0
		WindowThread := DllCall("User32\GetWindowThreadProcessId", "Ptr", Hwnd,
			"UInt*", &WindowProcess, "UInt")
		return WindowProcess == ProcessId && WindowThread == ThreadId
	}
	static ParseRoot(Path, &Pidl) {
		Pidl := 0
		return DllCall("Shell32\SHParseDisplayName", "Str", Path, "Ptr", 0,
			"Ptr*", &Pidl, "UInt", 0, "Ptr", 0, "Int")
	}
	static FreePidl(Pidl) {
		DllCall("Ole32\CoTaskMemFree", "Ptr", Pidl)
	}
	static MakeCallback(Function) {
		return CallbackCreate(Function, "F", 4)
	}
	static FreeCallback(Address) {
		CallbackFree(Address)
	}
	static Browse(Info) {
		return DllCall("Shell32\SHBrowseForFolderW", "Ptr", Info, "Ptr")
	}
	static SetCaption(Hwnd, Caption) {
		return DllCall("User32\SetWindowTextW", "Ptr", Hwnd, "Str", Caption, "Int") != 0
	}
	static SetInitial(Hwnd, Initial) {
		; BFFM_SETSELECTIONW uses a pathname, rather than a PIDL, when wParam is TRUE.
		DllCall("User32\SendMessageW", "Ptr", Hwnd, "UInt", 0x467,
			"Ptr", 1, "Str", Initial, "Ptr")
	}
	static Close(Hwnd) {
		return DllCall("User32\PostMessageW", "Ptr", Hwnd, "UInt", 0x10,
			"Ptr", 0, "Ptr", 0, "Int") != 0
	}
	static PathFromPidl(Pidl) {
		; This is the same MAX_PATH filesystem projection used by native DirSelect.
		Path := Buffer(520, 0)
		if !DllCall("Shell32\SHGetPathFromIDListW", "Ptr", Pidl, "Ptr", Path, "Int")
			return ""
		return StrGet(Path, "UTF-16")
	}
}

