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
		Events: [], Scan: Map("status", "ok", "keys", [Map("section", "obsolete", "key", "old", "value", "true")]) }
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
