; tests/unit/modules/updater/test_updater_release_notes.ahk

; ==============================================================================
; MODULE: Updater Release Notes Tests
; DESCRIPTION:
; The update prompt shows a release's notes. It used to build its own HTML page
; (_Updater_MakeMarkdownHtml) and hand it to innerHTML, so the CI changelog fold
; appeared as literal <details> text after the download tables, with a looser
; link policy than the Versions window. It now loads the shared release-notes
; page, which splits the body itself: there is no native notes view to feed
; (maintainer decision 2026-11-21).
;
; FEATURES & RATIONALE:
; 1. Seed boundary: the release body reaches the page as one HTML-safe JSON
;    string literal, never as markup.
; 2. Bridge boundary: only the exact navigated document with its session token
;    may ask to open a URL, and open_url is the only action.
; ==============================================================================

#Requires AutoHotkey v2.0

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
