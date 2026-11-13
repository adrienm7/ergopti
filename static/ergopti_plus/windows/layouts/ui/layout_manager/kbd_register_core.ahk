; layouts/ui/layout_manager/kbd_register_core.ahk

; ==============================================================================
; MODULE: Keyboard Layout DLL Registration (Windows)
; DESCRIPTION:
; Installs and uninstalls a Windows keyboard layout DLL the layout editor wrote
; in the page (docs/design/layout-editor.md « Windows host »), with the steps
; and the order of the NSIS installer of tools/lib/kbd-dll/installer.cjs: the
; System32 and SysWOW64 copies, the Keyboard Layouts\<KLID> key, the input
; profile through InstallLayoutOrTip and the Ergopti_kbd_<dll> uninstall entry,
; then the reverse. kbd_register.ahk runs it elevated (one UAC prompt); the
; driver (composer.ahk) stages the images and reads the result.
;
; FEATURES & RATIONALE:
; 1. Every machine-scoped effect is a port (registry, files, input profile,
;    machine): the tests replay the install and the uninstall against a fake
;    registry and file system and read the plan in order, nothing runs for real.
; 2. Ownership: the uninstall entry Ergopti_kbd_<dll> holds the KLID it owns. A
;    Keyboard Layouts key whose Layout File is <dll>.dll without that entry is
;    someone else's layout: it is refused and never overwritten, and an
;    uninstall without the entry touches nothing.
; 3. The elevated process reads each staged image into memory, checks its
;    SHA-256 against the request the driver wrote, and writes those bytes: a
;    file swapped in the staging folder after the check is never copied.
; 4. No global is read at the top level: the compiled driver dispatches here
;    before its own include of this file has run (ErgoptiPlus.ahk).
; ==============================================================================

#Requires AutoHotkey v2.0

#Include %A_LineFile%\..\..\..\adapters\keyboard_layout_install.ahk





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

/**
 * The registry keys and limits the registration shares with installer.cjs.
 * @param {String} Name
 * @returns {String|Integer}
 */
KbdRegister_Constant(Name) {
	switch Name {
		case "layouts_key": return "HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts"
		case "uninstall_root": return "HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall"
		case "substitutes_key": return "HKCU\Keyboard Layout\Substitutes"
		case "preload_key": return "HKCU\Keyboard Layout\Preload"
		case "dll_name": return "^[a-z][a-z0-9]{0,7}$"
		case "max_dll_bytes": return 1048576
		case "ilot_uninstall": return 1
		case "elevation_cancelled": return 1223
		case "invocation_flag": return "--kbd-register"
	}
	throw ValueError("Unknown keyboard layout registration constant.", -1, Name)
}

/**
 * The architectures the page writes, in the order the request lists them.
 * @returns {Array}
 */
KbdRegister_Architectures() {
	static Architectures := ["x86", "wow64", "x64", "arm64"]
	return Architectures
}

/**
 * The uninstall entry of a layout DLL.
 * @param {String} Dll - The DLL name without its extension.
 * @returns {String}
 */
KbdRegister_UninstallKey(Dll) => KbdRegister_Constant("uninstall_root") . "\Ergopti_kbd_" . Dll





; =================================
; =================================
; ======= 2/ What it checks =======
; =================================
; =================================

/**
 * Checks a request the driver staged.
 * @param {Any} Request - Decoded request.json.
 * @returns {String} Why it is refused, "" when it is accepted.
 */
KbdRegister_CheckRequest(Request) {
	if !(Request is Map)
		return "the request is not an object"
	if !(Request.Get("dll", 0) is String) || !RegExMatch(Request["dll"], KbdRegister_Constant("dll_name"))
		return "the DLL name is not a keyboard layout DLL name"
	if !(Request.Get("lcid", 0) is String) || !RegExMatch(Request["lcid"], "^[0-9a-f]{4}$")
		return "the LCID is not four lowercase hexadecimal digits"
	for Field in ["text", "company"]
		if !(Request.Get(Field, 0) is String) || RegExMatch(Request[Field], "[\x00-\x1F]")
			return "the " . Field . " is not one line of text"
	if Request["text"] == ""
		return "the layout text is empty"
	if !(Request.Get("sha256", 0) is Map)
		return "the request lists no image digest"
	for Arch in KbdRegister_Architectures()
		if !(Request["sha256"].Get(Arch, 0) is String) || !RegExMatch(Request["sha256"][Arch], "^[0-9a-f]{64}$")
			return "the " . Arch . " image has no digest"
	return ""
}

