; tests/fixtures/adapter_contract_boolean_types.ahk

; ==============================================================================
; MODULE: Adapter Boolean Return-Type Fixture
; DESCRIPTION: Run actual registered return-boolean callbacks against native AHK
; Boolean values and their numeric String lookalikes, without touching OS state.
; ==============================================================================

#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Off
#Warn All, StdOut
#Warn VarUnset, Off

if A_Args.Length != 2
	throw ValueError("Expected a boolean fixture mode and its owned receipt.")
global _ACBF_Mode := A_Args[1]
if !(_ACBF_Mode == "integer-false" || _ACBF_Mode == "integer-true" || _ACBF_Mode == "string-false" || _ACBF_Mode == "string-true")
	throw ValueError("Unknown boolean fixture mode.")
global _ACBF_Value := InStr(_ACBF_Mode, "true") ? true : false
global _ACBF_Calls := 0
EnvSet("ERGOPTI_AHK_RESULTS_FILE", A_Args[2])
OnError(_ACBF_Fatal)

#Include ../test_framework.ahk
#Include ../unit/adapters/test_adapter_contract_vectors_system.ahk

_ACBF_Endpoint() {
	global _ACBF_Mode, _ACBF_Value, _ACBF_Calls
	_ACBF_Calls += 1
	FileAppend("# adapter-fixture-endpoint`n", "*", "UTF-8-RAW")
	return InStr(_ACBF_Mode, "string-") ? (_ACBF_Value ? "1" : "0") : _ACBF_Value
}

SFD_IsSecureField() => _ACBF_Endpoint()
NI_IsInternetReachable() => _ACBF_Endpoint()
NI_IsVpnActive() => _ACBF_Endpoint()
KS_IsDown(KeyName) => _ACBF_Endpoint()
KS_IsUp(KeyName) => _ACBF_Endpoint()
AL_IsRunning(ProcessName) => _ACBF_Endpoint()

_ACBF_Fatal(Failure, *) {
	try FileAppend("adapter-boolean-fixture-error|" . Type(Failure), "**", "UTF-8-RAW")
	finally ExitApp(2)
}

if Type(true) != "Integer" || Type(false) != "Integer" || true != 1 || false != 0
	throw Error("The fixture requires the native AHK Boolean representation.")

_ACBF_Names := Map(
	"SecureFieldDetector: isSecureField returns a boolean and never throws", true,
	"NetworkInfo: isInternetReachable returns a boolean", true,
	"NetworkInfo: isVpnActive returns a boolean", true,
	"KeyState: isDown returns a boolean", true,
	"KeyState: isUp returns a boolean", true,
	"AppLauncher: isRunning returns a boolean", true)
_ACBF_Selected := []
for _ACBF_Entry in TEST_REGISTRY {
	if _ACBF_Names.Has(_ACBF_Entry.name)
		_ACBF_Selected.Push(_ACBF_Entry)
}
if _ACBF_Selected.Length != _ACBF_Names.Count
	throw Error("The fixture must find every actual boolean-return callback exactly once.")
TEST_REGISTRY := _ACBF_Selected
RunTests()
