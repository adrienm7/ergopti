; adapters/system_control.ahk

; ==============================================================================
; MODULE: SystemControl Adapter (AutoHotkey)
; DESCRIPTION:
; The Win32, COM, registry and shell primitives the system actions
; (modules/gestures/system_actions.ahk) are built from: start a program, post
; a window message, broadcast a setting change, read and write a registry
; value, mute the default microphone, close a process, read the active window
; and the Explorer windows, create a file exclusively, delete a file's
; Zone.Identifier stream, move the pointer, and ask or tell the user.
;
; FEATURES & RATIONALE:
; 1. Thin on purpose: each method is one native call with the arguments the
;    module chose, so the module's suite pins the exact message numbers,
;    command lines and paths through a recording double of this class.
; 2. Nothing here blocks the keyboard hook: Launch() does not wait for the
;    program, and Defer() moves a slower action (COM, a broadcast) out of the
;    hotkey thread that dispatched it.
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
global SYSTEM_CONTROL_ERROR_FILE_EXISTS := 80
; How long an activated window may take to come to the foreground.
global SYSTEM_CONTROL_ACTIVATE_WAIT_S := 1





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

	; @returns {Integer} This script's own process id.
	OwnPid() {
		return DllCall("GetCurrentProcessId", "UInt")
	}

	; @returns {Object|String} { Hwnd, Pid, Class } of the active window, or "".
	ActiveWindow() {
		Hwnd := WinExist("A")
		if !Hwnd
			return ""
		return { Hwnd: Hwnd, Pid: WinGetPID("ahk_id " . Hwnd), Class: WinGetClass("ahk_id " . Hwnd) }
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

	ClearClipboard() {
		A_Clipboard := ""
	}

	; Runs Fn in its own thread, after the current one returns.
	Defer(Fn) {
		SetTimer(Fn, -1)
	}

	; Shows a short notice.
	Notify(Text) {
		TrayTip(Text, "ErgoptiPlus", "Iconi Mute")
	}

	; Asks OK/Cancel with Cancel as the default button.
	; @returns {String} "OK" or "Cancel".
	Ask(Text, Title) {
		return MsgBox(Text, Title, "OKCancel Icon! Default2")
	}
}
