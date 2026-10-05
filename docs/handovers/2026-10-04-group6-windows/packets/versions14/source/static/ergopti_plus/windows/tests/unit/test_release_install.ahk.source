; static/ergopti_plus/windows/tests/unit/test_release_install.ahk

; ==============================================================================
; MODULE: Versions Window Release Install Tests
; DESCRIPTION:
; The Versions window listed releases with « View on GitHub » and nothing
; else. Its « Install this version » button now runs ReleaseInstall_Start
; (modules/updater/release_install.ahk): the configuration backup first
; (modules/updater/config_backup.ahk), then the update path. These cases drive
; the sequence with recording ports (nothing is downloaded or installed), the
; backup owner on a real temporary folder, the update path's observer routing,
; and the guard that the background check never installs.
; ==============================================================================

global _RIT_Events := []
global _RIT_Reports := []

; Recording ports whose outcomes each case sets.
; Opts: busy, blocked, found (false), reason, backup_fails, asset (false),
; install ("ok", "fail", "observer_fail"), phases (Array sent to the observer).
_RIT_Deps(Opts := 0) {
	global _RIT_Events, _RIT_Reports
	if !IsObject(Opts)
		Opts := Map()
	_RIT_Events := []
	_RIT_Reports := []
	return Map(
		"busy", () => Opts.Get("busy", false),
		"blocked", () => Opts.Get("blocked", ""),
		"find", (Tag) => _RIT_Find(Opts, Tag),
		"backup", (Release) => _RIT_Backup(Opts, Release),
		"asset", (Release) => _RIT_Asset(Opts, Release),
		"install", (Release, Observer) => _RIT_Install(Opts, Release, Observer),
		"report", (Message) => _RIT_Reports.Push(Message))
}

_RIT_Find(Opts, Tag) {
	global _RIT_Events
	_RIT_Events.Push("find")
	if !Opts.Get("found", true)
		return Map("reason", Opts.Get("reason", "changelog_window.install_error_unknown_release"))
	return Map("release", {Tag: Tag, RawJson: "{}"})
}

_RIT_Backup(Opts, Release) {
	global _RIT_Events
	_RIT_Events.Push("backup")
	if Opts.Get("backup_fails", false)
		throw Error("disk full")
	return Map("path", "C:\cfg\backups\pre-install-x")
}

_RIT_Asset(Opts, Release) {
	global _RIT_Events
	_RIT_Events.Push("asset")
	return Opts.Get("asset", true) ? {Url: "u", Digest: "d"} : 0
}

_RIT_Install(Opts, Release, Observer) {
	global _RIT_Events
	_RIT_Events.Push("install")
	for _, Phase in Opts.Get("phases", [])
		Observer.Call(Phase)
	Mode := Opts.Get("install", "ok")
	if (Mode == "observer_fail") {
		Observer.Call("failed", "changelog_window.install_error_verify")
		return false
	}
	return Mode == "ok"
}

_RIT_Joined(List) {
	Text := ""
	for Index, Item in List
		Text .= (Index > 1 ? "," : "") . Item
	return Text
}

_RIT_Phases() {
	global _RIT_Reports
	Phases := []
	for _, Message in _RIT_Reports
		Phases.Push(Message["phase"])
	return _RIT_Joined(Phases)
}

_RIT_Last() {
	global _RIT_Reports
	return _RIT_Reports[_RIT_Reports.Length]
}

_RIT_Reset() {
	global _ReleaseInstallTag, _UpdaterInstallObserver
	_ReleaseInstallTag := ""
	_UpdaterInstallObserver := 0
}





; ===============================
; ===============================
; ======= 1/ The sequence =======
; ===============================
; ===============================

_RIT_BacksUpFirstThenInstalls() {
	_RIT_Reset()
	Deps := _RIT_Deps(Map("phases", ["installing", "restarting"]))
	AssertTrue(ReleaseInstall_Start("v0.0.0-dev.139", "dev", Deps))
	AssertEqual("find,backup,asset,install", _RIT_Joined(_RIT_Events), "the backup precedes the update path")
	AssertEqual("backing_up,downloading,installing,restarting", _RIT_Phases())
	AssertEqual("C:\cfg\backups\pre-install-x", _RIT_Last()["backup_path"])
	_RIT_Reset()
}
Test("Release install: the click backs up first, then runs the update path (release-install-order)",
	_RIT_BacksUpFirstThenInstalls)

_RIT_RefusesMissingAsset() {
	_RIT_Reset()
	AssertFalse(ReleaseInstall_Start("v0.0.0-dev.139", "dev", _RIT_Deps(Map("asset", false))))
	AssertEqual("find,backup,asset", _RIT_Joined(_RIT_Events), "no install without the Windows asset")
	AssertEqual("failed", _RIT_Last()["phase"])
	AssertEqual("changelog_window.install_error_no_asset", _RIT_Last()["reason_key"])
	AssertEqual("C:\cfg\backups\pre-install-x", _RIT_Last()["backup_path"], "the backup is kept and named")
	AssertFalse(ReleaseInstall_Busy(), "a refusal frees Retry")
}
Test("Release install: a release without the Windows asset is refused after the backup (release-install-no-asset)",
	_RIT_RefusesMissingAsset)

