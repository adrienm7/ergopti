; tests/unit/hotstrings/engine/expander/test_kbd_register.ahk

; ==============================================================================
; MODULE: Keyboard Layout DLL Registration Tests (Windows)
; DESCRIPTION:
; The elevated helper (layouts/ui/layout_manager/kbd_register_core.ahk) installs and
; uninstalls a layout DLL with the steps and the order of the NSIS installer
; of tools/lib/kbd-dll/installer.cjs. Every machine-scoped effect goes through
; a fake registry and file system here: each test reads the plan of what the
; helper asked the machine to do, in order. Nothing is installed, no registry
; key is written and no UAC prompt is raised.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

_KBR_Layouts() => "HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts"

_KBR_Entry() => "HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\Ergopti_kbd_kbdmine"

_KBR_Image(Tag) {
	Bytes := Buffer(16, 0)
	NumPut("UChar", 0x4D, Bytes, 0), NumPut("UChar", 0x5A, Bytes, 1), NumPut("UChar", Tag, Bytes, 2)
	return Bytes
}

; A machine with a fake registry (Values maps "key|name" to data) and staged
; images; Plan receives every effect in order.
_KBR_Machine(Machine := 0x8664, TipResult := 1) {
	State := {Values: Map(), Keys: Map(), Files: Map(), Plan: [], Written: Map()}
	State.Values.CaseSense := "Off", State.Keys.CaseSense := "Off"
	; The machine's own layouts: French (00C0) and one Ergopti does not own.
	Seed(Key, Name, Value) {
		State.Keys[Key] := true
		State.Values[Key . "|" . Name] := Value
	}
	Seed(_KBR_Layouts() . "\0000040c", "Layout File", "KBDFR.DLL")
	Seed(_KBR_Layouts() . "\0000040c", "Layout Id", "")
	Seed(_KBR_Layouts() . "\a001040c", "Layout File", "kbdother.dll")
	Seed(_KBR_Layouts() . "\a001040c", "Layout Id", "00C0")
	for Arch in KbdRegister_Architectures()
		State.Files["C:\stage\kbdmine\" . Arch . "\kbdmine.dll"] := _KBR_Image(A_Index)
	Subkeys(Key) {
		Names := []
		for Known in State.Keys {
			if SubStr(Known, 1, StrLen(Key) + 1) = Key . "\" && !InStr(SubStr(Known, StrLen(Key) + 2), "\")
				Names.Push(SubStr(Known, StrLen(Key) + 2))
		}
		return Names
	}
	Values(Key) {
		Found := []
		for Name, Data in State.Values
			if SubStr(Name, 1, StrLen(Key) + 1) = Key . "|"
				Found.Push(Map("name", SubStr(Name, StrLen(Key) + 2), "data", Data))
		return Found
	}
	Write(Type, Key, Name, Value) {
		State.Plan.Push("write " . Key . " [" . Name . "] " . Type . " " . Value)
		State.Keys[Key] := true
		State.Values[Key . "|" . Name] := Value
	}
	DeleteValue(Key, Name) {
		State.Plan.Push("delete value " . Key . " [" . Name . "]")
		State.Values.Delete(Key . "|" . Name)
	}
	DeleteKey(Key) {
		State.Plan.Push("delete key " . Key)
		Gone := []
		for Name in State.Values
			if SubStr(Name, 1, StrLen(Key) + 1) = Key . "|"
				Gone.Push(Name)
		for Name in Gone
			State.Values.Delete(Name)
		State.Keys.Delete(Key)
	}
	State.Seed := Seed
	State.Ports := Map(
		"reg_read", (Key, Name) => State.Values.Get(Key . "|" . Name, ""),
		"reg_subkeys", Subkeys,
		"reg_values", Values,
		"reg_write", Write,
		"reg_delete_value", DeleteValue,
		"reg_delete_key", DeleteKey,
		"read_file", (Path) => State.Files[Path],
		"sha256", (Bytes) => CryptoSha256Bytes(Bytes),
		"write_file", (Path, Bytes, RedirectOff) => (State.Plan.Push("copy " . Path . (RedirectOff ? " (redirection off)" : "")),
			State.Written[Path] := Bytes),
		"delete_file", (Path, RedirectOff) => (State.Plan.Push("delete file " . Path
			. (RedirectOff ? " (redirection off)" : "")), "at_reboot"),
		"install_tip", (Text, Flags) => (State.Plan.Push("input profile " . Text . " " . Flags), TipResult),
		"native_machine", () => Machine,
		"windir", "C:\Windows",
		"uninstall_command", (Dll) => '"C:\AHK\AutoHotkey64.exe" /force C:\E\kbd_register.ahk uninstall ' . Dll,
		"read_text", (Path) => State.Files.Get(Path, ""),
		"write_text", (Path, Text) => (State.Plan.Push("result " . Path), State.Files[Path] := Text)
	)
	return State
}

_KBR_Request(State) {
	Digests := Map()
	for Arch in KbdRegister_Architectures()
		Digests[Arch] := CryptoSha256Bytes(State.Files["C:\stage\kbdmine\" . Arch . "\kbdmine.dll"])
	return Map("action", "install", "dll", "kbdmine", "text", "My Layout", "lcid", "040c", "company", "",
		"sha256", Digests)
}

_KBR_Plan(State) => _KLT_Join(State.Plan, "`n")





; ==========================
; ==========================
; ======= 2/ Install =======
; ==========================
; ==========================

Test("kbd register: a first install follows the NSIS installer's steps in its order (kbd-register)",
	_KBR_FirstInstallCase)

_KBR_FirstInstallCase() {
	State := _KBR_Machine()
	Result := KbdRegister_Install(_KBR_Request(State), "C:\stage\kbdmine", State.Ports)
	AssertTrue(Result["ok"], Result["detail"])
	AssertEqual("", Result["code"])
	AssertEqual("a002040c", Result["klid"], "the first free KLID a0nn<lcid>")
	Key := _KBR_Layouts() . "\a002040c"
	AssertEqual(_KLT_Join([
		"copy C:\Windows\System32\kbdmine.dll (redirection off)",
		"copy C:\Windows\SysWOW64\kbdmine.dll",
		"write " . Key . " [Layout File] REG_SZ kbdmine.dll",
		"write " . Key . " [Layout Text] REG_SZ My Layout",
		"write " . Key . " [Layout Display Name] REG_EXPAND_SZ @%SystemRoot%\system32\kbdmine.dll,-1000",
		"write " . Key . " [Layout Id] REG_SZ 00C1",
		"input profile 040C:a002040c 0",
		"write " . _KBR_Entry() . " [DisplayName] REG_SZ My Layout",
		"write " . _KBR_Entry() . " [Publisher] REG_SZ Ergopti",
		"write " . _KBR_Entry() . ' [UninstallString] REG_SZ "C:\AHK\AutoHotkey64.exe" /force C:\E\kbd_register.ahk uninstall kbdmine',
		"write " . _KBR_Entry() . " [KLID] REG_SZ a002040c",
		"write " . _KBR_Entry() . " [NoModify] REG_DWORD 1",
		"write " . _KBR_Entry() . " [NoRepair] REG_DWORD 1"], "`n"), _KBR_Plan(State))
	AssertEqual(3, NumGet(State.Written["C:\Windows\System32\kbdmine.dll"], 2, "UChar"), "x64 in System32")
	AssertEqual(2, NumGet(State.Written["C:\Windows\SysWOW64\kbdmine.dll"], 2, "UChar"), "wow64 in SysWOW64")
	AssertEqual("installed", KbdRegister_Inspect("kbdmine", State.Ports)["state"], "the entry now owns it")
}

Test("kbd register: each Windows architecture receives its own images (kbd-register)", _KBR_PlacementCase)

_KBR_PlacementCase() {
	Arm := _KBR_Machine(0xAA64)
	AssertTrue(KbdRegister_Install(_KBR_Request(Arm), "C:\stage\kbdmine", Arm.Ports)["ok"])
	AssertEqual(4, NumGet(Arm.Written["C:\Windows\System32\kbdmine.dll"], 2, "UChar"), "arm64 in System32")
	AssertEqual(2, NumGet(Arm.Written["C:\Windows\SysWOW64\kbdmine.dll"], 2, "UChar"), "wow64 in SysWOW64")
	X86 := _KBR_Machine(0x14C)
	AssertTrue(KbdRegister_Install(_KBR_Request(X86), "C:\stage\kbdmine", X86.Ports)["ok"])
	AssertEqual(1, NumGet(X86.Written["C:\Windows\System32\kbdmine.dll"], 2, "UChar"), "x86 in System32")
	AssertFalse(X86.Written.Has("C:\Windows\SysWOW64\kbdmine.dll"), "32-bit Windows has no SysWOW64")
	AssertThrows(() => KbdRegister_Placement(0x1C4, "C:\Windows", "kbdmine"), "an unknown machine is refused")
}

Test("kbd register: an upgrade keeps its KLID and Layout Id from the uninstall entry (kbd-register)",
	_KBR_UpgradeCase)

_KBR_UpgradeCase() {
	State := _KBR_Machine()
	State.Seed.Call(_KBR_Layouts() . "\a003040c", "Layout File", "kbdmine.dll")
	State.Seed.Call(_KBR_Layouts() . "\a003040c", "Layout Id", "00D7")
	State.Seed.Call(_KBR_Entry(), "KLID", "a003040c")
	Seen := KbdRegister_Inspect("kbdmine", State.Ports)
	AssertEqual("installed", Seen["state"], "« already installed » comes from the uninstall entry")
	Result := KbdRegister_Install(_KBR_Request(State), "C:\stage\kbdmine", State.Ports)
	AssertTrue(Result["ok"])
	AssertEqual("a003040c", Result["klid"])
	AssertContains(_KBR_Plan(State), "[Layout Id] REG_SZ 00D7")
}

Test("kbd register: a layout of the same DLL Ergopti does not own is refused and never overwritten (kbd-register)",
	_KBR_ForeignCase)

_KBR_ForeignCase() {
	State := _KBR_Machine()
	State.Seed.Call(_KBR_Layouts() . "\a005040c", "Layout File", "KBDMINE.DLL")
	AssertEqual("foreign", KbdRegister_Inspect("kbdmine", State.Ports)["state"])
	Result := KbdRegister_Install(_KBR_Request(State), "C:\stage\kbdmine", State.Ports)
	AssertFalse(Result["ok"])
	AssertEqual("foreign_layout", Result["code"])
	AssertEqual("", _KBR_Plan(State), "nothing is copied or written")
	; An entry naming another KLID does not make the foreign key Ergopti's.
	State.Seed.Call(_KBR_Entry(), "KLID", "a006040c")
	AssertEqual("foreign", KbdRegister_Inspect("kbdmine", State.Ports)["state"])
}

Test("kbd register: a staged image changed after the request is never copied (kbd-register)", _KBR_SwapCase)

_KBR_SwapCase() {
	State := _KBR_Machine()
	Request := _KBR_Request(State)
	State.Files["C:\stage\kbdmine\wow64\kbdmine.dll"] := _KBR_Image(99)
	Result := KbdRegister_Install(Request, "C:\stage\kbdmine", State.Ports)
	AssertFalse(Result["ok"])
	AssertEqual("install_failed", Result["code"])
	AssertEqual("", _KBR_Plan(State), "every image is checked before the first copy")
	Request["dll"] := "../evil"
	AssertEqual("install_failed", KbdRegister_Install(Request, "C:\stage\kbdmine", State.Ports)["code"])
}

Test("kbd register: an input profile Windows did not add leaves the layout installed and says so (kbd-register)",
	_KBR_ProfileCase)

_KBR_ProfileCase() {
	State := _KBR_Machine(0x8664, 0)
	Result := KbdRegister_Install(_KBR_Request(State), "C:\stage\kbdmine", State.Ports)
	AssertTrue(Result["ok"])
	AssertEqual("profile_not_added", Result["code"])
	AssertContains(_KBR_Plan(State), "[NoRepair] REG_DWORD 1", "the uninstall entry is still written")
}





; ============================
; ============================
; ======= 3/ Uninstall =======
; ============================
; ============================

Test("kbd register: uninstall follows the NSIS uninstall section in its order (kbd-register)", _KBR_UninstallCase)

_KBR_UninstallCase() {
	State := _KBR_Machine()
	AssertTrue(KbdRegister_Install(_KBR_Request(State), "C:\stage\kbdmine", State.Ports)["ok"])
	State.Seed.Call("HKCU\Keyboard Layout\Substitutes", "d002040c", "a002040c")
	State.Seed.Call("HKCU\Keyboard Layout\Substitutes", "0000040c", "0000040c")
	State.Seed.Call("HKCU\Keyboard Layout\Preload", "1", "0000040c")
	State.Seed.Call("HKCU\Keyboard Layout\Preload", "2", "d002040c")
	State.Seed.Call("HKCU\Keyboard Layout\Preload", "3", "a002040c")
	State.Plan := []
	Result := KbdRegister_Uninstall("kbdmine", State.Ports)
	AssertTrue(Result["ok"], Result["detail"])
	AssertEqual(_KLT_Join([
		"input profile 040C:a002040c 1",
		"delete value HKCU\Keyboard Layout\Preload [2]",
		"delete value HKCU\Keyboard Layout\Substitutes [d002040c]",
		"delete value HKCU\Keyboard Layout\Preload [3]",
		"delete key " . _KBR_Layouts() . "\a002040c",
		"delete file C:\Windows\System32\kbdmine.dll (redirection off)",
		"delete file C:\Windows\SysWOW64\kbdmine.dll",
		"delete key " . _KBR_Entry()], "`n"), _KBR_Plan(State))
	AssertEqual("0000040c", State.Ports["reg_read"].Call("HKCU\Keyboard Layout\Preload", "1"), "the user's own stays")
	AssertEqual("new", KbdRegister_Inspect("kbdmine", State.Ports)["state"])
	; Without the entry nothing is Ergopti's: nothing is touched.
	State.Plan := []
	AssertEqual("uninstall_failed", KbdRegister_Uninstall("kbdmine", State.Ports)["code"])
	AssertEqual("", _KBR_Plan(State))
}

Test("kbd register: the command lines and the elevated run write the result the driver reads (kbd-register)",
	_KBR_CommandCase)

_KBR_CommandCase() {
	Source := KbdRegister_Command(["install", "C:\Users\me\App Data\stage"], Map("compiled", false,
		"executable", "C:\AHK\AutoHotkey64.exe", "entry", "C:\E\ui\layout_manager\kbd_register.ahk"))
	AssertEqual("C:\AHK\AutoHotkey64.exe", Source["executable"])
	AssertEqual('/force C:\E\ui\layout_manager\kbd_register.ahk install "C:\Users\me\App Data\stage"', Source["arguments"])
	Compiled := KbdRegister_Command(["uninstall", "kbdmine"], Map("compiled", true, "executable", "C:\E\ErgoptiPlus.exe",
		"entry", ""))
	AssertEqual("/force --kbd-register uninstall kbdmine", Compiled["arguments"])
	AssertTrue(KbdRegister_IsInvocation(["--kbd-register", "install", "x"]))
	AssertFalse(KbdRegister_IsInvocation(["install", "x"]))
	State := _KBR_Machine()
	Request := _KBR_Request(State)
	Digests := ""
	for Arch, Digest in Request["sha256"]
		Digests .= (A_Index > 1 ? "," : "") . '"' . Arch . '":"' . Digest . '"'
	State.Files["C:\stage\kbdmine\request.json"] := '{"action":"install","dll":"kbdmine","text":"My Layout",'
		. '"lcid":"040c","company":"Me","sha256":{' . Digests . '}}'
	AssertEqual(0, KbdRegister_Run(["install", "C:\stage\kbdmine"], State.Ports))
	Result := JsonParse(State.Files["C:\stage\kbdmine\result.json"])
	AssertEqual(1, Result["ok"])
	AssertEqual("a002040c", Result["klid"])
	AssertContains(_KBR_Plan(State), "[Publisher] REG_SZ Me")
	AssertEqual(0, KbdRegister_Run(["uninstall", "kbdmine", "C:\stage\kbdmine"], State.Ports))
	AssertEqual(1, KbdRegister_Run(["uninstall", "kbdmine", "C:\stage\kbdmine"], State.Ports), "nothing left to remove")
	AssertEqual(1, KbdRegister_Run(["format", "C:\"], State.Ports), "an unknown action does nothing")
}
