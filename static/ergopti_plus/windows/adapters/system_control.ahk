; adapters/system_control.ahk

; ==============================================================================
; MODULE: SystemControl Adapter (AutoHotkey)
; DESCRIPTION:
; The Win32, COM, registry and shell primitives the system actions
; (modules/gestures/system_actions.ahk) are built from: start a program, post
; a window message, broadcast a setting change, read and write a registry
; value, probe a registry key, name the script's session (the virtual desktop
; actions and the touchpad registry owner use these two), mute the default
; microphone, close a process, read the active window
; and the Explorer windows, create a file exclusively, delete a file's
; Zone.Identifier stream, move the pointer, and ask or tell the user.
;
; FEATURES & RATIONALE:
; 1. Thin on purpose: each method is one native call with the arguments the
;    module chose, so the module's suite pins the exact message numbers,
;    command lines and paths through a recording double of this class.
; 2. Launch() does not wait for the program. Defer() only lets the hotkey or
;    gesture thread that dispatched an action return first: the deferred
;    action still runs on the script's one OS thread, so while a COM call or
;    BroadcastSettingChange waits (at most its timeout per window), remapped
;    keys queue behind it. Anything that can wait longer belongs in a process.
; 3. Failures are reported, never swallowed: a method either returns its
;    documented failure value or throws, and the module logs it.
; ==============================================================================




; ======================================
; ======================================
; ======= 1/ Win32 Identifiers =========
; ======================================
; ======================================

; The default capture endpoint: eCapture, eConsole (mmdeviceapi.h).
global SYSTEM_CONTROL_E_CAPTURE := 1
global SYSTEM_CONTROL_E_CONSOLE := 0
; CLSCTX_ALL, the context IMMDevice::Activate is asked for.
global SYSTEM_CONTROL_CLSCTX_ALL := 0x17
; SendMessageTimeout: skip a hung window instead of waiting on it.
global SYSTEM_CONTROL_SMTO_ABORTIFHUNG := 0x2
; How long one window may take to process a broadcast setting change.
global SYSTEM_CONTROL_BROADCAST_TIMEOUT_MS := 1000
; CreateFileW for an exclusive creation.
global SYSTEM_CONTROL_GENERIC_WRITE := 0x40000000
global SYSTEM_CONTROL_CREATE_NEW := 1
global SYSTEM_CONTROL_FILE_ATTRIBUTE_NORMAL := 0x80
global SYSTEM_CONTROL_ERROR_FILE_NOT_FOUND := 2
global SYSTEM_CONTROL_ERROR_PATH_NOT_FOUND := 3
global SYSTEM_CONTROL_ERROR_FILE_EXISTS := 80
; RegOpenKeyExW: the predefined HKEY_CURRENT_USER handle and the least right
; that proves a key exists.
global SYSTEM_CONTROL_HKEY_CURRENT_USER := 0x80000001
global SYSTEM_CONTROL_KEY_QUERY_VALUE := 0x0001
; How long an activated window may take to come to the foreground.
global SYSTEM_CONTROL_ACTIVATE_WAIT_S := 1
; OpenProcess receives a process identifier as a native DWORD.
global SYSTEM_CONTROL_MAX_PROCESS_ID := 0xFFFFFFFF
; Least rights needed by a retained process target.
global SYSTEM_CONTROL_PROCESS_TERMINATE := 0x0001
global SYSTEM_CONTROL_PROCESS_QUERY_LIMITED_INFORMATION := 0x1000
global SYSTEM_CONTROL_SYNCHRONIZE := 0x00100000
global SYSTEM_CONTROL_WAIT_OBJECT_0 := 0
global SYSTEM_CONTROL_WAIT_TIMEOUT := 258





; ======================================
; ======================================
; ======= 2/ Adapter ===================
; ======================================
; ======================================

class SystemControl {
	; Starts a program or opens a target without waiting for it.
	; @param {String} Target Command line, path or URI.
	; @param {String} WorkingDir Directory it starts in ("" = inherited).
	; @param {String} Options Run options ("Hide", "Max", …).
	; @returns {Integer} The process id (0 when the shell did not report one).
	; @throws {Error} When Windows refuses the launch.
	Launch(Target, WorkingDir := "", Options := "") {
		Pid := 0
		Run(Target, WorkingDir, Options, &Pid)
		return Pid
	}

