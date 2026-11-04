; tests/meta/corpus/test_corpus_updater_redirect.ahk

; ==============================================================================
; MODULE: Updater Redirect Corpus Consumer (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/http/get_redirect_vectors.json through
; Get-ErgoptiUpdaterRedirectDecision, the pure decision of the updater transport,
; in a real Windows PowerShell child.
;
; FEATURES & RATIONALE:
; 1. The corpus describes the curl client of macOS and Linux. Its receipt fields
;    (curl_exit, num_redirects) and carried headers have no meaning for a transport
;    that sends no credential and reads the Location header itself, so only the
;    action of a case is compared, and the cases that depend on those fields are
;    pinned with that reason rather than skipped.
; 2. Every case agrees or is pinned in _CTUR_PENDING with its reason, so a change
;    forces the inventory to shrink and a new divergence turns the suite red.
; ==============================================================================

#Requires AutoHotkey v2.0



global _CTUR_CASE_COUNT := 33

global _CTUR_CURL_RECEIPT := "the case reads a curl receipt field or its native resolved URL, which this transport does not have"
global _CTUR_HTTPS_ONLY := "the updater always floors at HTTPS; the corpus also covers a caller without the floor"
global _CTUR_REDIRECT_SET := "the updater follows 301, 302, 303, 307 and 308 only; the curl client follows any 3xx with a Location"
global _CTUR_NO_VISITED := "the updater bounds a loop by its hop limit and deadline and keeps no visited set"
global _CTUR_URI_ESCAPE := "the Location is resolved by System.Uri, which escapes a literal space where the curl client refuses it"
global _CTUR_MISSING_LOCATION := "a redirect without a Location is refused here, the curl client keeps the response as terminal"

global _CTUR_PENDING := Map(
	"http same origin permitted without floor", _CTUR_HTTPS_ONLY,
	"relative value cannot impersonate native resolved URL", _CTUR_CURL_RECEIPT,
	"literal space refused", _CTUR_URI_ESCAPE,
	"exact prior URL loop refused", _CTUR_NO_VISITED,
	"transport failure never follows Location", _CTUR_CURL_RECEIPT,
	"native prior following is invalid evidence", _CTUR_CURL_RECEIPT,
	"missing Location retains redirect response", _CTUR_MISSING_LOCATION,
	"native 300 Location preserves curl behavior", _CTUR_REDIRECT_SET,
	"native 304 Location preserves curl behavior without ETag port", _CTUR_REDIRECT_SET,
	"native 399 Location preserves curl behavior", _CTUR_REDIRECT_SET,
	"original HTTP floor stays HTTP after an intermediate HTTPS upgrade", _CTUR_HTTPS_ONLY)

_CTUR_CorpusPath() {
	return A_ScriptDir . "\..\..\_shared\tests\corpus\http\get_redirect_vectors.json"
}

_CTUR_Corpus() {
	static Corpus := JsonParse(FileRead(_CTUR_CorpusPath(), "UTF-8"))
	return Corpus
}

; One real PowerShell child answers every case: its start costs about a second.
_CTUR_Decisions() {
	static Decisions := 0
	global _VendorDir
	if Decisions is Map
		return Decisions
	Output := A_Temp . "\ergopti_redirect_decisions_" . DllCall("GetCurrentProcessId", "UInt") . ".txt"
	Args := [_Updater_PowerShellPath(), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", A_ScriptDir . "\fixtures\updater_redirect_decisions.ps1",
		"-Module", _VendorDir . "\ergopti_updater_download.ps1", "-Corpus", _CTUR_CorpusPath(), "-Output", Output]
	Command := ""
	for Arg in Args
		Command .= (Command == "" ? "" : " ") . _Updater_QuoteCreateProcessArg(Arg)
	try {
		AssertEqual(0, RunWait(Command, , "Hide"), "the redirect decision child must complete")
		Found := Map()
		for Line in StrSplit(Trim(FileRead(Output, "UTF-8"), "`r`n"), "`n", "`r") {
			Fields := StrSplit(Line, "`t")
			Found[Integer(Fields[1])] := Fields[2]
		}
		Decisions := Found
	} finally {
		if FileExist(Output)
			FileDelete(Output)
	}
	return Decisions
}

_CTUR_ReplayCase(Index, Entry) {
	global _CTUR_PENDING
	Actual := _CTUR_Decisions()[Index]
	Expected := Entry["expected"]["action"]
	Name := Entry["name"]
	if _CTUR_PENDING.Has(Name)
		AssertTrue(Actual != Expected, Name . " now agrees: remove it from _CTUR_PENDING")
	else
		AssertEqual(Expected, Actual, Name)
}

_CTUR_CountAndPendingAreCurrent() {
	global _CTUR_CASE_COUNT, _CTUR_PENDING
	Cases := _CTUR_Corpus()["cases"]
	AssertEqual(_CTUR_CASE_COUNT, Cases.Length, "get_redirect_vectors.json changed size")
	AssertEqual(Cases.Length, _CTUR_Decisions().Count, "every case reached the real decision")
	Known := Map()
	for Entry in Cases
		Known[Entry["name"]] := true
	for Name, Reason in _CTUR_PENDING {
		AssertTrue(Known.Has(Name), "stale pending entry: " . Name)
		AssertTrue(Reason != "", "a pending entry states its reason: " . Name)
	}
}
Test("updater redirect corpus: the count and the pending inventory are current", _CTUR_CountAndPendingAreCurrent)

_CTUR_RegisterCases() {
	for Index, Entry in _CTUR_Corpus()["cases"]
		Test("updater redirect corpus: " . Entry["name"], _CTUR_ReplayCase.Bind(Index, Entry))
}
_CTUR_RegisterCases()