/**
 * What the registry already says about a layout DLL. Reading needs no right.
 * @param {String} Dll - The DLL name.
 * @param {Map} Ports - "reg_read" (Key, Name) and "reg_subkeys" (Key).
 * @returns {Map} state ("new", "installed" or "foreign"), klid and layout_id.
 */
KbdRegister_Inspect(Dll, Ports) {
	LayoutsKey := KbdRegister_Constant("layouts_key")
	Owned := Ports["reg_read"].Call(KbdRegister_UninstallKey(Dll), "KLID")
	for Klid in Ports["reg_subkeys"].Call(LayoutsKey) {
		if StrCompare(Ports["reg_read"].Call(LayoutsKey . "\" . Klid, "Layout File"), Dll . ".dll") != 0
			continue
		if Owned == "" || StrCompare(Klid, Owned) != 0
			return Map("state", "foreign", "klid", Klid, "layout_id", "")
	}
	if Owned == ""
		return Map("state", "new", "klid", "", "layout_id", "")
	return Map("state", "installed", "klid", Owned,
		"layout_id", Ports["reg_read"].Call(LayoutsKey . "\" . Owned, "Layout Id"))
}

/**
 * The first free KLID a0nn<lcid>: no installed layout may use it.
 * @param {String} Lcid - Four lowercase hexadecimal digits.
 * @param {Map} Ports - "reg_read".
 * @returns {String}
 * @throws {Error} When the 255 identifiers are all taken.
 */
KbdRegister_AllocateKlid(Lcid, Ports) {
	LayoutsKey := KbdRegister_Constant("layouts_key")
	loop 255 {
		Klid := "a0" . Format("{:02x}", A_Index) . Lcid
		if Ports["reg_read"].Call(LayoutsKey . "\" . Klid, "Layout File") == ""
			return Klid
	}
	throw Error("No free keyboard layout identifier is left.")
}

/**
 * A Layout Id one above every installed one, so no two layouts share it.
 * @param {Map} Ports - "reg_read" and "reg_subkeys".
 * @returns {String} Four uppercase hexadecimal digits.
 */
KbdRegister_AllocateLayoutId(Ports) {
	LayoutsKey := KbdRegister_Constant("layouts_key")
	Highest := 0
	for Klid in Ports["reg_subkeys"].Call(LayoutsKey) {
		Value := Ports["reg_read"].Call(LayoutsKey . "\" . Klid, "Layout Id")
		if RegExMatch(Value, "^[0-9A-Fa-f]{1,4}$") && Integer("0x" . Value) > Highest
			Highest := Integer("0x" . Value)
	}
	return Format("{:04X}", Highest + 1)
}

/**
 * Where each image goes on this machine, as installer.cjs places them.
 * @param {Integer} NativeMachine - IMAGE_FILE_MACHINE of the OS (0xAA64, 0x8664 or 0x14C).
 * @param {String} WinDir - %WINDIR%.
 * @param {String} Dll - The DLL name.
 * @returns {Array} Maps arch, path, redirect_off (System32 seen past WOW64).
 */
KbdRegister_Placement(NativeMachine, WinDir, Dll) {
	System32 := WinDir . "\System32\" . Dll . ".dll"
	SysWow64 := WinDir . "\SysWOW64\" . Dll . ".dll"
	switch NativeMachine {
		case 0xAA64:
			return [Map("arch", "arm64", "path", System32, "redirect_off", true),
				Map("arch", "wow64", "path", SysWow64, "redirect_off", false)]
		case 0x8664:
			return [Map("arch", "x64", "path", System32, "redirect_off", true),
				Map("arch", "wow64", "path", SysWow64, "redirect_off", false)]
		case 0x14C:
			return [Map("arch", "x86", "path", System32, "redirect_off", false)]
	}
	throw Error("The machine type " . Format("0x{:X}", NativeMachine) . " has no keyboard layout image.")
}





; ==============================
; ==============================
; ======= 3/ Install ===========
; ==============================
; ==============================

_KbdRegister_Result(Ok, Code, Detail, Klid := "") => Map("ok", Ok ? true : false, "code", Code, "detail", Detail, "klid", Klid)

/**
 * Installs the staged images, in installer.cjs' order.
 * @param {Map} Request - Decoded request.json (KbdRegister_CheckRequest).
 * @param {String} Staging - Folder holding <arch>\<dll>.dll.
 * @param {Map} Ports - "reg_read", "reg_subkeys", "reg_write" (Type, Key, Name, Value),
 *   "read_file" (Path) -> Buffer, "sha256" (Buffer) -> hex, "write_file" (Path,
 *   Buffer, RedirectOff), "install_tip" (Text, Flags) -> Integer,
 *   "native_machine" () -> Integer, "windir", "uninstall_command" (Dll) -> String.
 * @returns {Map} ok, code (foreign_layout, profile_not_added, install_failed), detail, klid.
 */
KbdRegister_Install(Request, Staging, Ports) {
	Refusal := KbdRegister_CheckRequest(Request)
	if Refusal != ""
		return _KbdRegister_Result(false, "install_failed", Refusal)
	Dll := Request["dll"]
	LayoutsKey := KbdRegister_Constant("layouts_key")
	Seen := KbdRegister_Inspect(Dll, Ports)
	if Seen["state"] == "foreign"
		return _KbdRegister_Result(false, "foreign_layout",
			"the keyboard layout " . Seen["klid"] . " already uses " . Dll . ".dll and is not Ergopti's", Seen["klid"])
	try {
		if Seen["state"] == "installed" {
			; An upgrade keeps its KLID and its Layout Id.
			Klid := Seen["klid"]
			LayoutId := Seen["layout_id"] != "" ? Seen["layout_id"] : KbdRegister_AllocateLayoutId(Ports)
		} else {
			Klid := KbdRegister_AllocateKlid(Request["lcid"], Ports)
			LayoutId := KbdRegister_AllocateLayoutId(Ports)
		}
		Images := Map()
		for Place in KbdRegister_Placement(Ports["native_machine"].Call(), Ports["windir"], Dll) {
			Bytes := Ports["read_file"].Call(Staging . "\" . Place["arch"] . "\" . Dll . ".dll")
			if Ports["sha256"].Call(Bytes) != Request["sha256"][Place["arch"]]
				return _KbdRegister_Result(false, "install_failed", "the staged " . Place["arch"] . " image changed", Klid)
			Images[Place["path"]] := Bytes
		}
		for Place in KbdRegister_Placement(Ports["native_machine"].Call(), Ports["windir"], Dll)
			Ports["write_file"].Call(Place["path"], Images[Place["path"]], Place["redirect_off"])
		Key := LayoutsKey . "\" . Klid
		Ports["reg_write"].Call("REG_SZ", Key, "Layout File", Dll . ".dll")
		Ports["reg_write"].Call("REG_SZ", Key, "Layout Text", Request["text"])
		Ports["reg_write"].Call("REG_EXPAND_SZ", Key, "Layout Display Name", "@%SystemRoot%\system32\" . Dll . ".dll,-1000")
		Ports["reg_write"].Call("REG_SZ", Key, "Layout Id", LayoutId)
		Added := Ports["install_tip"].Call(StrUpper(Request["lcid"]) . ":" . Klid, 0)
		Entry := KbdRegister_UninstallKey(Dll)
		Ports["reg_write"].Call("REG_SZ", Entry, "DisplayName", Request["text"])
		Ports["reg_write"].Call("REG_SZ", Entry, "Publisher", Request["company"] != "" ? Request["company"] : "Ergopti")
		Ports["reg_write"].Call("REG_SZ", Entry, "UninstallString", Ports["uninstall_command"].Call(Dll))
		Ports["reg_write"].Call("REG_SZ", Entry, "KLID", Klid)
		Ports["reg_write"].Call("REG_DWORD", Entry, "NoModify", 1)
		Ports["reg_write"].Call("REG_DWORD", Entry, "NoRepair", 1)
	} catch as Err {
		return _KbdRegister_Result(false, "install_failed", Err.Message, IsSet(Klid) ? Klid : "")
	}
	if !(Added is Integer) || Added == 0
		return _KbdRegister_Result(true, "profile_not_added",
			"the layout is installed but its input profile was not added; add it in Settings", Klid)
	return _KbdRegister_Result(true, "", "", Klid)
}





; ==============================
; ==============================
; ======= 4/ Uninstall =========
; ==============================
; ==============================

; Removes the values of a current-user list whose data is Data.
_KbdRegister_DropValues(Key, Data, Ports) {
	for Value in Ports["reg_values"].Call(Key)
		if StrCompare(Value["data"], Data) == 0
			Ports["reg_delete_value"].Call(Key, Value["name"])
}

/**
 * Uninstalls a layout DLL this registration installed, in installer.cjs' order.
 * @param {String} Dll - The DLL name.
 * @param {Map} Ports - As KbdRegister_Install, plus "reg_values" (Key) -> Maps
 *   name and data, "reg_delete_value" (Key, Name), "reg_delete_key" (Key) and
 *   "delete_file" (Path, RedirectOff) -> "deleted", "absent" or "at_reboot".
 * @returns {Map} ok, code (uninstall_failed), detail, klid.
 */
KbdRegister_Uninstall(Dll, Ports) {
	if !(Dll is String) || !RegExMatch(Dll, KbdRegister_Constant("dll_name"))
		return _KbdRegister_Result(false, "uninstall_failed", "the DLL name is not a keyboard layout DLL name")
	Entry := KbdRegister_UninstallKey(Dll)
	Klid := Ports["reg_read"].Call(Entry, "KLID")
	if !RegExMatch(Klid, "^[0-9a-fA-F]{8}$")
		return _KbdRegister_Result(false, "uninstall_failed", "Ergopti did not install " . Dll . ".dll")
	try {
		Ports["install_tip"].Call(StrUpper(SubStr(Klid, 5)) . ":" . Klid, KbdRegister_Constant("ilot_uninstall"))
		; A substitute naming the KLID, then the Preload entries naming that substitute or the KLID.
		Substitutes := KbdRegister_Constant("substitutes_key"), Preload := KbdRegister_Constant("preload_key")
		for Value in Ports["reg_values"].Call(Substitutes) {
			if StrCompare(Value["data"], Klid) != 0
				continue
			_KbdRegister_DropValues(Preload, Value["name"], Ports)
			Ports["reg_delete_value"].Call(Substitutes, Value["name"])
		}
		_KbdRegister_DropValues(Preload, Klid, Ports)
		Ports["reg_delete_key"].Call(KbdRegister_Constant("layouts_key") . "\" . Klid)
		for Place in KbdRegister_Placement(Ports["native_machine"].Call(), Ports["windir"], Dll)
			Ports["delete_file"].Call(Place["path"], Place["redirect_off"])
		Ports["reg_delete_key"].Call(Entry)
	} catch as Err {
		return _KbdRegister_Result(false, "uninstall_failed", Err.Message, Klid)
	}
	return _KbdRegister_Result(true, "", "", Klid)
}





; ====================================
; ====================================
; ======= 5/ Command and entry =======
; ====================================
; ====================================

/**
 * The elevated command line of one registration.
 * @param {Array} Words - "install" and the staging folder, or "uninstall" and the DLL name.
 * @param {Map} Env - compiled, executable (the compiled driver or AutoHotkey), entry (kbd_register.ahk).
 * @returns {Map} executable and arguments (one String, each word quoted).
 */
KbdRegister_Command(Words, Env) {
	Parts := ["/force"]
	if Env["compiled"]
		Parts.Push(KbdRegister_Constant("invocation_flag"))
	else
		Parts.Push(Env["entry"])
	for Word in Words
		Parts.Push(Word)
	Line := ""
	for Part in Parts
		Line .= (A_Index > 1 ? " " : "") . (InStr(Part, " ") || Part == "" ? '"' . Part . '"' : Part)
	return Map("executable", Env["executable"], "arguments", Line)
}

/**
 * Whether this process was started to register a layout DLL.
 * @param {Array} Args - The command line; A_Args by default.
 * @returns {Boolean}
 */
KbdRegister_IsInvocation(Args := unset) {
	if !IsSet(Args)
		Args := A_Args
	return Args.Length >= 1 && Args[1] = KbdRegister_Constant("invocation_flag")
}

/**
 * Runs one registration from its command line and writes its result.json.
 * @param {Array} Words - "install" <staging> or "uninstall" <dll> [<staging>].
 * @param {Map} Ports - The machine (KbdRegister_SystemPorts in production).
 * @returns {Integer} The exit code: 0 on success, 1 on failure.
 */
KbdRegister_Run(Words, Ports) {
	Action := Words.Length >= 1 ? Words[1] : ""
	Staging := ""
	if Action == "install" && Words.Length == 2 {
		Staging := Words[2]
		try {
			Request := JsonParse(Ports["read_text"].Call(Staging . "\request.json"))
			Result := KbdRegister_Install(Request, Staging, Ports)
		} catch as Err {
			Result := _KbdRegister_Result(false, "install_failed", "the request cannot be read: " . Err.Message)
		}
	} else if Action == "uninstall" && (Words.Length == 2 || Words.Length == 3) {
		Staging := Words.Length == 3 ? Words[3] : ""
		Result := KbdRegister_Uninstall(Words[2], Ports)
	} else {
		return 1
	}
	if Staging != ""
		Ports["write_text"].Call(Staging . "\result.json", "{" . '"ok":' . (Result["ok"] ? "true" : "false")
			. ',"code":' . JsonStringLiteral(Result["code"]) . ',"detail":' . JsonStringLiteral(Result["detail"])
			. ',"klid":' . JsonStringLiteral(Result["klid"]) . "}`n")
	return Result["ok"] ? 0 : 1
}

/**
 * The machine itself, for the elevated process only: never called by a test.
 * @returns {Map} The ports of KbdRegister_Install and KbdRegister_Uninstall.
 */
KbdRegister_SystemPorts() {
	UninstallCommand(Dll) {
		Command := KbdRegister_Command(["uninstall", Dll], KbdRegister_SelfEnv())
		return '"' . Command["executable"] . '" ' . Command["arguments"]
	}
	return LayoutInstallSystemPorts(KbdRegister_Constant("max_dll_bytes"), UninstallCommand)
}

/**
 * How this process starts itself again: the compiled driver, or AutoHotkey
 * with kbd_register.ahk next to this file.
 * @returns {Map} compiled, executable, entry.
 */
KbdRegister_SelfEnv() {
	SplitPath(A_LineFile, , &Folder)
	return Map("compiled", A_IsCompiled ? true : false,
		"executable", A_IsCompiled ? A_ScriptFullPath : A_AhkPath,
		"entry", A_IsCompiled ? "" : Folder . "\kbd_register.ahk")
}

/**
 * The elevated entry: runs the command line after the invocation flag and exits.
 * @param {Array} Args - The command line; A_Args by default.
 */
KbdRegister_Main(Args := unset) {
	if !IsSet(Args)
		Args := A_Args
	Words := []
	for Index, Word in Args
		if Index > 1 || Word != KbdRegister_Constant("invocation_flag")
			Words.Push(Word)
	ExitApp(KbdRegister_Run(Words, KbdRegister_SystemPorts()))
}
