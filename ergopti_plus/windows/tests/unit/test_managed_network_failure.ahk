; tests/unit/test_managed_network_failure.ahk

; ==============================================================================
; MODULE: Managed Network Failure Corpus Replay
; DESCRIPTION:
; Replays independent typed native receipt expectations against the shared AHK
; interpreter. Actual networking and native trust remain integration gates.
; ==============================================================================

#Requires AutoHotkey v2.0

_ManagedNetwork_TestCorpus() {
	global _SharedDir
	Policy := JsonParse(FileRead(_SharedDir . "\modules\network\managed_network.json", "UTF-8"))
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\network\failure_vectors.json", "UTF-8"))
	Contract := ManagedNetworkFailureContract(Policy)
	AssertEqual(1, Corpus["schema_version"])
	AssertEqual(53, Corpus["vectors"].Length, "independent network failure inventory")
	Labels := Map("retry", "network.action.retry", "proxy_settings", "network.action.open_proxy_settings",
		"download_folder", "network.action.open_download_folder", "diagnostics", "error_dialog.open_log")
	for Vector in Corpus["vectors"] {
		Id := Vector["id"]
		Report := Contract.Classify(Vector["receipt"], Vector.Get("capabilities", Map()))
		AssertEqual(Vector["cause"], Report["cause"], Id)
		AssertEqual("network.failure." . Vector["cause"], Report["message_key"], Id . " locale")
		AssertEqual(Vector["actions"].Length, Report["actions"].Length, Id . " action count")
		for Index, Action in Report["actions"] {
			AssertEqual(Vector["actions"][Index], Action["id"], Id . " action order")
			AssertEqual(Labels[Vector["actions"][Index]], Action["label_key"], Id . " action locale")
			for Key in Action
				AssertTrue(Key == "id" || Key == "label_key", "actions must not expose raw native metadata")
		}
		if Vector.Has("evidence")
			AssertEqual(Vector["evidence"], Report["evidence"], Id . " evidence")
		for Key in Report
			AssertTrue(Key == "cause" || Key == "message_key" || Key == "evidence" || Key == "actions",
				"failure reports must not copy URLs, stderr, paths or credentials")
	}
}
Test("Managed network failures: independent shared corpus", _ManagedNetwork_TestCorpus)

_ManagedNetwork_TestRetiredOwner() {
	global _SharedDir
	Policy := JsonParse(FileRead(_SharedDir . "\modules\network\managed_network.json", "UTF-8"))
	Contract := ManagedNetworkFailureContract(Policy)
	Current := Map("owner_alive", true, "retry_available", true, "diagnostics_available", true)
	AssertEqual("retry", Contract.Actions("unknown", Current)[1]["id"])
	Current["owner_alive"] := false
	Actions := Contract.Actions("unknown", Current)
	AssertEqual(1, Actions.Length)
	AssertEqual("diagnostics", Actions[1]["id"])
}
Test("Managed network failures: action click rechecks retired owner", _ManagedNetwork_TestRetiredOwner)

_ManagedNetwork_TestPolicyRefusals() {
	global _SharedDir
	Text := FileRead(_SharedDir . "\modules\network\managed_network.json", "UTF-8")
	for Kind in ["field", "vacuous", "capability"] {
		Policy := JsonParse(Text)
		if Kind == "field"
			Policy["rules"][1]["when"]["typo_stage"] := ["file_write"]
		else if Kind == "vacuous"
			Policy["rules"][1]["when"] := Map()
		else
			Policy["actions"]["retry"]["requires"] := ["imaginary_owner"]
		Refused := false
		try ManagedNetworkFailureContract(Policy)
		catch
			Refused := true
		AssertTrue(Refused, "invalid policy must fail closed: " . Kind)
	}
}
Test("Managed network failures: invalid canonical policy is refused", _ManagedNetwork_TestPolicyRefusals)

_ManagedNetwork_TestAlternateCapabilities() {
	global _SharedDir
	Policy := JsonParse(FileRead(_SharedDir . "\modules\network\managed_network.json", "UTF-8"))
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\network\alternative_capability_vectors.json", "UTF-8"))
	Contract := ManagedNetworkFailureContract(Policy)
	AssertEqual(1, Corpus["schema_version"])
	AssertEqual(7, Corpus["vectors"].Length, "independent alternative capability inventory")
	for Vector in Corpus["vectors"] {
		Id := Vector["id"]
		Actions := Contract.Actions(Vector["cause"], Vector["capabilities"])
		AssertEqual(Vector["actions"].Length, Actions.Length, Id . " action count")
		for Index, Action in Actions {
			AssertEqual(Vector["actions"][Index], Action["id"], Id . " action order")
			AssertEqual("mlx.use_ollama", Action["label_key"], Id . " action locale")
			for Key in Action
				AssertTrue(Key == "id" || Key == "label_key", "alternate action must not expose raw metadata")
		}
	}
}
Test("Managed network failures: independent alternative capability corpus", _ManagedNetwork_TestAlternateCapabilities)