	; Posts one message to every top-level window, without waiting.
	; @returns {Boolean} Whether PostMessage accepted it.
	PostBroadcast(Msg, WParam, LParam) {
		return DllCall("PostMessageW", "Ptr", 0xFFFF, "UInt", Msg, "UPtr", WParam, "Ptr", LParam, "Int") != 0
	}

	; Posts WM_CLOSE to one window, as its own close button does.
	; @returns {Boolean} Whether PostMessage accepted it.
	PostClose(Hwnd) {
		return DllCall("PostMessageW", "Ptr", Hwnd, "UInt", 0x0010, "UPtr", 0, "Ptr", 0, "Int") != 0
	}

	; Broadcasts WM_SETTINGCHANGE for one settings area ("ImmersiveColorSet").
	; @returns {Boolean} Whether the broadcast was delivered.
	BroadcastSettingChange(Area) {
		global SYSTEM_CONTROL_SMTO_ABORTIFHUNG, SYSTEM_CONTROL_BROADCAST_TIMEOUT_MS
		Result := 0
		return DllCall("SendMessageTimeoutW", "Ptr", 0xFFFF, "UInt", 0x001A, "UPtr", 0, "Str", Area,
			"UInt", SYSTEM_CONTROL_SMTO_ABORTIFHUNG, "UInt", SYSTEM_CONTROL_BROADCAST_TIMEOUT_MS,
			"UPtr*", &Result, "Ptr") != 0
	}

	; @returns {Integer|String} The DWORD value, or "" when it is absent.
	ReadDword(Key, Name) {
		return RegRead(Key, Name, "")
	}

	; @throws {OSError} When the value cannot be written.
	WriteDword(Key, Name, Value) {
		RegWrite(Value, "REG_DWORD", Key, Name)
	}

	; @returns {Boolean} Whether the default microphone is muted.
	; @throws {Error} When no capture device is present.
	CaptureMuted() {
		Muted := 0
		ComCall(15, this._CaptureVolume(), "Int*", &Muted)
		return Muted != 0
	}

	; Mutes or unmutes the default microphone.
	; @throws {Error} When no capture device is present.
	SetCaptureMuted(Muted) {
		ComCall(14, this._CaptureVolume(), "Int", Muted ? 1 : 0, "Ptr", 0)
	}

	; The IAudioEndpointVolume of the default capture endpoint.
	_CaptureVolume() {
		global SYSTEM_CONTROL_E_CAPTURE, SYSTEM_CONTROL_E_CONSOLE, SYSTEM_CONTROL_CLSCTX_ALL
		static CLSID_MMDeviceEnumerator := "{BCDE0395-E52F-467C-8E3D-C4579291692E}"
		static IID_IMMDeviceEnumerator := "{A95664D2-9614-4F35-A746-DE8DB63617E6}"
		static IID_IAudioEndpointVolume := "{5CDF2C82-841E-4546-9722-0CF74078229A}"
		Enumerator := ComObject(CLSID_MMDeviceEnumerator, IID_IMMDeviceEnumerator)
		DevicePtr := 0
		ComCall(4, Enumerator, "Int", SYSTEM_CONTROL_E_CAPTURE, "Int", SYSTEM_CONTROL_E_CONSOLE, "Ptr*", &DevicePtr)
		Device := ComValue(13, DevicePtr)
		Iid := Buffer(16)
		DllCall("ole32\CLSIDFromString", "Str", IID_IAudioEndpointVolume, "Ptr", Iid, "HRESULT")
		VolumePtr := 0
		ComCall(3, Device, "Ptr", Iid, "UInt", SYSTEM_CONTROL_CLSCTX_ALL, "Ptr", 0, "Ptr*", &VolumePtr)
		return ComValue(13, VolumePtr)
	}

	; Terminates one process at once.
	; @returns {Boolean} Whether the process was closed.
	CloseProcess(Pid) {
		return ProcessClose(Pid) != 0
	}

