; tests/unit/infra/config/persistence/test_config_cleanup_refresh_lifecycle.ahk

; ==============================================================================
; MODULE: Cleanup Preview Refresh Ownership
; DESCRIPTION:
; The native window can close while any of the preview's file reads or scanner
; pumps messages. A retired session must stop work and keep its scan revoked.
; ==============================================================================

#Requires AutoHotkey v2.0

_CUKR_Read(World, Path) {
	World.Reads += 1
	World.Events.Push("read")
	if World.Boundary == (World.Reads == 1 ? "first-read" : "last-read")
		World.Session.Close()
	return World.Changed && World.Reads == 2 ? "changed bytes" : "original bytes"
}

_CUKR_Find(World, Path) {
	World.Events.Push("scan")
	if World.Boundary == "scan"
		World.Session.Close()
	return World.Scan
}

_CUKR_RefreshOwnership(Boundary, Changed := false) {
	Session := ConfigCleanupSession("private-unused-fixture.toml")
	World := { Session: Session, Boundary: Boundary, Changed: Changed, Reads: 0,
		Events: [], Scan: Map("status", "ok", "source", "original bytes",
			"keys", [Map("section", "obsolete", "key", "old", "value", "true")]) }
	if Boundary == "closed"
		Session.Close()
	Result := Session.Refresh(_CUKR_Read.Bind(World), _CUKR_Find.Bind(World))
	if Boundary != "live" {
		AssertEqual(0, Result, "closing during refresh must produce no page response")
		AssertTrue(Session.Closed)
		AssertEqual(0, Session.Scan, "closing keeps scan ownership revoked")
		AssertEqual("", Session.Source, "a retired refresh cannot admit source bytes")
		AssertEqual("empty", Session.State["status"], "closed preview state stays unpublished")
		AssertEqual(0, Session.State["keys"].Length)
		ExpectedCalls := Boundary == "closed" ? 0 : Boundary == "first-read" ? 1 : Boundary == "scan" ? 2 : 3
		AssertEqual(ExpectedCalls, World.Events.Length, "no later I/O may start after the close receipt")
	} else {
		AssertTrue(Result == Session.State)
		AssertTrue(Session.Scan == World.Scan)
		AssertEqual(Changed ? "changed" : "ready", Result["status"])
		AssertEqual(Changed ? "" : "original bytes", Session.Source)
		AssertEqual(3, World.Events.Length)
	}
}
for Boundary in ["closed", "first-read", "scan", "last-read"]
	Test("cleanup preview: " . Boundary . " closure revokes refresh publication (cleanup-refresh-close)",
		_CUKR_RefreshOwnership.Bind(Boundary))
Test("cleanup preview: live coherent refresh still admits its scan (cleanup-refresh-close)",
	_CUKR_RefreshOwnership.Bind("live"))
Test("cleanup preview: live changed bytes still require refresh (cleanup-refresh-close)",
	_CUKR_RefreshOwnership.Bind("live", true))


; A second writer can replace the file twice while the scanner pumps native
; I/O. Matching reads around that scan do not prove which image it classified.
_CUKR_TransientSourceScan(Original, Transient, Path) {
	AssertTrue(FSWriteDurable(Path, Transient))
	try {
		Scan := ConfigUnusedKeysFind(Path)
		AssertEqual("ok", Scan["status"])
		AssertEqual(1, Scan["keys"].Length, "the transient image has exactly one outdated consent value")
		AssertEqual("enabled", Scan["keys"][1]["key"])
		return Scan
	} finally AssertTrue(FSWriteDurable(Path, Original))
}

_CUKR_TransientSourceCannotAuthorizeHealthyCleanup(OriginalValue) {
	Root := A_Temp . "\ergopti_cleanup_aba_" . PLC_CurrentProcessId() . "_" . A_TickCount
	DirCreate(Root)
	Path := Root . "\config.toml"
	Original := "[_meta]`nschema_version = " . ConfigMigrateCurrentVersion()
		. "`n[metrics]`nenabled = " . OriginalValue . "`n"
	Transient := StrReplace(Original, "enabled = " . OriginalValue, 'enabled = "invalid"')
	try {
		AssertTrue(FSWriteDurable(Path, Original))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"], "the independently authored healthy configuration is writable")
		AssertEqual(0, ConfigUnusedKeysFind(Path)["keys"].Length, "the restored image contains no unused settings")
		Session := ConfigCleanupSession(Path)
		State := Session.Refresh(FSReadUtf8Exact, _CUKR_TransientSourceScan.Bind(Original, Transient))
		if State["status"] == "ready"
			Session.Handle(Map("action", "clean", "session", Session.Token))
		AssertEqual(Original, FSReadUtf8Exact(Path),
			"a scan of a transient invalid image must never authorize removal of the restored healthy consent")
		AssertEqual("changed", State["status"], "the preview must require a coherent refresh")
		AssertEqual(0, Session.Handle(Map("action", "clean", "session", Session.Token)))
		AssertFalse(JsonParse(Session.Json()).Has("source"), "private scanned source never enters the page payload")
	} finally DirDelete(Root, true)
}
for _CUKR_Consent in ["true", "false"]
	Test("cleanup preview: an ABA source change cannot remove enabled=" . _CUKR_Consent . " (cleanup-preview-source-aba)",
		_CUKR_TransientSourceCannotAuthorizeHealthyCleanup.Bind(_CUKR_Consent))


_CUKR_AbsentSourceRemainsEmpty() {
	Path := A_Temp . "\ergopti_cleanup_absent_" . PLC_CurrentProcessId() . "_" . A_TickCount . ".toml"
	AssertFalse(FSExists(Path), "the absent-source control must begin absent")
	Session := ConfigCleanupSession(Path)
	State := Session.Refresh()
	AssertEqual("empty", State["status"], "a genuine absent source is a coherent empty preview")
	AssertEqual(0, State["keys"].Length)
	AssertEqual(0, Session.Handle(Map("action", "clean", "session", Session.Token)))
	AssertFalse(FSExists(Path), "an empty preview cannot materialize the absent file")
}
Test("cleanup preview: an absent source remains a coherent empty preview (cleanup-preview-source-aba)",
	_CUKR_AbsentSourceRemainsEmpty)


_CUKR_MalformedScanKeepsMutationDisabled() {
	Root := A_Temp . "\ergopti_cleanup_malformed_" . PLC_CurrentProcessId() . "_" . A_TickCount
	DirCreate(Root)
	Path := Root . "\config.toml"
	Source := "[unterminated`n"
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		Session := ConfigCleanupSession(Path)
		State := Session.Refresh()
		AssertEqual("failed", State["status"], "a failed scan has no source admission to consume")
		AssertEqual(0, State["keys"].Length)
		AssertEqual(0, Session.Handle(Map("action", "clean", "session", Session.Token)))
		AssertEqual(Source, FSReadUtf8Exact(Path), "the malformed source remains byte-exact")
	} finally DirDelete(Root, true)
}
Test("cleanup preview: a failed scan cannot admit source or mutation (cleanup-preview-source-aba)",
	_CUKR_MalformedScanKeepsMutationDisabled)
