; modules/updater/release_install.ahk

; ==============================================================================
; MODULE: Updater / Release Install From the Versions Window
; DESCRIPTION:
; The Windows port of _shared/lua/updater/release_install.lua: the one-click
; install of a release chosen in the Versions window (install_release), in the
; same order as on macOS and Linux. Back the configuration up
; (modules/updater/config_backup.ahk), find the release's authenticated asset,
; then hand the release to the update path itself (Updater_DownloadAndInstall:
; the isolated download, the SHA-256 check against GitHub's digest, the swap
; worker and the restart). Each phase reaches the page; a refusal or a failure
; ends the install visibly and keeps the backup.
;
; FEATURES & RATIONALE:
; 1. Only a click starts it: ReleaseInstall_Start is called by the Versions
;    window's bridge handler and by nothing in the update schedule.
; 2. Backup first: nothing is downloaded before the backup is complete, and a
;    failed backup refuses the install.
; 3. No check is skipped: the update path's own asset authentication, digest
;    and swap run unchanged; this module only observes them
;    (_UpdaterInstallObserver) so the window shows their phases and failures.
; 4. One install at a time: a request while one runs, or while the updater's
;    own transaction runs, is refused as busy.
; ==============================================================================

; The page reason key of every way the install can stop.
global RELEASE_INSTALL_REASONS := Map(
	"busy",            "changelog_window.install_error_busy",
	"unexpected",      "changelog_window.install_error_unexpected",
	"backup",          "changelog_window.install_error_backup",
	"no_asset",        "changelog_window.install_error_no_asset",
	"download",        "changelog_window.install_error_download",
	"verify",          "changelog_window.install_error_verify",
	"install",         "changelog_window.install_error_install",
	"unknown_release", "changelog_window.install_error_unknown_release",
	"no_details",      "changelog_window.install_error_no_details")

; The tag of the release being installed from the Versions window, or "".
global _ReleaseInstallTag := ""





; ===============================
; ===============================
; ======= 1/ The Sequence =======
; ===============================
; ===============================

; Installs one release the user clicked in the Versions window.
; @param Tag {String} Release tag posted by the page.
; @param Channel {String} Registry channel the page listed it on (logged).
; @param Deps {Map} The ports, production or test:
;   "busy"    () -> Boolean: the updater's own transaction or recovery runs.
;   "blocked" () -> String: locale key of why this build cannot install, or "".
;   "find"    (Tag) -> Map("release", Release) or Map("reason", key).
;   "backup"  (Release) -> Map record (its "path" is shown); throws on failure.
;   "asset"   (Release) -> Object, or 0 when the release has none for Windows.
;   "install" (Release, Observer) -> Boolean: the update path started.
;   "report"  (Map) -> sends { tag, phase, reason_key?, backup_path? } to the page.
; @returns {Boolean} True when the backup is made and the update path started.
ReleaseInstall_Start(Tag, Channel, Deps) {
	global _ReleaseInstallTag, RELEASE_INSTALL_REASONS
	if !(Tag is String) || Tag == "" {
		try LoggerError("ReleaseInstall", "Refused an install request without a release tag.")
		return false
	}
	if (_ReleaseInstallTag != "" || Deps["busy"].Call()) {
		try LoggerWarn("ReleaseInstall", "Refused to install {1}: another install or update is running.", Tag)
		_ReleaseInstall_Report(Deps, Map("tag", Tag, "phase", "failed", "reason_key", RELEASE_INSTALL_REASONS["busy"]))
		return false
	}
	Blocked := Deps["blocked"].Call()
	if (Blocked != "") {
		; The page greys its buttons for this reason; a request anyway is a stale page.
		try LoggerError("ReleaseInstall", "Refused to install {1}: this build cannot install a release ({2}).", Tag, Blocked)
		_ReleaseInstall_Report(Deps, Map("tag", Tag, "phase", "failed", "reason_key", RELEASE_INSTALL_REASONS["unexpected"]))
		return false
	}
	Found := Deps["find"].Call(Tag)
	if !(Found is Map) || !Found.Has("release") {
		Reason := (Found is Map && Found.Has("reason")) ? Found["reason"] : RELEASE_INSTALL_REASONS["unknown_release"]
		try LoggerError("ReleaseInstall", "Refused to install {1}: it is not in the release list the window loaded.", Tag)
		_ReleaseInstall_Report(Deps, Map("tag", Tag, "phase", "failed", "reason_key", Reason))
		return false
	}
	Release := Found["release"]
	_ReleaseInstallTag := Tag
	try LoggerStart("ReleaseInstall", "Installing {1} from the Versions window (channel {2})…", Tag, Channel)
	_ReleaseInstall_Report(Deps, Map("tag", Tag, "phase", "backing_up"))
	try Backup := Deps["backup"].Call(Release)
	catch as Err {
		try LoggerError("ReleaseInstall", "Install of {1} refused: the configuration backup failed ({2}).", Tag, Err.Message)
		return _ReleaseInstall_Fail(Deps, Tag, "backup", "")
	}
	BackupPath := (Backup is Map && Backup.Has("path")) ? Backup["path"] : ""
	Asset := Deps["asset"].Call(Release)
	if !IsObject(Asset) {
		try LoggerError("ReleaseInstall", "Install of {1} refused: the release has no asset for Windows.", Tag)
		return _ReleaseInstall_Fail(Deps, Tag, "no_asset", BackupPath)
	}
	_ReleaseInstall_Report(Deps, Map("tag", Tag, "phase", "downloading", "backup_path", BackupPath))
	Observer := _ReleaseInstall_OnPhase.Bind(Deps, Tag, BackupPath)
	Started := false
	try Started := Deps["install"].Call(Release, Observer) == true
	catch as Err
		try LoggerError("ReleaseInstall", "The update path raised for {1}: {2}.", Tag, Err.Message)
	if Started
		return true
	; The update path may already have reported why through the observer.
	if (_ReleaseInstallTag == Tag)
		_ReleaseInstall_Fail(Deps, Tag, "download", BackupPath)
	return false
}

