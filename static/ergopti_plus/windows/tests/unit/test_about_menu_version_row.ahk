; static/ergopti_plus/windows/tests/unit/test_about_menu_version_row.ahk

; ==============================================================================
; MODULE: About Menu Version Row Tests
; DESCRIPTION:
; The first row of the Version / Updates submenu read « ErgoptiPlus local » for
; every source run and « ErgoptiPlus 0.0.0-dev.144 » for a release: no commit,
; so nobody could tell which checkout or build a demo was running. It now
; names the build kind and the commit through the shared formatter
; (Updater_VersionRowLabel): « Version 0.0.0-dev.144 (c3005e0b9) » for a stamped
; release, « Version locale (c3005e0b9) » for a source run, and the unknown
; commit's own words with a logged WARNING when neither BUNDLE_COMMIT nor .git
; says.
;
; The identity goes through Updater_ResolveBuildIdentity and the real commit
; resolver on throwaway repositories of each .git shape (loose ref, packed ref,
; detached HEAD, linked worktree), and the row through _MI_AboutUpdateRows.
; ==============================================================================

#Requires AutoHotkey v2.0

global _AVR_SHA := "c3005e0b9aaaabbbbccccddddeeeeffff0000111"
global _AVR_SHORT := "c3005e0b9"

; Resets the ring buffer at DEBUG so a test reads only its own lines.
_AVR_ResetLog() {
	global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_MIN_LEVEL
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT
	LOGGER_RING_BUFFER := []
	LOGGER_RING_CURSOR := 0
	LOGGER_MIN_LEVEL := "DEBUG"
	_LOGGER_DEDUP_KEY := ""
	_LOGGER_DEDUP_LEVEL := ""
	_LOGGER_DEDUP_COUNT := 0
	_LoggerRefreshFastFlags()
}

; Every ring line joined.
_AVR_RingText() {
	Text := ""
	for _, Line in LoggerRingBufferSnapshot()
		Text .= Line . "`n"
	return Text
}

; Writes one fixture file without a BOM, creating its directory.
_AVR_Put(Path, Content) {
	SplitPath(Path, , &Dir)
	DirCreate(Dir)
	FileAppend(Content, Path, "UTF-8-RAW")
}

; A throwaway checkout of one .git shape whose HEAD resolves to _AVR_SHA.
; @returns {String} The directory the lookup starts from.
_AVR_MakeCheckout(Root, Shape) {
	global _AVR_SHA
	DirCreate(Root . "\repo\static")
	Git := Root . "\repo\.git"
	switch Shape {
		case "loose_ref":
			_AVR_Put(Git . "\HEAD", "ref: refs/heads/dev`n")
			_AVR_Put(Git . "\refs\heads\dev", _AVR_SHA . "`n")
		case "packed_ref":
			_AVR_Put(Git . "\HEAD", "ref: refs/heads/dev`n")
			_AVR_Put(Git . "\packed-refs", "# pack-refs with: peeled fully-peeled sorted`n"
				. "3b924cd46aaaabbbbccccddddeeeeffff0000111 refs/heads/main`n"
				. _AVR_SHA . " refs/heads/dev`n")
		case "detached_head":
			_AVR_Put(Git . "\HEAD", _AVR_SHA . "`n")
		case "worktree_file":
			Main := Root . "\main\.git"
			_AVR_Put(Git, "gitdir: " . Main . "\worktrees\wt`n")
			_AVR_Put(Main . "\worktrees\wt\HEAD", "ref: refs/heads/wip/about-menu`n")
			_AVR_Put(Main . "\worktrees\wt\commondir", "../..`n")
			_AVR_Put(Main . "\refs\heads\wip\about-menu", _AVR_SHA . "`n")
		default:
			throw ValueError("Unknown checkout shape: " . Shape)
	}
	return Root . "\repo\static"
}

_AVR_NewRoot() {
	return A_Temp . "\ergopti_avr_" . A_TickCount . "_" . Random(1000, 9999)
}

; A channel setter the rows never call here.
_AVR_NoChannel(*) {
	return true
}

; The first row _MI_AboutUpdateRows draws for an identity.
_AVR_VersionRow(Identity, IsLocal) {
	Rows := _MI_AboutUpdateRows(IsLocal, _AVR_NoChannel, () => Identity)
	return Rows[1]["label"]
}