	; Acquires one non-inheritable process capability before destructive approval.
	; @param {Integer} Pid The resolved positive DWORD process id; reused ids are never reopened.
	; @returns {Object} The retained native handle and its process id.
	; @throws {TypeError} When the PID is outside the native DWORD domain.
	; @throws {OSError} When Windows refuses the process access.
	AcquireProcessTarget(Pid) {
		global SYSTEM_CONTROL_PROCESS_TERMINATE, SYSTEM_CONTROL_PROCESS_QUERY_LIMITED_INFORMATION, SYSTEM_CONTROL_SYNCHRONIZE
		global SYSTEM_CONTROL_MAX_PROCESS_ID
		if !(Pid is Integer) || Pid <= 0 || Pid > SYSTEM_CONTROL_MAX_PROCESS_ID
			throw TypeError("A process target requires a positive DWORD PID.")
		Access := SYSTEM_CONTROL_PROCESS_TERMINATE | SYSTEM_CONTROL_PROCESS_QUERY_LIMITED_INFORMATION | SYSTEM_CONTROL_SYNCHRONIZE
		Handle := DllCall("Kernel32\OpenProcess", "UInt", Access, "Int", false, "UInt", Pid, "Ptr")
		if !Handle
			throw OSError(A_LastError, -1, "OpenProcess target")
		return { Handle: Handle, Pid: Pid }
	}

	; @returns {Boolean} Whether the retained process still runs.
	; @throws {OSError} When Windows cannot query its retained handle.
	ProcessTargetIsLive(Lease) {
		global SYSTEM_CONTROL_WAIT_OBJECT_0, SYSTEM_CONTROL_WAIT_TIMEOUT
		if !IsObject(Lease) || !Lease.HasOwnProp("Handle") || !Lease.Handle
			return false
		Status := DllCall("Kernel32\WaitForSingleObject", "Ptr", Lease.Handle, "UInt", 0, "UInt")
		if Status == SYSTEM_CONTROL_WAIT_OBJECT_0
			return false
		if Status != SYSTEM_CONTROL_WAIT_TIMEOUT
			throw OSError(A_LastError, -1, "WaitForSingleObject target")
		return true
	}

	; Terminates only the exact retained process object, never a numeric lookup.
	; @returns {Boolean} Whether native termination accepted this process handle.
	TerminateProcessTarget(Lease) {
		if !IsObject(Lease) || !Lease.HasOwnProp("Handle") || !Lease.Handle
			throw ValueError("The process target has already been released.")
		return DllCall("Kernel32\TerminateProcess", "Ptr", Lease.Handle, "UInt", 1, "Int") != 0
	}

	; Releases the capability once; this cleanup also runs during suspension.
	; @throws {OSError} When native handle cleanup fails.
	ReleaseProcessTarget(Lease) {
		PreviousCritical := Critical("On")
		try {
			if !IsObject(Lease) || !Lease.HasOwnProp("Handle") || !Lease.Handle
				return
			Handle := Lease.Handle
			Lease.Handle := 0
		} finally Critical(PreviousCritical)
		if !DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int")
			throw OSError(A_LastError, -1, "CloseHandle process target")
	}

	; @returns {Integer} This script's own process id.
	OwnPid() {
		return DllCall("GetCurrentProcessId", "UInt")
	}

	; @returns {Integer} The Remote Desktop Services session this script runs
	;   in, which names the per-session registry keys Explorer keeps.
	; @throws {OSError} When Windows does not report the session.
	SessionId() {
		Session := 0
		if !DllCall("ProcessIdToSessionId", "UInt", this.OwnPid(), "UInt*", &Session)
			throw OSError(A_LastError, -1, "ProcessIdToSessionId")
		return Session
	}