; Whether an install from the Versions window runs.
; @returns {Boolean}
ReleaseInstall_Busy() {
	global _ReleaseInstallTag
	return _ReleaseInstallTag != ""
}

; The update path's phases of the install this window asked for.
_ReleaseInstall_OnPhase(Deps, Tag, BackupPath, Phase, ReasonKey := "") {
	global _ReleaseInstallTag, RELEASE_INSTALL_REASONS
	if (_ReleaseInstallTag != Tag)
		return
	if (Phase == "failed") {
		Known := false
		for _, Key in RELEASE_INSTALL_REASONS {
			if (Key == ReasonKey)
				Known := true
		}
		_ReleaseInstallTag := ""
		try LoggerError("ReleaseInstall", "Install of {1} stopped: {2}.", Tag,
			Known ? ReasonKey : RELEASE_INSTALL_REASONS["unexpected"])
		_ReleaseInstall_Report(Deps, Map("tag", Tag, "phase", "failed", "backup_path", BackupPath,
			"reason_key", Known ? ReasonKey : RELEASE_INSTALL_REASONS["unexpected"]))
		return
	}
	; The swap worker has been acknowledged, not completed: the resident process
	; cannot observe installation after it exits. Close only this owner's handoff.
	if (Phase == "restarting")
		try LoggerSuccess("ReleaseInstall", "Verified release {1} handed to the swap and restart worker.", Tag)
	if (Phase == "installing" || Phase == "restarting")
		_ReleaseInstall_Report(Deps, Map("tag", Tag, "phase", Phase, "backup_path", BackupPath))
}

_ReleaseInstall_Fail(Deps, Tag, Reason, BackupPath) {
	global _ReleaseInstallTag, RELEASE_INSTALL_REASONS
	_ReleaseInstallTag := ""
	try LoggerError("ReleaseInstall", "Install of {1} stopped: {2}.", Tag, RELEASE_INSTALL_REASONS[Reason])
	Message := Map("tag", Tag, "phase", "failed", "reason_key", RELEASE_INSTALL_REASONS[Reason])
	if (BackupPath != "")
		Message["backup_path"] := BackupPath
	_ReleaseInstall_Report(Deps, Message)
	return false
}

; Sends one phase to the page; a page failure never unwinds the install.
_ReleaseInstall_Report(Deps, Message) {
	try Deps["report"].Call(Message)
	catch as Err
		try LoggerError("ReleaseInstall", "The Versions page could not be told the install phase: {1}.", Err.Message)
}





; ===================================
; ===================================
; ======= 2/ The Page Message =======
; ===================================
; ===================================

; Encodes one install or restore phase as the JSON object the page reads.
; @param Message {Map} String values only.
; @returns {String}
ReleaseInstall_MessageJson(Message) {
	Text := "{"
	Index := 0
	for Key, Value in Message {
		Index += 1
		Text .= (Index > 1 ? "," : "") . JsonStringLiteral(Key) . ":" . JsonStringLiteral(Value . "")
	}
	return Text . "}"
}
