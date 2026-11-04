; tests/fixtures/adapter_contract_empty_message.ahk

; ==============================================================================
; MODULE: Adapter Contract Empty-Message Fixture
; DESCRIPTION: Run actual registered adapter contract callbacks against a healthy
; endpoint or one that throws an Error with an empty message. No OS side effects.
; ==============================================================================

#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Off
#Warn All, StdOut
#Warn VarUnset, Off

if A_Args.Length != 2 || !(A_Args[1] == "healthy" || A_Args[1] == "empty-error")
	throw ValueError("Expected an adapter fixture mode and its owned receipt.")
global _ACMF_Mode := A_Args[1]
global _ACMF_Calls := 0
EnvSet("ERGOPTI_AHK_RESULTS_FILE", A_Args[2])
OnError(_ACMF_Fatal)

#Include ../test_framework.ahk
#Include ../unit/adapters/test_adapter_contract_vectors.ahk
#Include ../unit/adapters/test_adapter_contract_vectors_system.ahk

_ACMF_Endpoint() {
	global _ACMF_Mode, _ACMF_Calls
	_ACMF_Calls += 1
	FileAppend("# adapter-fixture-endpoint`n", "*", "UTF-8-RAW")
	if _ACMF_Mode == "empty-error"
		throw Error("")
}

NotifierSend(Message, Opts, DisplayFn := 0) {
	_ACMF_Endpoint()
	return true
}

CryptoSha256(Data) {
	_ACMF_Endpoint()
	return "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}

_ACMF_Fatal(Failure, *) {
	try FileAppend("adapter-contract-fixture-error|" . Type(Failure), "**", "UTF-8-RAW")
	finally ExitApp(2)
}

_ACMF_Selected := []
for _ACMF_Entry in TEST_REGISTRY {
	if _ACMF_Entry.name == "Notifier: send_info does not throw"
		|| _ACMF_Entry.name == "Crypto: sha256 handles the empty string"
		_ACMF_Selected.Push(_ACMF_Entry)
}
if _ACMF_Selected.Length != 2
	throw Error("The fixture must find both actual adapter contract callbacks.")
TEST_REGISTRY := _ACMF_Selected
RunTests()
