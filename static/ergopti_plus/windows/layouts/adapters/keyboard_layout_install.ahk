; layouts/adapters/keyboard_layout_install.ahk

; ==============================================================================
; MODULE: Keyboard Layout Install Adapter (AutoHotkey)
; DESCRIPTION:
; The native half of a keyboard layout DLL install. The driver side stages the
; page's DLL images, reads the 64-bit registry view, starts the elevated
; registration (the one UAC prompt) and activates the installed layout. The
; elevated side copies the images into System32 and SysWOW64, deletes them and
; installs the input profile. layouts/ui/layout_manager/composer.ahk and
; layouts/ui/layout_manager/kbd_register_core.ahk own the policy and the order.
;
; FEATURES & RATIONALE:
; 1. No global is read at the top level: the compiled driver dispatches the
;    elevated registration before its own include of this file has run.
; 2. Fail fast: every Win32 refusal throws an OSError naming the call, except
;    the layout activation, whose refusal the composer reports as a failure.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ==============================
; ======= 1/ Driver side =======
; ==============================
; ==============================

; Writes a staged image, creating its folder first.
; @param Path {String} The image path.
; @param Bytes {Buffer} The image.
LayoutInstallWriteStagedBytes(Path, Bytes) {
	SplitPath(Path, , &Parent)
	DirCreate(Parent)
	_LayoutInstallWriteBytes(Path, Bytes)
}

; The 64-bit registry view, whatever the bitness of AutoHotkey: the uninstall
; entries of a 64-bit Windows live there.
; @param Key {String} The key.
; @param Name {String} The value name.
; @returns {String} The value, or "" when it is absent.
LayoutInstallRegRead64(Key, Name) {
	Previous := A_RegView
	SetRegView(64)
	try return RegRead(Key, Name, "")
	finally SetRegView(Previous)
}

; The subkey names of a key in the 64-bit registry view.
; @param Key {String} The key.
; @returns {Array} The subkey names.
LayoutInstallRegSubkeys64(Key) {
	Previous := A_RegView
	SetRegView(64)
	try {
		Names := []
		loop reg Key, "K"
			Names.Push(A_LoopRegName)
		return Names
	} finally SetRegView(Previous)
}

; The one UAC prompt: a refused prompt throws, like a cancelled ShellExecute.
; @param Command {Map} executable and arguments.
; @returns {Integer} The exit code of the elevated process.
LayoutInstallElevate(Command) {
	return RunWait('*RunAs "' . Command["executable"] . '" ' . Command["arguments"], , "Hide")
}

; Loads the installed layout and asks the foreground window to switch to it.
; @param Klid {String} The layout id.
; @returns {Boolean} false when Windows did not load the layout.
LayoutInstallActivate(Klid) {
	static KLF_ACTIVATE := 0x1, WM_INPUTLANGCHANGEREQUEST := 0x50
	Hkl := DllCall("User32\LoadKeyboardLayoutW", "WStr", Klid, "UInt", KLF_ACTIVATE, "Ptr")
	if !Hkl {
		LoggerError("LayoutComposer", "Windows did not load the keyboard layout {1}.", Klid)
		return false
	}
	Foreground := WinExist("A")
	if Foreground
		PostMessage(WM_INPUTLANGCHANGEREQUEST, 0, Hkl, , "ahk_id " . Foreground)
	return true
}





; ================================
; ================================
; ======= 2/ Elevated side =======
; ================================
; ================================

