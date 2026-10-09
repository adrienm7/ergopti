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
global _ReleaseInstallCurrent := 0
global _ReleaseInstallTerminal := 0
global _ReleaseInstallOperation := 0
global _ReleaseInstallFailureEpoch := 0





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
	global _ReleaseInstallCurrent, _ReleaseInstallTerminal, _ReleaseInstallOperation
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
	_ReleaseInstallTerminal := 0
	_ReleaseInstallOperation += 1
	Current := Map("id", _ReleaseInstallOperation, "tag", Tag, "channel", Channel, "deps", Deps,
		"native_owner", Deps.Has("failure_owner") ? Deps["failure_owner"].Call() : 0,
		"release", {RawJson: Release.RawJson, Tag: Release.Tag})
	_ReleaseInstallCurrent := Current
	_ReleaseInstallTag := Tag
	try LoggerStart("ReleaseInstall", "Installing {1} from the Versions window (channel {2})…", Tag, Channel)
	_ReleaseInstall_Report(Deps, Map("tag", Tag, "phase", "backing_up"))
	try Backup := Deps["backup"].Call(Release)
	catch as Err {
		try LoggerError("ReleaseInstall", "Install of {1} refused: the configuration backup failed ({2}).", Tag, Err.Message)
		return _ReleaseInstall_Fail(Deps, Tag, "backup", "", Current)
	}
	BackupPath := (Backup is Map && Backup.Has("path")) ? Backup["path"] : ""
	Current["backup_path"] := BackupPath
	Asset := Deps["asset"].Call(Release)
	if !IsObject(Asset) {
		try LoggerError("ReleaseInstall", "Install of {1} refused: the release has no asset for Windows.", Tag)
		return _ReleaseInstall_Fail(Deps, Tag, "no_asset", BackupPath, Current)
	}
	_ReleaseInstall_Report(Deps, Map("tag", Tag, "phase", "downloading", "backup_path", BackupPath))
	Observer := (Phase, ReasonKey := "", FailureReceipt := 0) =>
		_ReleaseInstall_OnPhase(Deps, Tag, BackupPath, Phase, ReasonKey, FailureReceipt, Current)
	Started := false
	try Started := Deps["install"].Call(Release, Observer) == true
	catch as Err
		try LoggerError("ReleaseInstall", "The update path raised for {1}: {2}.", Tag, Err.Message)
	if Started
		return true
	; The update path may already have reported why through the observer.
	if (_ReleaseInstallTag == Tag && ObjPtr(_ReleaseInstallCurrent) == ObjPtr(Current))
		_ReleaseInstall_Fail(Deps, Tag, "download", BackupPath, Current)
	return false
}

; Whether an install from the Versions window runs.
; @returns {Boolean}
ReleaseInstall_Busy() {
	global _ReleaseInstallTag
	return _ReleaseInstallTag != ""
}

; The update path's phases of the install this window asked for.
; Pure transaction identity: no tag-only admission after a callback can reenter.
_ReleaseInstall_OwnerCurrent(Current, Tag) {
	global _ReleaseInstallCurrent, _ReleaseInstallOperation, _ReleaseInstallTag
	return Current is Map && _ReleaseInstallCurrent == Current
		&& Current.Get("id", 0) == _ReleaseInstallOperation && StrCompare(_ReleaseInstallTag, Tag, true) == 0
}

_ReleaseInstall_OnPhase(Deps, Tag, BackupPath, Phase, ReasonKey := "", FailureReceipt := 0, Expected := 0) {
	global _ReleaseInstallTag, RELEASE_INSTALL_REASONS, _ReleaseInstallCurrent
	Current := IsObject(Expected) ? Expected : _ReleaseInstallCurrent
	if !_ReleaseInstall_OwnerCurrent(Current, Tag)
		return false
	if Phase == "failed" {
		StageOwner := Deps.Has("failure_stage_owner") ? Deps["failure_stage_owner"].Call(Current["release"]) : 0
		if !_ReleaseInstall_OwnerCurrent(Current, Tag)
			return false
		Known := false
		for _, Key in RELEASE_INSTALL_REASONS
			if StrCompare(Key, ReasonKey, true) == 0
				Known := true
		PreviousCritical := Critical("On")
		try {
			if !_ReleaseInstall_OwnerCurrent(Current, Tag)
				return false
			_ReleaseInstallTag := ""
		} finally Critical(PreviousCritical)
		try LoggerError("ReleaseInstall", "Install of {1} stopped: {2}.", Tag,
			Known ? ReasonKey : RELEASE_INSTALL_REASONS["unexpected"])
		if !_ReleaseInstall_OwnerCurrent(Current, "")
			return false
		Message := Map("tag", Tag, "phase", "failed", "backup_path", BackupPath,
			"reason_key", Known ? ReasonKey : RELEASE_INSTALL_REASONS["unexpected"])
		if !_ReleaseInstall_ManagedFailure(Current, Message, FailureReceipt, StageOwner)
			|| !_ReleaseInstall_OwnerCurrent(Current, "")
			return false
		_ReleaseInstall_Report(Deps, Message)
		return true
	}
	if Phase == "restarting"
		try LoggerSuccess("ReleaseInstall", "Verified release {1} handed to the swap and restart worker.", Tag)
	if !_ReleaseInstall_OwnerCurrent(Current, Tag)
		return false
	if Phase == "installing" || Phase == "restarting"
		_ReleaseInstall_Report(Deps, Map("tag", Tag, "phase", Phase, "backup_path", BackupPath))
	return true
}

