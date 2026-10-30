; tests/meta/suite/test_adapter_contract_boolean_types.ahk

; ==============================================================================
; MODULE: Adapter Boolean Type Contracts
; DESCRIPTION: Numeric equality in AHK also accepts String "0" and "1". Execute
; actual registered type-contract callbacks with both Boolean values and both
; String lookalikes so return-boolean coverage cannot silently accept text.
; ==============================================================================

#Requires AutoHotkey v2.0

Test("adapter contract boolean: native false remains valid (boolean-contract-type)",
	_ACED_Receive.Bind("integer-false", "adapter_contract_boolean_types.ahk", 6, 0))
Test("adapter contract boolean: native true remains valid (boolean-contract-type)",
	_ACED_Receive.Bind("integer-true", "adapter_contract_boolean_types.ahk", 6, 0))
Test("adapter contract boolean: numeric false text is rejected (boolean-contract-type)",
	_ACED_Receive.Bind("string-false", "adapter_contract_boolean_types.ahk", 6, 1))
Test("adapter contract boolean: numeric true text is rejected (boolean-contract-type)",
	_ACED_Receive.Bind("string-true", "adapter_contract_boolean_types.ahk", 6, 1))