	; Strictly probes a key under HKEY_CURRENT_USER: only "not found" means
	; absent. A key that exists but cannot be opened is an error, never a
	; missing key, so a caller cannot mistake a refusal for an empty key.
	; @param {String} SubKey Key path below HKEY_CURRENT_USER.
	; @returns {Boolean} True when the key exists.
	; @throws {OSError} On any other failure to open the key.
	CurrentUserKeyExists(SubKey) {
		global SYSTEM_CONTROL_HKEY_CURRENT_USER, SYSTEM_CONTROL_KEY_QUERY_VALUE
		global SYSTEM_CONTROL_ERROR_FILE_NOT_FOUND, SYSTEM_CONTROL_ERROR_PATH_NOT_FOUND
		Handle := 0
		Status := DllCall("Advapi32\RegOpenKeyExW", "Ptr", SYSTEM_CONTROL_HKEY_CURRENT_USER,
			"WStr", SubKey, "UInt", 0, "UInt", SYSTEM_CONTROL_KEY_QUERY_VALUE, "PtrP", &Handle, "UInt")
		if (Status == 0) {
			DllCall("Advapi32\RegCloseKey", "Ptr", Handle, "UInt")
			return true
		}
		if (Status == SYSTEM_CONTROL_ERROR_FILE_NOT_FOUND || Status == SYSTEM_CONTROL_ERROR_PATH_NOT_FOUND)
			return false
		throw OSError(Status, -1, "HKEY_CURRENT_USER\" . SubKey . " could not be opened.")
	}

	; @returns {Object|String} { Hwnd, Pid, Class } of the active window, or "".
	ActiveWindow() {
		Hwnd := WinExist("A")
		if !Hwnd
			return ""
		; A menu, a tooltip or a quitting app can close between the reads: it is
		; then no longer the active window, and there is none to report.
		try
			return { Hwnd: Hwnd, Pid: WinGetPID(Hwnd), Class: WinGetClass(Hwnd) }
		catch TargetError
			return ""
	}

	; Reads exactly one window, including a hidden one, without choosing a new
	; foreground target. HWND, process and class are the available Win32 receipt;
	; they do not claim an unavailable unique window-generation identity.
	; @param {Integer} Hwnd The admitted window handle, 0 when no window was read.
	; @returns {Object|String} Detached { Hwnd, Pid, Class }, or "" when absent.
	WindowSnapshot(Hwnd) {
		if !(Hwnd is Integer)
			throw TypeError("A window snapshot requires an integer HWND.")
		if !Hwnd || !DllCall("IsWindow", "Ptr", Hwnd, "Int")
			return ""
		PreviousHidden := DetectHiddenWindows(true)
		try {
			Pid := WinGetPID("ahk_id " . Hwnd)
			ClassName := WinGetClass("ahk_id " . Hwnd)
			if !DllCall("IsWindow", "Ptr", Hwnd, "Int")
				return ""
			return { Hwnd: Hwnd, Pid: Pid, Class: ClassName }
		} catch TargetError {
			return ""
		} finally DetectHiddenWindows(PreviousHidden)
	}
	; @returns {Integer} The process id of the desktop shell, whose explorer.exe
	;   owns the desktop and the taskbar, or 0 when no shell is running.
	ShellPid() {
		Hwnd := DllCall("GetShellWindow", "Ptr")
		return Hwnd ? this._WindowPid(Hwnd) : 0
	}

	; The process of the packaged app an ApplicationFrameWindow frames: its
	; Windows.UI.Core.CoreWindow child is the only child owned by another
	; process than the shared ApplicationFrameHost.exe.
	; @returns {Integer} The app's process id, or 0 when the frame holds none (a
	;   minimized or suspended app takes its CoreWindow out of the frame).
	FramedAppPid(FrameHwnd) {
		FramePid := this._WindowPid(FrameHwnd)
		for Child in WinGetControlsHwnd("ahk_id " . FrameHwnd) {
			Pid := this._WindowPid(Child)
			if (Pid && Pid != FramePid)
				return Pid
		}
		return 0
	}

	; @returns {Integer} The process id owning a window or control, 0 if none.
	_WindowPid(Hwnd) {
		Pid := 0
		DllCall("GetWindowThreadProcessId", "Ptr", Hwnd, "UInt*", &Pid, "UInt")
		return Pid
	}

	; @returns {Array} The visible top-level windows of one process.
	WindowsOfProcess(Pid) {
		return WinGetList("ahk_pid " . Pid)
	}

	; Brings one window back to the foreground, waiting briefly for it.
	; @returns {Boolean} Whether it is active.
	Activate(Hwnd) {
		global SYSTEM_CONTROL_ACTIVATE_WAIT_S
		if !WinExist("ahk_id " . Hwnd)
			return false
		WinActivate("ahk_id " . Hwnd)
		return WinWaitActive("ahk_id " . Hwnd, , SYSTEM_CONTROL_ACTIVATE_WAIT_S) != 0
	}

	; @returns {ComObject} The Shell.Application automation object.
	ShellApplication() {
		return ComObject("Shell.Application")
	}

	; The active tab of an Explorer frame: the topmost ShellTabWindowClass child
	; (the inactive tabs are hidden below it).
	; @returns {Integer} Its HWND, or 0 for an Explorer without tabs.
	ActiveExplorerTab(FrameHwnd) {
		; A frame without that control is an Explorer from before tabs, whose one
		; Shell.Application window is matched by the frame's HWND alone.
		try
			return ControlGetHwnd("ShellTabWindowClass1", FrameHwnd)
		catch TargetError
			return 0
	}