_RIT_VerificationFailureReportedOnce() {
	_RIT_Reset()
	AssertFalse(ReleaseInstall_Start("v0.0.0-dev.139", "dev", _RIT_Deps(Map("install", "observer_fail"))))
	Failures := 0
	for _, Message in _RIT_Reports
		Failures += (Message["phase"] == "failed")
	AssertEqual(1, Failures, "the update path's failure is reported once")
	AssertEqual("changelog_window.install_error_verify", _RIT_Last()["reason_key"])
	AssertEqual("C:\cfg\backups\pre-install-x", _RIT_Last()["backup_path"])
	AssertFalse(ReleaseInstall_Busy())
}
Test("Release install: a failed verification of the update path is shown once (release-install-verify)",
	_RIT_VerificationFailureReportedOnce)

_RIT_BackupFailureDownloadsNothing() {
	_RIT_Reset()
	AssertFalse(ReleaseInstall_Start("v1.0.0", "main", _RIT_Deps(Map("backup_fails", true))))
	AssertEqual("find,backup", _RIT_Joined(_RIT_Events))
	AssertEqual("changelog_window.install_error_backup", _RIT_Last()["reason_key"])
}
Test("Release install: nothing is downloaded when the backup fails (release-install-backup-first)",
	_RIT_BackupFailureDownloadsNothing)

_RIT_RefusalsBeforeBackup() {
	global _ReleaseInstallTag
	_RIT_Reset()
	AssertFalse(ReleaseInstall_Start("v1.0.0", "main", _RIT_Deps(Map("busy", true))))
	AssertEqual("", _RIT_Joined(_RIT_Events), "busy: nothing runs")
	AssertEqual("changelog_window.install_error_busy", _RIT_Last()["reason_key"])
	AssertFalse(ReleaseInstall_Start("v1.0.0", "main", _RIT_Deps(Map("blocked", "changelog_window.install_blocked_source"))))
	AssertEqual("", _RIT_Joined(_RIT_Events), "a source run: nothing runs")
	AssertFalse(ReleaseInstall_Start("v1.0.0", "main", _RIT_Deps(Map("found", false,
		"reason", "changelog_window.install_error_no_details"))))
	AssertEqual("find", _RIT_Joined(_RIT_Events), "an unknown release: no backup")
	AssertEqual("changelog_window.install_error_no_details", _RIT_Last()["reason_key"])
	_ReleaseInstallTag := "v0.9.0"
	AssertFalse(ReleaseInstall_Start("v1.0.0", "main", _RIT_Deps()))
	AssertEqual("changelog_window.install_error_busy", _RIT_Last()["reason_key"], "one install at a time")
	_RIT_Reset()
}
Test("Release install: busy, blocked and unknown releases are refused before any backup (release-install-refusals)",
	_RIT_RefusalsBeforeBackup)

_RIT_FailuresReachTheObserver() {
	global _UpdaterInstallObserver
	Seen := []
	_UpdaterInstallObserver := (Phase, Reason := "") => Seen.Push(Phase . ":" . Reason)
	_Updater_ReportInstallFailure("updater.install_error_download", "changelog_window.install_error_verify")
	AssertEqual("failed:changelog_window.install_error_verify", _RIT_Joined(Seen),
		"a window following the install gets the failure instead of a modal box")
	AssertEqual(0, _UpdaterInstallObserver, "a failure ends the following")
	AssertFalse(_Updater_NotifyInstallPhase("installing"), "nobody follows once it failed")
	AssertTrue(_Updater_StagingFailureIsVerification("ERR:SHA-256 digest mismatch"))
	AssertTrue(_Updater_StagingFailureIsVerification("ERR:Downloaded file is too small"))
	AssertFalse(_Updater_StagingFailureIsVerification("ERR:HTTP 404"))
}
Test("Release install: the update path's failures reach the Versions window (release-install-observer)",
	_RIT_FailuresReachTheObserver)

; Capture the real central logger without replacing its state or file sinks.
_RIT_WithLifecycleLogs(Body) {
	global _LOGGER_TEST_SINK
	SavedSink := _LOGGER_TEST_SINK
	Lines := []
	LoggerSetTestSink((Line) => Lines.Push(Line))
	_RIT_Reset()
	try Body.Call(Lines)
	finally {
		_RIT_Reset()
		LoggerSetTestSink(SavedSink)
	}
}

