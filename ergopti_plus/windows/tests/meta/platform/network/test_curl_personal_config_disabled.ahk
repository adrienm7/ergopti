; tests/meta/platform/network/test_curl_personal_config_disabled.ahk

; ==============================================================================
; MODULE: curl Personal Configuration Guard
; DESCRIPTION:
; curl ignores the user's personal .curlrc only when --disable is its very
; first argument. Both Ollama command lines once omitted it while the managed
; transport passed it, so an inherited .curlrc could add headers or rewrite
; output for local model requests (the behavioural proof is
; test_llm_api_ollama_curl_personal_config.ahk). This scan covers the whole
; class: every driver site that composes a curl.exe command line or argv must
; put --disable first, so a new launch site cannot regress silently.
; ==============================================================================

#Requires AutoHotkey v2.0

_CPCD_EveryCurlLaunchDisablesPersonalConfig() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the curl personal-config guard")
	Subjects := 0
	Offending := []
	; Command strings start with the quoted executable path.
	Position := 1
	while Position := RegExMatch(Src, 'curl_exe\s*\.\s*\x27"\s*([^\s\x27]*)', &Match, Position) {
		Subjects += 1
		if Match[1] != "--disable"
			Offending.Push("command line followed by '" . Match[1] . "'")
		Position += Match.Len
	}
	; Argument vectors pass the executable, then an array of arguments.
	Position := 1
	while Position := RegExMatch(Src, 'CurlExe\s*,\s*\[\s*"([^"]*)"', &Match, Position) {
		Subjects += 1
		if Match[1] != "--disable"
			Offending.Push("argv starting with '" . Match[1] . "'")
		Position += Match.Len
	}
	AssertTrue(Subjects >= 4, "the guard must see every known curl launch (found " . Subjects . ")")
	Report := ""
	for Item in Offending
		Report .= (Report == "" ? "" : "; ") . Item
	AssertEqual(0, Offending.Length, "every curl launch must pass --disable first: " . Report)
}
Test("curl: every driver launch passes --disable first (ollama-curl-personal-config)",
	_CPCD_EveryCurlLaunchDisablesPersonalConfig)
