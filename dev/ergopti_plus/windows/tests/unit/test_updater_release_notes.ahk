; tests/unit/test_updater_release_notes.ahk

; ==============================================================================
; MODULE: Updater Release Notes Tests
; DESCRIPTION:
; The update prompt shows a release's notes. It used to build its own HTML page
; (_Updater_MakeMarkdownHtml) and hand it to innerHTML, so the CI changelog fold
; appeared as literal <details> text after the download tables, with a looser
; link policy than the Versions window. It now loads the shared release-notes
; page, and the native (no-WebView2) views show a plain-text projection of the
; same changelog section.
;
; FEATURES & RATIONALE:
; 1. Cross-driver vectors: _Updater_ReleaseNotesChangelog ports the changelog
;    extraction of _shared/ui/changelog/release_body.js; both replay
;    _shared/tests/corpus/updater/release_body_vectors.json.
; 2. Seed boundary: the release body reaches the page as one HTML-safe JSON
;    string literal, never as markup.
; 3. Bridge boundary: only the exact navigated document with its session token
;    may ask to open a URL, and open_url is the only action.
; ==============================================================================

#Requires AutoHotkey v2.0

_URN_LoadVectors() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\updater\release_body_vectors.json"
	Assert(FileExist(Path) != "", "release body vectors must exist at: " . Path)
	Vectors := JsonParse(FileRead(Path, "UTF-8"))["vectors"]
	Assert(Vectors.Length >= 8, "release body vectors: >=8 expected, got " . Vectors.Length)
	return Vectors
}

_URN_Join(LineArray) {
	Out := ""
	for Pos, Line in LineArray
		Out .= (Pos > 1 ? "`n" : "") . Line
	return Out
}

_URN_VectorParity() {
	for _, V in _URN_LoadVectors()
		AssertEqual(_URN_Join(V["changelog"]), _Updater_ReleaseNotesChangelog(_URN_Join(V["body"])),
			"changelog extraction must match the shared splitter [" . V["id"] . "]")
}
Test("Updater release notes: changelog extraction replays the shared vectors (release-notes-vectors)",
	_URN_VectorParity)

_URN_PlainTextShowsOnlyTheChangelog() {
	for _, V in _URN_LoadVectors() {
		if (V["id"] != "folded-after-downloads")
			continue
		Plain := _Updater_ReleaseNotesToPlain(_URN_Join(V["body"]))
		Assert(InStr(Plain, "Keep the daemon") > 0, "the plain notes must keep the changelog entries")
		for _, Leak in ["keyboard layout only", "Ergopti_windows.exe", "<details", "<summary", "</details>", "**"]
			Assert(InStr(Plain, Leak) = 0, "the plain notes must not show '" . Leak . "'")
		AssertEqual(t("updater.changelog_empty"), _Updater_ReleaseNotesToPlain(""),
			"an empty body must show the localized empty-notes message")
		return
	}
	Assert(false, "the folded-after-downloads vector is missing")
}
Test("Updater release notes: native views show the changelog as plain text (release-notes-plain)",
	_URN_PlainTextShowsOnlyTheChangelog)

_URN_SeedKeepsTheBodyAsData() {
	Body := "</script><script>window.auditCanary=1</script> " . '"quoted" \ ' . Chr(0x2028) . "é"
	Seed := _Updater_ReleaseNotesSeed(Body, "session-token")
	Assert(InStr(Seed, "<") = 0 && InStr(Seed, ">") = 0,
		"the seed must carry no HTML-significant character a host could parse")
	Assert(RegExMatch(Seed, 'body:("(?:[^"\\]|\\.)*")', &Literal) > 0,
		"the seed must pass the body as one JSON string literal")
	AssertEqual(Body, JsonParse(Literal[1]), "the body must round-trip exactly through the seed")
	Assert(InStr(Seed, 'session:"session-token"') > 0, "the seed must carry the bridge session")
	ControlText := "before" . Chr(8) . Chr(12) . Chr(0x1F) . "after"
	AssertEqual(ControlText, JsonParse(JsonStringLiteral(ControlText, true)),
		"the shared script-string encoder must round-trip every C0 control character")
}
Test("Updater release notes: the seed passes the body as data, never markup (release-notes-seed)",
	_URN_SeedKeepsTheBodyAsData)

_URN_FakeArgs(PaneSource, Message) {
	return { Source: PaneSource, TryGetWebMessageAsString: (*) => Message }
}

_URN_BridgeAcceptsOnlyTheSessionOpenUrl() {
	PaneSource := "https://ergopti.releasenotes/ui/release_notes/index.html?cb=1"
	Url := "https://github.com/adrienm7/ergopti/pull/1"
	Opened := []
	OpenFn := (Target, *) => Opened.Push(Target)
	Good := '{"action":"open_url","url":"' . Url . '","session":"s1"}'

	_Updater_OnReleaseNotesMessage(PaneSource, "s1", 0, _URN_FakeArgs(PaneSource . "x", Good), OpenFn)
	AssertEqual(0, Opened.Length, "a message from another document must be ignored")
	_Updater_OnReleaseNotesMessage(PaneSource, "s1", 0,
		_URN_FakeArgs(PaneSource, '{"action":"open_url","url":"' . Url . '","session":"s2"}'), OpenFn)
	AssertEqual(0, Opened.Length, "a message with another session must be ignored")
	_Updater_OnReleaseNotesMessage(PaneSource, "s1", 0,
		_URN_FakeArgs(PaneSource, '{"action":"fetch","url":"' . Url . '","session":"s1"}'), OpenFn)
	AssertEqual(0, Opened.Length, "an action other than open_url must be ignored")
	_Updater_OnReleaseNotesMessage(PaneSource, "s1", 0, _URN_FakeArgs(PaneSource, "not json"), OpenFn)
	AssertEqual(0, Opened.Length, "an unreadable message must be ignored")

	_Updater_OnReleaseNotesMessage(PaneSource, "s1", 0, _URN_FakeArgs(PaneSource, Good), OpenFn)
	AssertEqual(1, Opened.Length, "the session's open_url must reach the manual URL opener")
	AssertEqual(Url, Opened.Length ? Opened[1] : "", "the opener must receive the clicked URL")
}
Test("Updater release notes: the pane bridge accepts only its session's open_url (release-notes-bridge)",
	_URN_BridgeAcceptsOnlyTheSessionOpenUrl)