_ReleaseInstall_Fail(Deps, Tag, Reason, BackupPath, Expected := 0) {
	global _ReleaseInstallTag, RELEASE_INSTALL_REASONS, _ReleaseInstallCurrent
	Current := IsObject(Expected) ? Expected : _ReleaseInstallCurrent
	if !_ReleaseInstall_OwnerCurrent(Current, Tag)
		return false
	PreviousCritical := Critical("On")
	try {
		if !_ReleaseInstall_OwnerCurrent(Current, Tag)
			return false
		_ReleaseInstallTag := ""
	} finally Critical(PreviousCritical)
	try LoggerError("ReleaseInstall", "Install of {1} stopped: {2}.", Tag, RELEASE_INSTALL_REASONS[Reason])
	if !_ReleaseInstall_OwnerCurrent(Current, "")
		return false
	Message := Map("tag", Tag, "phase", "failed", "reason_key", RELEASE_INSTALL_REASONS[Reason])
	if BackupPath != ""
		Message["backup_path"] := BackupPath
	if !_ReleaseInstall_ManagedFailure(Current, Message, 0) || !_ReleaseInstall_OwnerCurrent(Current, "")
		return false
	_ReleaseInstall_Report(Deps, Message)
	return false
}

; Retain only the captured transaction/terminal epoch across capability probes.
_ReleaseInstall_ManagedFailure(Current, Message, Receipt, StageOwner := 0) {
	global _ReleaseInstallTerminal, _ReleaseInstallFailureEpoch, RELEASE_INSTALL_REASONS
	if !_ReleaseInstall_OwnerCurrent(Current, "")
		return false
	Deps := Current["deps"]
	if Message["reason_key"] != RELEASE_INSTALL_REASONS["download"] || !Deps.Has("failure_classify")
		return true
	PreviousCritical := Critical("On")
	try {
		if !_ReleaseInstall_OwnerCurrent(Current, "")
			return false
		ExpectedEpoch := ++_ReleaseInstallFailureEpoch
		Current["epoch"] := ExpectedEpoch
		Current["receipt"] := Receipt is Map ? Receipt : Map()
		Current["stage_owner"] := StageOwner
		_ReleaseInstallTerminal := Current
	} finally Critical(PreviousCritical)
	try Report := Deps["failure_classify"].Call(Current["receipt"],
		() => _ReleaseInstall_FailureCurrent(Current), () => _ReleaseInstall_Retry(Current))
	catch {
		PreviousCritical := Critical("On")
		try {
			if _ReleaseInstallTerminal == Current && Current["epoch"] == ExpectedEpoch
				_ReleaseInstallTerminal := 0
		} finally Critical(PreviousCritical)
		try LoggerError("ReleaseInstall", "Managed-network capability inspection failed; no failure actions admitted.")
		return _ReleaseInstall_OwnerCurrent(Current, "") && _ReleaseInstallTerminal == 0
	}
	PreviousCritical := Critical("On")
	try {
		if !_ReleaseInstall_OwnerCurrent(Current, "") || _ReleaseInstallTerminal != Current
			|| Current["epoch"] != ExpectedEpoch
			return false
		Current["failure_report"] := Report
		Message["managed_failure"] := true
		Message["operation"] := Current["id"]
		Message["failure_epoch"] := ExpectedEpoch
		Message["failure_report"] := Report
		return true
	} finally Critical(PreviousCritical)
}