_RIT_LogKinds(Lines) {
	Kinds := []
	for _, Line in Lines {
		if RegExMatch(Line, "\[(START|SUCCESS|ERROR|WARNING)\] \[ReleaseInstall\]", &Match)
			Kinds.Push(Match[1])
	}
	return _RIT_Joined(Kinds)
}

_RIT_LogClosesAtAcknowledgedHandoff(Lines) {
	Tag := "v-lifecycle-handoff"
	Deps := _RIT_Deps()
	AssertTrue(ReleaseInstall_Start(Tag, "dev", Deps))
	AssertEqual("START", _RIT_LogKinds(Lines), "starting the download is not a completed handoff")
	_ReleaseInstall_OnPhase(Deps, Tag, "backup", "installing")
	AssertEqual("START", _RIT_LogKinds(Lines), "an unacknowledged swap is not a completed handoff")
	_ReleaseInstall_OnPhase(Deps, Tag, "backup", "restarting")
	AssertEqual("START,SUCCESS", _RIT_LogKinds(Lines), "the acknowledged restart closes the lifecycle")
}
Test("Release install: lifecycle succeeds only at acknowledged worker handoff",
	_RIT_WithLifecycleLogs.Bind(_RIT_LogClosesAtAcknowledgedHandoff))

_RIT_LogRefusalIsTerminal(Lines) {
	AssertFalse(ReleaseInstall_Start("v-lifecycle-refusal", "dev", _RIT_Deps(Map("install", "fail"))))
	AssertEqual("START,ERROR", _RIT_LogKinds(Lines), "a refused download closes with failure, never success")
	AssertFalse(ReleaseInstall_Busy(), "failure frees the next request")
}
Test("Release install: download refusal logs a failure terminal",
	_RIT_WithLifecycleLogs.Bind(_RIT_LogRefusalIsTerminal))

_RIT_LogObserverFailureIsTerminal(Lines) {
	AssertFalse(ReleaseInstall_Start("v-lifecycle-verification", "dev",
		_RIT_Deps(Map("install", "observer_fail"))))
	AssertEqual("START,ERROR", _RIT_LogKinds(Lines), "the observer's refusal logs one failure terminal")
	AssertFalse(ReleaseInstall_Busy(), "observer failure frees the next request")
}
Test("Release install: observer failure logs one failure terminal",
	_RIT_WithLifecycleLogs.Bind(_RIT_LogObserverFailureIsTerminal))





; ===================================
; ===================================
; ======= 2/ The backup owner =======
; ===================================
; ===================================

_RIT_WriteFile(Path, Text) {
	SplitPath(Path, , &Dir)
	DirCreate(Dir)
	FileAppend(Text, Path, "UTF-8-RAW")
}

_RIT_BackupAndRestoreRealFiles() {
	Root := A_Temp . "\ergopti_rit_" . A_TickCount
	Cfg := Root . "\cfg"
	try {
		_RIT_WriteFile(Cfg . "\config.toml", "[script]`n")
		_RIT_WriteFile(Cfg . "\hotstrings\personal_hotstrings.toml", "btw = 1`n")
		_RIT_WriteFile(Cfg . "\metrics\metrics.toml", "never copied")
		_RIT_WriteFile(Cfg . "\db.sqlite", "binary")
		Rules := ConfigBackup_Rules()
		Clock := () => Map("stamp", "20260930-101500", "iso", "2026-09-30T10:15:00Z")
		Record := ConfigBackup_Create(Cfg, "pre_install", "v0.0.0-dev.139", "0.0.0-dev.140", Rules, Clock)
		AssertEqual("pre-install-20260930-101500-v0.0.0-dev.139", Record["id"])
		AssertEqual("config.toml,hotstrings/personal_hotstrings.toml", _RIT_Joined(Record["files"]))
		AssertTrue(FileExist(Record["path"] . "\backup.json") != "", "the manifest completes the backup")
		AssertEqual("", FileExist(Record["path"] . "\config\metrics\metrics.toml"), "metrics are not configuration")
		Latest := ConfigBackup_Latest(Cfg, "pre_install", Rules)
		AssertEqual(Record["id"], Latest["id"])

		FileDelete(Cfg . "\config.toml")
		_RIT_WriteFile(Cfg . "\config.toml", "[changed]`n")
		Later := () => Map("stamp", "20260930-111500", "iso", "2026-09-30T11:15:00Z")
		Result := ConfigBackup_Restore(Cfg, Record["id"], Rules, Later)
		AssertTrue(Result["ok"], "the restore commits")
		AssertEqual("[script]`n", FileRead(Cfg . "\config.toml", "UTF-8"))
		AssertEqual("[changed]`n", FileRead(Result["pre"]["path"] . "\config\config.toml", "UTF-8"),
			"the replaced configuration is backed up first")

		FileDelete(Record["path"] . "\config\hotstrings\personal_hotstrings.toml")
		Missing := ConfigBackup_Restore(Cfg, Record["id"], Rules, Later)
		AssertFalse(Missing["ok"])
		AssertEqual("missing", Missing["reason"])
		AssertFalse(ConfigBackup_Restore(Cfg, "..\x", Rules, Later)["ok"], "an id leaving the folder is refused")
	} finally {
		try DirDelete(Root, true)
	}
}
Test("Config backup: backs up and restores the configuration's exact bytes (config-backup-real-files)",
	_RIT_BackupAndRestoreRealFiles)

