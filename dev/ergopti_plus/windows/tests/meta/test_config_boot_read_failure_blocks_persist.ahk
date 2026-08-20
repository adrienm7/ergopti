; tests/meta/test_config_boot_read_failure_blocks_persist.ahk

; ==============================================================================
; MODULE: Regression — a transiently unreadable config.toml must never be
;         overwritten with defaults (config-boot-read-failed)
; DESCRIPTION:
; The whole feature configuration could be destroyed by a lock that lasted a few
; hundred milliseconds. Start the driver while config.toml is briefly held by a
; sync client, an AV real-time scan or a backup job, and:
;
;   1. ApplyConfigToml called ReadTomlFile, which caught the sharing violation
;      and returned "";
;   2. `loop parse, ""` applied ZERO overrides, so Features stayed at
;      ManifestBuildFeaturesMap() defaults — and the apply still logged
;      SUCCESS "0 value(s)", indistinguishable from a genuinely fresh config;
;   3. the lock cleared before the -500 ms boot timer fired SaveFullConfig,
;      which re-collected that DEFAULT tree and wrote it out successfully,
;      replacing every one of the user's settings with factory values.
;
; ROOT CAUSE ENCODED: ReadTomlFile collapsed "unreadable" into "empty" and
; exposed no signal to later writers. TOML_BatchWrite's own TOML_ReadFailed
; guard structurally cannot catch this case — it re-parses at WRITE time, and by
; then the lock has cleared, so the write looks safe while the payload it was
; handed is already defaults. The distinction therefore has to be latched at
; READ time and survive until the process restarts.
;
; The three assertions below are the three links of that chain: the sentinel is
; raised, the apply refuses to pretend it succeeded, and the persist declines.
; Breaking any single link re-opens the data loss, so each is asserted
; separately rather than through one end-to-end scenario.
;
; SCOPE: behavioural throughout — the failure is provoked with a real exclusive
; file lock, which is exactly the mechanism the field failure used.
; ==============================================================================

#Requires AutoHotkey v2.0

; Deny every sharing mode so a concurrent FileRead fails with OS error 32, the
; same sharing violation a sync client or an AV scanner produces.
global _CBRF_EXCLUSIVE_LOCK_FLAGS := "r-rwd"





; =======================================================================
; =======================================================================
; ======= 1/ An unreadable existing file raises a sticky sentinel =======
; =======================================================================
; =======================================================================

; ReadTomlFile must keep returning "" (no caller may be made to throw), but it
; has to record that "" meant "could not read" rather than "was empty". The flag
; must be STICKY: the whole point is that the file is readable again by the time
; the write happens, so a flag cleared by the next successful read of ANY path
; would be gone exactly when it is needed.
_CBRF_UnreadableExistingFileIsFlagged() {
	Path := A_Temp . "\ergopti_test_cbrf_locked_" . A_TickCount . ".toml"
	try FileDelete(Path)
	FileAppend("[layout]`nenabled = false`n", Path, "UTF-8")

	Lock := FileOpen(Path, _CBRF_EXCLUSIVE_LOCK_FLAGS)
	Assert(Lock != "" and IsObject(Lock), "the test could not take an exclusive lock — it would otherwise assert nothing")
	Content := ReadTomlFile(Path)
	Flagged := TOML_UnreadableFile(Path)
	Lock.Close()

	Assert(Content == "",
		"ReadTomlFile must stay non-throwing and return empty on a sharing violation")
	Assert(Flagged,
		"an EXISTING file that could not be read must be flagged unreadable — returning an empty string with no signal is what let the caller apply defaults and the next writer persist them over the user's real config")

	; A file that is genuinely absent reads empty too, but that is not a failure:
	; flagging it would block the very first save on a fresh install.
	Missing := A_Temp . "\ergopti_test_cbrf_absent_" . A_TickCount . ".toml"
	try FileDelete(Missing)
	ReadTomlFile(Missing)
	Assert(!TOML_UnreadableFile(Missing),
		"a MISSING file must not be flagged — it legitimately reads as empty, and flagging it would block the first save of a fresh install")

	; Only a successful read of the same path may clear it: that read is the
	; proof that anything derived from the file is now trustworthy again.
	Recovered := ReadTomlFile(Path)
	try FileDelete(Path)
	Assert(InStr(Recovered, "enabled = false") > 0, "the file must read back once unlocked")
	Assert(!TOML_UnreadableFile(Path),
		"a later successful read of the same path must clear the flag, or one transient lock would block every save for the rest of the session")
}





; ====================================================================
; ====================================================================
; ======= 2/ The boot apply refuses to report a silent success =======
; ====================================================================
; ====================================================================

; The destructive step needs TWO things to be true: the tree in memory is
; defaults, and something later serializes it. This asserts the first — the
; apply must neither claim success nor leave the caller unable to tell.
_CBRF_ApplyRefusesUnreadableConfig() {
	global _ConfigBootReadFailed
	Path := A_Temp . "\ergopti_test_cbrf_apply_" . A_TickCount . ".toml"
	try FileDelete(Path)
	; A real override: if the apply ever ran, this key would flip in the fixture.
	FileAppend("[layout]`nenabled = false`n", Path, "UTF-8")

	Fixture := Map("layout", Map("enabled", true))
	PrevFlag := _ConfigBootReadFailed
	_ConfigBootReadFailed := false

	Lock := FileOpen(Path, _CBRF_EXCLUSIVE_LOCK_FLAGS)
	Assert(Lock != "" and IsObject(Lock), "the test could not take an exclusive lock — it would otherwise assert nothing")
	Result := ApplyConfigToml(Fixture, Path)
	Flag := _ConfigBootReadFailed
	Lock.Close()
	try FileDelete(Path)
	_ConfigBootReadFailed := PrevFlag

	Assert(Result == -1,
		"ApplyConfigToml must return a FAILURE signal (-1) for an existing-but-unreadable config — returning 0 is indistinguishable from a config that legitimately carried no overrides")
	Assert(Flag,
		"ApplyConfigToml must latch _ConfigBootReadFailed so the deferred boot save knows the feature tree in memory is defaults rather than the user's settings")
	Assert(Fixture["layout"]["enabled"] == true,
		"nothing may be applied from a file that could not be read")
}