_ReleaseInstall_FailureCurrent(Current) {
	global _ReleaseInstallTerminal, _ReleaseInstallTag
	if !_ReleaseInstall_OwnerCurrent(Current, "") || !IsObject(_ReleaseInstallTerminal) || ObjPtr(_ReleaseInstallTerminal) != ObjPtr(Current)
		|| _ReleaseInstallTag != ""
		return false
	Deps := Current["deps"]
	Admitted := Deps.Has("failure_current") && Deps["failure_current"].Call(Current) == true
		&& Deps["blocked"].Call() == "" && !Deps["busy"].Call()
	return Admitted && _ReleaseInstall_OwnerCurrent(Current, "") && IsObject(_ReleaseInstallTerminal) && ObjPtr(_ReleaseInstallTerminal) == ObjPtr(Current)
		&& _ReleaseInstallTag == ""
}

; Exact terminal IDs are necessary but do not replace fresh native admission.
ReleaseInstall_FailureAction(Operation, Epoch, Id) {
	global _ReleaseInstallTerminal
	Current := _ReleaseInstallTerminal
	if !(Operation is Integer) || !(Epoch is Integer) || !(Id is String)
		|| !IsObject(Current) || Operation != Current["id"] || Epoch != Current["epoch"]
		|| !_ReleaseInstall_FailureCurrent(Current)
		return false
	Deps := Current["deps"]
	return Deps["failure_action"].Call(Current["failure_report"]["cause"], Id,
		() => _ReleaseInstall_FailureCurrent(Current), () => _ReleaseInstall_Retry(Current)) == true
}

; Retry preserves the initial backup and the native staging owner's consent,
; authenticated asset/digest, pause provenance and channel policy.
_ReleaseInstall_Retry(Previous) {
	global _ReleaseInstallTerminal, _ReleaseInstallCurrent, _ReleaseInstallTag, _ReleaseInstallOperation
	if !_ReleaseInstall_FailureCurrent(Previous)
		return false
	Deps := Previous["deps"]
	_ReleaseInstallTerminal := 0
	_ReleaseInstallOperation += 1
	Current := Map("id", _ReleaseInstallOperation, "tag", Previous["tag"], "channel", Previous["channel"],
		"backup_path", Previous["backup_path"], "deps", Deps, "native_owner", Previous["native_owner"], "release", Previous["release"])
	_ReleaseInstallCurrent := Current
	Tag := Current["tag"], BackupPath := Current["backup_path"]
	_ReleaseInstallTag := Tag
	_ReleaseInstall_Report(Deps, Map("tag", Tag, "phase", "downloading", "backup_path", BackupPath))
	Observer := (Phase, ReasonKey := "", FailureReceipt := 0) =>
		_ReleaseInstall_OnPhase(Deps, Tag, BackupPath, Phase, ReasonKey, FailureReceipt, Current)
	if !_ReleaseInstall_OwnerCurrent(Current, Tag)
		return false
	Started := false
	try Started := Deps["failure_retry"].Call(Previous["stage_owner"], Observer) == true
	catch {
		try LoggerError("ReleaseInstall", "The retained native retry refused before dispatch.")
	}
	if !Started && _ReleaseInstallTag == Tag && ObjPtr(_ReleaseInstallCurrent) == ObjPtr(Current)
		_ReleaseInstall_Fail(Deps, Tag, "download", BackupPath, Current)
	return Started
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
; @param Message {Map} Public phase strings, integer epochs and canonical safe report.
; @returns {String}
ReleaseInstall_MessageJson(Message) {
	Text := "{", Index := 0
	for Key in ["tag", "phase", "reason_key", "backup_path", "id", "created_at"] {
		if !Message.Has(Key) || !(Message[Key] is String)
			continue
		Text .= (Index++ ? "," : "") . JsonStringLiteral(Key) . ":" . JsonStringLiteral(Message[Key])
	}
	for Key in ["operation", "failure_epoch"] {
		if !Message.Has(Key) || !(Message[Key] is Integer) || Message[Key] < 1
			continue
		Text .= (Index++ ? "," : "") . JsonStringLiteral(Key) . ":" . Message[Key]
	}
	if Message.Has("managed_failure") && Message["managed_failure"] == true
		Text .= (Index++ ? "," : "") . '"managed_failure":true'
	if Message.Has("failure_report") && Message["failure_report"] is Map {
		Report := Message["failure_report"]
		Public := '{"cause":' . JsonStringLiteral(Report["cause"])
			. ',"message_key":' . JsonStringLiteral(Report["message_key"]) . ',"actions":['
		for I, Action in Report["actions"]
			Public .= (I > 1 ? "," : "") . '{"id":' . JsonStringLiteral(Action["id"])
				. ',"label_key":' . JsonStringLiteral(Action["label_key"]) . '}'
		Text .= (Index++ ? "," : "") . '"failure_report":' . Public . "]}"
	}
	return Text . "}"
}