; The machine itself, for the elevated process only: never called by a test.
; @param MaxDllBytes {Integer} The largest image a read accepts.
; @param UninstallCommand {Func} UninstallCommand(Dll) returns the command line
;   of the uninstall entry.
; @returns {Map} The ports of KbdRegister_Install and KbdRegister_Uninstall.
LayoutInstallSystemPorts(MaxDllBytes, UninstallCommand) {
	SetRegView(64)
	Machine() {
		ProcessMachine := 0, NativeMachine := 0
		if !DllCall("Kernel32\IsWow64Process2", "Ptr", DllCall("Kernel32\GetCurrentProcess", "Ptr"),
				"UShort*", &ProcessMachine, "UShort*", &NativeMachine)
			throw OSError(A_LastError, -1, "IsWow64Process2")
		return Map("process", ProcessMachine, "native", NativeMachine)
	}
	; System32 of a 32-bit process on 64-bit Windows is SysWOW64 unless redirection is off.
	WithRedirection(RedirectOff, Fn) {
		Wow := Machine()["process"] != 0
		Old := 0
		if RedirectOff && Wow && !DllCall("Kernel32\Wow64DisableWow64FsRedirection", "Ptr*", &Old)
			throw OSError(A_LastError, -1, "Wow64DisableWow64FsRedirection")
		try return Fn()
		finally {
			if RedirectOff && Wow
				DllCall("Kernel32\Wow64RevertWow64FsRedirection", "Ptr", Old)
		}
	}
	WriteFile(Path, Bytes, RedirectOff) {
		WithRedirection(RedirectOff, () => _LayoutInstallWriteBytes(Path, Bytes))
	}
	DeleteFile(Path, RedirectOff) {
		return WithRedirection(RedirectOff, () => _LayoutInstallDeleteFile(Path))
	}
	Subkeys(Key) {
		Names := []
		loop reg Key, "K"
			Names.Push(A_LoopRegName)
		return Names
	}
	Values(Key) {
		Found := []
		loop reg Key, "V"
			Found.Push(Map("name", A_LoopRegName, "data", RegRead(Key, A_LoopRegName, "")))
		return Found
	}
	ReadFile(Path) {
		Bytes := FileRead(Path, "RAW")
		if Bytes.Size == 0 || Bytes.Size > MaxDllBytes
			throw Error(Path . " is empty or larger than a keyboard layout image")
		return Bytes
	}
	WriteText(Path, Text) {
		Handle := FileOpen(Path, "w", "UTF-8-RAW")
		try Handle.Write(Text)
		finally Handle.Close()
	}
	return Map(
		"reg_read", (Key, Name) => RegRead(Key, Name, ""),
		"reg_subkeys", Subkeys,
		"reg_values", Values,
		"reg_write", (Type, Key, Name, Value) => RegWrite(Value, Type, Key, Name),
		"reg_delete_value", (Key, Name) => RegDelete(Key, Name),
		"reg_delete_key", (Key) => RegDeleteKey(Key),
		"read_file", ReadFile,
		"read_text", (Path) => FileRead(Path, "UTF-8"),
		"write_text", WriteText,
		"sha256", (Bytes) => CryptoSha256Bytes(Bytes),
		"write_file", WriteFile,
		"delete_file", DeleteFile,
		"install_tip", (Text, Flags) => DllCall("Input\InstallLayoutOrTip", "WStr", Text, "UInt", Flags, "Int"),
		"native_machine", () => Machine()["native"],
		"windir", EnvGet("WINDIR"),
		"uninstall_command", UninstallCommand
	)
}

_LayoutInstallWriteBytes(Path, Bytes) {
	Handle := FileOpen(Path, "w")
	try Handle.RawWrite(Bytes, Bytes.Size)
	finally Handle.Close()
}

; A DLL a process still has loaded cannot be deleted: Windows removes it at the
; next start (MOVEFILE_DELAY_UNTIL_REBOOT).
_LayoutInstallDeleteFile(Path) {
	if !FileExist(Path)
		return "absent"
	try {
		FileDelete(Path)
		return "deleted"
	} catch OSError {
		; Still loaded by a process: scheduled below instead.
	}
	if !DllCall("Kernel32\MoveFileExW", "WStr", Path, "Ptr", 0, "UInt", 0x4)
		throw OSError(A_LastError, -1, "MoveFileExW " . Path)
	return "at_reboot"
}