; The success path must keep working unchanged, or the guard would be a
; permanent regression dressed up as a fix.
_CBRF_ApplyStillWorksWhenReadable() {
	global _ConfigBootReadFailed
	Path := A_Temp . "\ergopti_test_cbrf_ok_" . A_TickCount . ".toml"
	try FileDelete(Path)
	FileAppend("[layout]`nenabled = false`n", Path, "UTF-8")

	Fixture := Map("layout", Map("enabled", true))
	PrevFlag := _ConfigBootReadFailed
	_ConfigBootReadFailed := false
	Result := ApplyConfigToml(Fixture, Path)
	Flag := _ConfigBootReadFailed
	_ConfigBootReadFailed := PrevFlag
	try FileDelete(Path)

	Assert(Result >= 1, "a readable config must still apply its overrides")
	Assert(Fixture["layout"]["enabled"] == false, "the override must reach the Features tree")
	Assert(!Flag, "a readable config must not latch the failure flag")
}





; ================================================================
; ================================================================
; ======= 3/ The persist declines while the flag is raised =======
; ================================================================
; ================================================================

; The last link: even with the file readable again and the driver fully ready,
; SaveFullConfig must refuse, because what it would serialize is the default
; tree that step 2 proved was never overridden.
; The last link: even with the file readable again and the driver fully ready,
; SaveFullConfig must refuse, because what it would serialize is the default
; tree that step 2 proved was never overridden.
;
; The unguarded write is deliberately NOT driven here as a control: a completed
; SaveFullConfig pulls in the whole tray/menu/metrics surface and blocks the
; headless runner on a dialog. The false-green risk that control would have
; covered ("it bailed for some unrelated reason") is closed instead by asserting
; the refusal's own distinct return value — the only other early exit,
; !_DriverReady, returns nothing — and by the positional assertion below.
_CBRF_SaveDeclinesWhileFlagged() {
	global _ConfigBootReadFailed, ConfigurationFile, _DriverReady
	Target := A_Temp . "\ergopti_test_cbrf_save_" . A_TickCount . ".toml"
	try FileDelete(Target)
	; Content that is unmistakably the user's, so any rewrite is visible.
	FileAppend("[layout]`nenabled = false`n", Target, "UTF-8")
	Before := FileRead(Target, "UTF-8")

	PrevFile  := IsSet(ConfigurationFile) ? ConfigurationFile : ""
	PrevReady := IsSet(_DriverReady) ? _DriverReady : false
	PrevFlag  := IsSet(_ConfigBootReadFailed) ? _ConfigBootReadFailed : false

	ConfigurationFile     := Target
	_DriverReady          := true
	_ConfigBootReadFailed := true
	Threw   := ""
	Refused := ""
	try Refused := SaveFullConfig()
	catch as e
		Threw := e.Message

	ConfigurationFile     := PrevFile
	_DriverReady          := PrevReady
	_ConfigBootReadFailed := PrevFlag

	After := FileRead(Target, "UTF-8")
	try FileDelete(Target)

	Assert(Threw == "",
		"SaveFullConfig must DECLINE cleanly, not throw: it runs from a boot timer where an exception is invisible. Got: " . Threw)
	Assert(Refused == false,
		"SaveFullConfig must return false when it refuses, so the refusal is distinguishable from the !_DriverReady deferral (which returns nothing) and from a save that ran")
	Assert(After == Before,
		"SaveFullConfig must not rewrite config.toml while _ConfigBootReadFailed is set — the tree it would serialize is manifest defaults, and writing it destroys every setting the user had")
}

; Positional guard: the refusal is only worth anything if it happens BEFORE the
; file is replaced. A guard that drifts below the write (or below the Updates
; collection that feeds it) still returns false and still passes the assertions
; above while the config is already gone.
_CBRF_GuardPrecedesTheWrite() {
	Body := _DriverFuncBody("SaveFullConfig")
	Assert(Body != "", "SaveFullConfig() must exist in the driver source")

	GuardPos := InStr(Body, "_ConfigBootReadFailed")
	WritePos := InStr(Body, "TOML_BatchWrite")
	Assert(GuardPos > 0,
		"SaveFullConfig must consult _ConfigBootReadFailed — without it a boot that could not read config.toml persists manifest defaults over the user's settings")
	Assert(WritePos > 0, "SaveFullConfig must still reach TOML_BatchWrite on the nominal path")
	Assert(GuardPos < WritePos,
		"the _ConfigBootReadFailed guard must come BEFORE TOML_BatchWrite — after it, the user's config has already been replaced")
}


Test("meta config-boot-read-failed: an unreadable existing TOML raises a sticky sentinel",
	_CBRF_UnreadableExistingFileIsFlagged)
Test("meta config-boot-read-failed: the boot apply refuses an unreadable config",
	_CBRF_ApplyRefusesUnreadableConfig)
Test("meta config-boot-read-failed: a readable config still applies",
	_CBRF_ApplyStillWorksWhenReadable)
Test("meta config-boot-read-failed: the persist declines while the sentinel is raised",
	_CBRF_SaveDeclinesWhileFlagged)
Test("meta config-boot-read-failed: the persist guard precedes the write",
	_CBRF_GuardPrecedesTheWrite)