	; The tab one Shell.Application window draws in, from its IShellBrowser
	; (IOleWindow::GetWindow).
	; @returns {Integer} The tab's HWND.
	ExplorerTabOf(Window) {
		static IID_IShellBrowser := "{000214E2-0000-0000-C000-000000000046}"
		Browser := ComObjQuery(Window, IID_IShellBrowser, IID_IShellBrowser)
		Tab := 0
		ComCall(3, Browser, "Ptr*", &Tab)
		return Tab
	}

	; @returns {String} The letters of the removable drives, e.g. "EF".
	RemovableDrives() {
		return DriveGetList("REMOVABLE")
	}

	; Deletes a file's Zone.Identifier stream (its Mark of the Web).
	; @returns {String} "removed", "absent" or "failed".
	DeleteZoneIdentifier(Path) {
		global SYSTEM_CONTROL_ERROR_FILE_NOT_FOUND
		if DllCall("DeleteFileW", "Str", Path . ":Zone.Identifier", "Int")
			return "removed"
		return (A_LastError = SYSTEM_CONTROL_ERROR_FILE_NOT_FOUND) ? "absent" : "failed"
	}

	; Creates an empty file only when no file has that name.
	; @returns {String} "created", "exists" or "failed".
	CreateNewFile(Path) {
		global SYSTEM_CONTROL_GENERIC_WRITE, SYSTEM_CONTROL_CREATE_NEW
		global SYSTEM_CONTROL_FILE_ATTRIBUTE_NORMAL, SYSTEM_CONTROL_ERROR_FILE_EXISTS
		Handle := DllCall("CreateFileW", "Str", Path, "UInt", SYSTEM_CONTROL_GENERIC_WRITE, "UInt", 0,
			"Ptr", 0, "UInt", SYSTEM_CONTROL_CREATE_NEW, "UInt", SYSTEM_CONTROL_FILE_ATTRIBUTE_NORMAL, "Ptr", 0, "Ptr")
		if (Handle = -1)
			return (A_LastError = SYSTEM_CONTROL_ERROR_FILE_EXISTS) ? "exists" : "failed"
		DllCall("CloseHandle", "Ptr", Handle)
		return "created"
	}

	; @returns {Boolean} Whether Path is a directory.
	IsDirectory(Path) {
		return InStr(FileExist(Path), "D") > 0
	}

	; @returns {Array} Every file below a directory, recursively.
	FilesUnder(Dir) {
		Files := []
		Loop Files, Dir . "\*", "FR"
			Files.Push(A_LoopFileFullPath)
		return Files
	}

	; @returns {String} The Windows Terminal alias, or "" when it is not installed.
	WindowsTerminalPath() {
		Path := EnvGet("LOCALAPPDATA") . "\Microsoft\WindowsApps\wt.exe"
		return FileExist(Path) ? Path : ""
	}

	; @returns {Object} { X, Y } of the pointer, in screen coordinates.
	MousePosition() {
		CoordMode("Mouse", "Screen")
		MouseGetPos(&X, &Y)
		return { X: X, Y: Y }
	}

	; @returns {Array} { Left, Top, Right, Bottom } of each monitor.
	Monitors() {
		Monitors := []
		Loop MonitorGetCount() {
			MonitorGet(A_Index, &Left, &Top, &Right, &Bottom)
			Monitors.Push({ Left: Left, Top: Top, Right: Right, Bottom: Bottom })
		}
		return Monitors
	}

	; Moves the pointer at once, in screen coordinates.
	MoveMouse(X, Y) {
		CoordMode("Mouse", "Screen")
		MouseMove(X, Y, 0)
	}

	; Empties the clipboard through the clipboard owner (adapters/clipboard.ahk),
	; which records the change as the driver's own: the keylogger then retires
	; the last copy's provenance instead of logging a user copy.
	; @returns {Boolean} False when the clipboard could not be written.
	ClearClipboard() {
		return CB_Write("")
	}

	; Runs Fn in its own thread, after the current one returns.
	; @param {Integer} DelayMs How long to wait first, in ms (positive).
	Defer(Fn, DelayMs := 1) {
		SetTimer(Fn, -DelayMs)
	}

	; Shows a short notice.
	Notify(Text) {
		TrayTip(Text, "ErgoptiPlus", "Iconi Mute")
	}

	; Asks OK/Cancel with Cancel as the default button.
	; @returns {String} "OK" or "Cancel".
	Ask(Text, Title) {
		return Ui_MsgBox(Text, Title, "OKCancel Icon! Default2")
	}
}