_RIT_ManifestPathsStayInside() {
	AssertTrue(ConfigBackup_IsContained("hotstrings/personal_hotstrings.toml"))
	for _, Bad in ["", "/etc/passwd", "..\x", "a/../b", "a//b", "C:/x", "a\b", "./a"]
		AssertFalse(ConfigBackup_IsContained(Bad), "refused: " . Bad)
}
Test("Config backup: a manifest path never leaves the configuration folder (config-backup-contained)",
	_RIT_ManifestPathsStayInside)





; ========================================
; ========================================
; ======= 3/ Never without a click =======
; ========================================
; ========================================

_RIT_BackgroundCheckNeverInstalls() {
	Body := _DriverFuncBody("_Updater_HandleBackgroundResult")
	Assert(Body != "", "_Updater_HandleBackgroundResult must exist")
	for _, Forbidden in ["Updater_DownloadAndInstall(", "_Updater_ActivateCachedRelease(",
			"_Updater_StartStagingWorker(", "ReleaseInstall_Start("]
		AssertEqual(0, InStr(Body, Forbidden), "the background check only announces: " . Forbidden)
	Tick := _DriverFuncBody("Updater_BackgroundTick")
	Assert(Tick != "", "Updater_BackgroundTick must exist")
	AssertEqual(0, InStr(Tick, "Updater_DownloadAndInstall("), "the schedule never installs")
}
Test("Updater: the background check announces a release and never installs it (update-notify-only)",
	_RIT_BackgroundCheckNeverInstalls)


; A same-tag retry must not let the previous transaction's observer publish.
_RIT_SameTagObserverHasExactOperation() {
	global _RIT_Reports
	_RIT_Reset()
	Observers := []
	Deps := _RIT_Deps()
	Deps["install"] := (Release, Observer) => (Observers.Push(Observer), true)
	AssertTrue(ReleaseInstall_Start("v-owner", "dev", Deps))
	Observers[1].Call("failed", "changelog_window.install_error_download")
	AssertTrue(ReleaseInstall_Start("v-owner", "dev", Deps))
	Count := _RIT_Reports.Length
	Observers[1].Call("installing")
	Observers[1].Call("failed", "changelog_window.install_error_verify")
	AssertEqual(Count, _RIT_Reports.Length, "retired same-tag observer cannot publish or retire the new transaction")
	AssertTrue(ReleaseInstall_Busy(), "the newer exact transaction still owns the install")
	Observers[2].Call("installing")
	AssertEqual(Count + 1, _RIT_Reports.Length, "the exact current observer can publish")
	_RIT_Reset()
}
Test("Release install: same-tag retry fences the previous exact observer", _RIT_SameTagObserverHasExactOperation)

_RIT_PublicFailureJsonNeverSerializesNativeReceipt() {
	Receipt := Map("url", "https://credential@private", "stderr", "secret", "path", "C:\secret")
	Report := Map("cause", "proxy", "message_key", "network.failure.proxy", "evidence", "proxy_connect_authentication",
		"actions", [Map("id", "retry", "label_key", "network.action.retry")], "receipt", Receipt)
	Message := Map("tag", "v1.2.3", "phase", "failed", "backup_path", "C:\cfg\backup", "operation", 31,
		"failure_epoch", 44, "failure_report", Report, "receipt", Receipt, "owner", Map("secret", "credential"))
	Encoded := ReleaseInstall_MessageJson(Message)
	Decoded := JsonParse(Encoded)
	AssertEqual(31, Decoded["operation"])
	AssertEqual(44, Decoded["failure_epoch"])
	AssertEqual("proxy", Decoded["failure_report"]["cause"])
	AssertEqual("retry", Decoded["failure_report"]["actions"][1]["id"])
	AssertFalse(Decoded.Has("receipt"))
	AssertFalse(Decoded.Has("owner"))
	AssertFalse(Decoded["failure_report"].Has("receipt"))
	AssertEqual(0, InStr(Encoded, "credential"))
	AssertEqual(0, InStr(Encoded, "secret"))
	AssertEqual("C:\cfg\backup", Decoded["backup_path"], "the original user-visible backup is preserved")
}
Test("Release install: page JSON contains only canonical safe failure fields", _RIT_PublicFailureJsonNeverSerializesNativeReceipt)
