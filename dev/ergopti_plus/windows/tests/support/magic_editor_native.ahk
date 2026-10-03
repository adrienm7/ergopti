; tests/support/magic_editor_native.ahk

; ==============================================================================
; MODULE: Private Physical Shortcut Native Probe
; DESCRIPTION:
; Exercises the real AHK variant registry in a disposable owned child process.
; The probe registers and retires inert callbacks without publishing host input.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, StdOut

#Include %A_ScriptDir%\..\..\infra\chord.ahk
#Include %A_ScriptDir%\..\..\adapters\hotkey_registrar.ahk

LoggerDebug(*) => 0
LoggerWarn(*) => 0
LoggerError(*) => 0

OnError(_MEN_Error)
_MEN_Error(Err, *) {
	FileAppend(Err.Message, "**", "UTF-8-RAW")
	ExitApp(2)
}

_MEN_Require(Value, Message) {
	if !Value
		throw Error(Message)
}

_MEN_Criterion(*) => false

; A private local scope keeps #Warn strict without fixture globals shadowing
; production resolver locals and contaminating the exact stdout receipt.
_MEN_Run() {
	Us := DllCall("LoadKeyboardLayoutW", "Str", "00000409", "UInt", 0x80, "Ptr")
	_MEN_Require(Us != 0, "The native probe requires the actual US layout.")
	Resolver := HotkeyRegistrarNativeKeyResolverSnapshot(Map("get_layout", (*) => Us))
	for Pair in [["Cmd+Space", "#space", "SC039"], ["Cmd+D", "#d", "SC020"]] {
		Ordinary := _HotkeyRegistrarReserveResolvedOwned(Pair[1], (*) => 0, "native-probe-ordinary",
			HotkeyRegistrarResolvedNativeDescriptor(Pair[2], Resolver))
		_MEN_Require(Ordinary != "" && _HotkeyRegistrarActivate(Ordinary), "The ordinary owner must acquire its native alias.")
		Broker := HotkeyRegistrarReservePhysicalBroker("Cmd+" . Pair[3], (*) => 0,
			"native-probe-physical", HotkeyRegistrarResolvedNativeDescriptor("#" . Pair[3]), _MEN_Criterion)
		_MEN_Require(Broker != "", "The physical broker must coexist with an acknowledged ordinary VK alias.")
		_MEN_Require(HotkeyRegistrarSetEnabled(Ordinary, false), "The ordinary alias must acknowledge its reversible handoff.")
		_MEN_Require(_HotkeyRegistrarActivate(Broker), "The physical criterion must acknowledge native On.")
		_MEN_Require(HotkeyRegistrarSetEnabled(Broker, false), "The physical criterion must acknowledge native Off.")
		_MEN_Require(HotkeyRegistrarSetEnabled(Broker, true), "The identical physical criterion must acknowledge native resume.")
		_MEN_Require(HotkeyRegistrarUnbind(Broker), "The physical criterion must acknowledge exact retirement.")
		_MEN_Require(HotkeyRegistrarSetEnabled(Ordinary, true), "The ordinary alias must recover its actual native variant.")
		_MEN_Require(HotkeyRegistrarUnbind(Ordinary), "The recovered ordinary alias must retire exactly.")
	}

	HotIf()
	Hotkey("#SC027", (*) => 0, "Off I2")
	Unknown := HotkeyRegistrarReservePhysicalBroker("Cmd+SC027", (*) => 0,
		"native-probe-unknown", HotkeyRegistrarResolvedNativeDescriptor("#SC027"), _MEN_Criterion)
	_MEN_Require(Unknown == "", "An unknown global native producer must never be overwritten.")
	FileAppend("vk-aliases|context-retained|unknown-refused", "*", "UTF-8-RAW")
}

_MEN_Run()
ExitApp(0)