; =====================================
; =====================================
; ======= 1/ Build identity ===========
; =====================================
; =====================================

_AVR_PackagedShowsVersionAndCommit() {
	global _AVR_SHA, _AVR_SHORT
	Root := _AVR_NewRoot()
	try {
		Start := _AVR_MakeCheckout(Root, "detached_head")
		_AVR_ResetLog()
		Identity := Updater_ResolveBuildIdentity("0.0.0-dev.144", Start, _AVR_SHA)
		AssertEqual("release", Identity["kind"])
		AssertEqual("0.0.0-dev.144", Identity["version"])
		AssertEqual(_AVR_SHORT, Identity["commit"], "a packaged build names its stamped commit")
		AssertEqual(StrReplace(StrReplace(t("menu.about.version_release"), "{version}", "0.0.0-dev.144"),
			"{commit}", _AVR_SHORT), _AVR_VersionRow(Identity, false))
		AssertEqual(0, InStr(_AVR_RingText(), "Build commit unknown"), "a stamped commit logs no warning")
	} finally {
		try DirDelete(Root, true)
	}
}
Test("About version row: a packaged release shows its version and commit", _AVR_PackagedShowsVersionAndCommit)

_AVR_LocalCheckoutNamesItsCommit() {
	global _AVR_SHORT
	for _, Shape in ["loose_ref", "packed_ref", "detached_head", "worktree_file"] {
		Root := _AVR_NewRoot()
		try {
			Start := _AVR_MakeCheckout(Root, Shape)
			_AVR_ResetLog()
			Identity := Updater_ResolveBuildIdentity("local", Start, "__BUNDLE_COMMIT__")
			AssertEqual("local", Identity["kind"], Shape)
			AssertEqual("", Identity["version"], Shape)
			AssertEqual(_AVR_SHORT, Identity["commit"], "the checkout's commit (" . Shape . ")")
			AssertEqual(StrReplace(t("menu.about.version_local"), "{commit}", _AVR_SHORT),
				_AVR_VersionRow(Identity, true), "the local row (" . Shape . ")")
			AssertEqual(0, InStr(_AVR_RingText(), "Build commit unknown"), "a resolved commit logs no warning")
		} finally {
			try DirDelete(Root, true)
		}
	}
}
Test("About version row: a source checkout says it is local and names its commit (every .git shape)",
	_AVR_LocalCheckoutNamesItsCommit)

_AVR_MissingGitDataIsUnknownAndLogged() {
	_AVR_ResetLog()
	Start := A_Temp . "\ergopti_avr_no_repo_" . A_TickCount
	Identity := Updater_ResolveBuildIdentity("local", Start, "__BUNDLE_COMMIT__")
	AssertEqual("local", Identity["kind"])
	AssertEqual("", Identity["commit"], "an unknown commit is never guessed")
	AssertEqual(StrReplace(t("menu.about.version_local"), "{commit}", t("menu.about.commit_unknown")),
		_AVR_VersionRow(Identity, true), "the row says the commit is unknown")
	Text := _AVR_RingText()
	Assert(InStr(Text, "[WARNING] [BuildCommit] Build commit unknown: no build stamp"), Text)
}
Test("About version row: missing git data reads as an unknown commit, logged with its reason",
	_AVR_MissingGitDataIsUnknownAndLogged)

_AVR_IdentityIsResolvedOnce() {
	First := Updater_BuildIdentity()
	AssertTrue(IsObject(First) && First.Has("kind") && First.Has("commit"), "the identity carries its fields")
	AssertTrue(Updater_BuildIdentity() == First, "the same identity is served to every rebuild")
	Body := _StripFullLineComments(_DriverFuncBody("Updater_BuildIdentity"))
	Assert(Body != "", "Updater_BuildIdentity must be readable")
	Assert(InStr(Body, "static Identity") > 0, "the identity is resolved once per script")
	Assert(InStr(Body, "Updater_CurrentVersion()") > 0, "its version comes from the version owner")
}
Test("About version row: the identity is resolved once per script", _AVR_IdentityIsResolvedOnce)
