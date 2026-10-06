; ui/onboarding/finish.ahk

; ==============================================================================
; MODULE: Onboarding / Config Write + Reload
; DESCRIPTION:
; Commits the wizard's validated answers: one transactional write of the
; candidate config.toml (with the imported tap-hold keys' tap_hold.toml, and
; paths.toml when the configuration folder moves), stamped with this build's
; schema version, then a single Reload so every module starts from the new
; files. A refused reload rolls every file back and leaves the wizard open for
; a retry. A tap_hold.toml that cannot take the import leaves the other
; answers to be saved without it, as on macOS and Linux, and the user is told.
; A key whose recommended hold enters the navigation layer brings Ergopti's
; recommended layer along: layers.toml is created in the same transition when
; the folder has none, and an existing one is never replaced.
;
; Split out of the former infra/onboarding.ahk (the module split); see
; ui/onboarding/init.ahk for the module overview. Functions and globals are
; hoisted, so load order across the onboarding/*.ahk files is irrelevant.
; ==============================================================================





; ==========================================
; ==========================================
; ======= 1/ Config write and reload =======
; ==========================================
; ==========================================

; The tap_hold.toml target a wizard commit publishes beside config.toml, with
; the file it replaces backed up first. A file that cannot take the import
; (unreadable, or holding a key of the user's) must not cost the other answers,
; as on macOS and Linux: the commit saves them without the keys, then says so.
; @param Path string The tap_hold.toml beside the candidate config.toml.
; @param Keys Array Validated key ids from OnboardingTapHoldKeys.
; @returns {Map|String} The transition target, or why the keys are not imported.
_Onboarding_TapHoldTarget(Path, Keys) {
	global _SharedDir
	try {
		Image := TapHoldImportImage(Path, _SharedDir . "\tap_hold\defaults.toml", Keys)
		Backup := TapHoldImportBackup(Path, Image)
		ExpectedOld := ConfigTransitionExpectedOld(Image["source_present"], Image["source_content"])
		if !(ExpectedOld is Map)
			throw Error("the bytes of '" . Path . "' could not be verified")
	} catch as Err {
		try LoggerError("Onboarding",
			"The tap-hold keys cannot be imported into '{1}': {2}. The other answers are saved without them.",
			Path, Err.Message)
		return Err.Message
	}
	if (Backup != "")
		try LoggerInfo("Onboarding", "Backed up '{1}' to '{2}' before the tap-hold import.", Path, Backup)
	return ConfigTransitionPresentTarget(Path, Image["content"], ExpectedOld)
}

; The layers.toml a wizard commit creates beside its tap-hold import: the
; configuration folder's, when one of the imported keys' recommended hold
; enters the layer Ergopti's recommended layer file binds.
; @param ConfigDir string The configuration folder being set up.
; @param Keys Array Validated key ids from OnboardingTapHoldKeys.
; @returns {String} The layers.toml path, "" when no imported key enters the layer.
; Throws when the shipped layer or tap-hold data cannot be read.
_Onboarding_NavLayerPath(ConfigDir, Keys) {
	global _SharedDir
	Preset := TapHoldRecommendedLayer(_SharedDir)
	if !TapHoldPresetEntersLayer(_SharedDir . "\tap_hold\defaults.toml", Keys, Preset["layer_id"])
		return ""
	return KeymapLayers_UserFilePathFromVocabulary(_SharedDir, ConfigDir)
}

; The transition target that creates layers.toml from the recommended layer.
; An existing file is the user's: no target is returned for it.
; @param Path string The folder's layers.toml.
; @returns {Map|Integer|String} The target, 0 for a file kept as it is, or why
;   the layer cannot be imported.
_Onboarding_NavLayerTarget(Path) {
	global _SharedDir
	try Image := TapHoldLayerImportImage(_SharedDir, Path)
	catch as Err {
		try LoggerError("Onboarding",
			"The recommended navigation layer cannot be imported into '{1}': {2}. The other answers are saved without it.",
			Path, Err.Message)
		return Err.Message
	}
	if (Image["content"] == Image["source_content"]) {
		try LoggerInfo("Onboarding", "'{1}' is kept: the wizard never replaces a layer file.", Path)
		return 0
	}
	return ConfigTransitionPresentTarget(Path, Image["content"], ConfigTransitionExpectedOld(0, ""))
}

; The configuration rows a wizard commit writes: the chosen language, then the
; answers the page gave as manifest paths (already validated and sparse).
; @param Locale string Locale code the user picked.
; @param Rows Array Rows from OnboardingAnswerRows.
; @returns {Array}
_Onboarding_CommitUpdates(Locale, Rows) {
	Updates := [{ Section: "script", Key: "locale", Value: Locale }]
	for Row in Rows
		Updates.Push(Row)
	return Updates
}

; Write all collected wizard answers to config.toml in one atomic call, then
; reload so ErgoptiPlus boots with a fully-configured environment.
; Persist the chosen config dir to paths.toml. Same format produced by
; the FilePathsEditor dialog (infra/onboarding-independent helper in
; ErgoptiPlus.ahk) so a wizard pass and a later edit-via-tray produce
; structurally identical files.
; The Tap-Holds page's checked keys are imported by the tap-hold writer into
; the tap_hold.toml beside the candidate config.toml, in the same transition,
; so a key never lands in a folder whose answers were not saved. A tap-hold
; file that cannot take them is left alone and the user told once the other
; answers are saved.
; @param Locale string Locale code the user picked.
; @param ConfigDir string Folder typed on the config page; "" is the OS default.
; @param Rows Array Validated rows from OnboardingAnswerRows.
; @param TapHoldKeys Array Validated key ids from OnboardingTapHoldKeys.
; @param BeforeReloadFn Func|0 Teardown lent to the accepted reload hand-off.
; @returns {Boolean} False when nothing was committed or the reload was refused.
_Onboarding_Commit(Locale, ConfigDir, Rows, TapHoldKeys, BeforeReloadFn := 0) {
	; If the user picked a custom config directory on the config page, persist
	; its candidate config before pointing paths.toml at it.
	; The boot path resolver will then route ConfigurationFile to the new location
	; on the upcoming Reload. We publish the in-memory ``ConfigurationFile`` only
	; after both writes succeed. An empty ``ConfigDir`` means
	; "use the OS default" — which is a REQUEST, not a no-op: when the driver
	; is currently redirected elsewhere it has to be moved back and paths.toml
	; rewritten, or the user's ask to leave that folder is silently dropped.
	global _ConfigDir, _DefaultConfigDir, _PathsFile, ConfigurationFile, _AhkSubDir
	global _DefaultLogsDir
	PreviousCritical := Critical("Off")
	try {
	try {
		PreviousConfigDir := _ConfigDir
		PreviousConfigurationFile := ConfigurationFile
		CandidateDir := _ConfigDir
		CandidateConfig := ConfigurationFile
		PathRedirectRequired := false
		if (ConfigDir != "") {
			CandidateDir := ConfigDir
		} else if (IsSet(_DefaultConfigDir) and _DefaultConfigDir != "") {
			; Empty field = "use the OS default". Resolving it here rather than
			; skipping the block is what makes the request real: the comparison
			; below then sees default != current and performs the move back.
			CandidateDir := _DefaultConfigDir
		}
		if (CandidateDir != "") {
			CandidateDir := ConfigTransitionNormalizeConfigDir(CandidateDir)
			if !(CandidateDir is String) {
				_Onboarding_CommitError(
					"onboarding.error.commit_invalid_config_dir")
				return false
			}
			if (CandidateDir != _ConfigDir) {
				DirCreate(CandidateDir)
				DirCreate(CandidateDir . _AhkSubDir)
				CandidateConfig := CandidateDir . _AhkSubDir . "config.toml"
				PathRedirectRequired := true
			}
		}

		updates := _Onboarding_CommitUpdates(Locale, Rows)
		TapHoldPath := ""
		LayersPath := ""
		NavLayerRefused := false
		if (TapHoldKeys.Length > 0) {
			TapHoldPath := TapHoldConfigPathBeside(CandidateConfig)
			try LayersPath := _Onboarding_NavLayerPath(CandidateDir, TapHoldKeys)
			catch as Err {
				NavLayerRefused := true
				try LoggerError("Onboarding",
					"The recommended navigation layer cannot be imported: {1}. The other answers are saved without it.",
					Err.Message)
			}
		}

		; The wizard is reachable from the live tray as well as first boot. Hold
		; current config ownership from candidate write through paths.toml
		; replacement, live publication and Reload. A release before Reload lets
		; an already-open menu dialog commit to whichever path the partial
		; transition exposed.
		TransitionPaths := [CandidateConfig]
		if (TapHoldPath != "")
			TransitionPaths.Push(TapHoldPath)
		if (LayersPath != "")
			TransitionPaths.Push(LayersPath)
		if PathRedirectRequired
			TransitionPaths.Push(_PathsFile)
		AcquireResult := ConfigTransitionAcquireLifecycleBundle(_PathsFile,
			TransitionPaths)
		if !ConfigTransitionResultIs(AcquireResult, "bundle_acquired") {
			ConfigTransitionLogFailure("Onboarding", AcquireResult)
			_Onboarding_CommitError(
				"onboarding.error.commit_transaction_busy")
			return false
		}
		OwnerBundle := AcquireResult["bundle"]
		ReleaseBundle := true
		try {
			; A config.toml the wizard creates carries this build's schema version.
			updates := ConfigMigrateStampNewFile(updates, CandidateConfig)
			updates := _ConfigPrepareTypedUpdates(updates)
			CandidateResult := TOML_BuildConfigUpdatedContent(CandidateConfig, updates)
			if !ConfigTransitionResultIs(CandidateResult, "rendered")
					|| !CandidateResult.Has("content")
					|| !(CandidateResult["content"] is String)
					|| !CandidateResult.Has("source_present")
					|| !(CandidateResult["source_present"] is Integer)
					|| !CandidateResult.Has("source_content")
					|| !(CandidateResult["source_content"] is String) {
				_Onboarding_CommitError(
					"onboarding.error.commit_candidate_render")
				return false
			}
			; Config targets are declared first and the stable locator last. The core
			; rejects any other locator position, and the WAL publishes before either
			; target changes, so boot can restore all-old or finish all-new.
			ExpectedCandidateOld := ConfigTransitionExpectedOld(
				CandidateResult["source_present"],
				CandidateResult["source_content"])
			if !(ExpectedCandidateOld is Map) {
				_Onboarding_CommitError(
					"onboarding.error.commit_source_verification")
				return false
			}
			TargetSpecs := [ConfigTransitionPresentTarget(CandidateConfig,
				CandidateResult["content"], ExpectedCandidateOld)]
			TapHoldsRefused := false
			if (TapHoldPath != "") {
				TapHoldTarget := _Onboarding_TapHoldTarget(TapHoldPath, TapHoldKeys)
				TapHoldsRefused := !(TapHoldTarget is Map)
				if !TapHoldsRefused
					TargetSpecs.Push(TapHoldTarget)
				; The layer goes with its key: never into a folder whose keys
				; were not imported.
				if (!TapHoldsRefused && LayersPath != "") {
					LayerTarget := _Onboarding_NavLayerTarget(LayersPath)
					if (LayerTarget is Map)
						TargetSpecs.Push(LayerTarget)
					else if (LayerTarget is String)
						NavLayerRefused := true
				}
			}
			if PathRedirectRequired {
				; The rewrite keeps the user's LogsDirPath.
				try LocatorContent := ConfigTransitionPathsTomlContent(
					CandidateDir, _DefaultConfigDir,
					ConfigTransitionCurrentLogsOverride(), _DefaultLogsDir)
				catch as Err {
					try LoggerError("Onboarding",
						"Could not build paths.toml transition content: {1}.",
						Err.Message)
					_Onboarding_CommitError(
						"onboarding.error.commit_redirect_render")
					return false
				}
				TargetSpecs.Push(ConfigTransitionPresentTarget(_PathsFile,
					LocatorContent))
			}
			CommitResult := ConfigTransitionCommitOwned(_PathsFile, TargetSpecs,
				OwnerBundle)
			if !ConfigTransitionResultIs(CommitResult, "committed_new") {
				ConfigTransitionLogFailure("Onboarding", CommitResult)
				if CommitResult.Has("barrier_retained")
						&& (CommitResult["barrier_retained"] is Integer)
						&& CommitResult["barrier_retained"] == 1
					ReleaseBundle := false
				_Onboarding_CommitError(
					"onboarding.error.commit_transition")
				return false
			}
			; The other answers are saved: only now can the notice say so.
			if TapHoldsRefused
				_Onboarding_ShowError("onboarding.error.tap_holds_import")
			else if NavLayerRefused
				_Onboarding_ShowError("onboarding.error.nav_layer_import")

			; Publish only the fully persisted state. The teardown callback runs from
			; the reload hand-off only after every refusal gate accepts, so a failed
			; reload keeps the existing wizard alive for retry. A launched reload
			; owns the bundle until OnExit; a later refusal hands it back to the
			; same rollback a refused launch runs here.
			_ConfigDir := CandidateDir
			ConfigurationFile := CandidateConfig
			Rollback := _Onboarding_RollbackRefusedReload.Bind(
				PreviousConfigDir, PreviousConfigurationFile)
			Reloaded := ReloadPreservingSuspend(BeforeReloadFn, OwnerBundle,
				ConfigTransitionSettleRefusedReload.Bind(Rollback, OwnerBundle))
			if (Reloaded is Integer) && Reloaded == 1 {
				ReleaseBundle := false
				return true
			}
			if Rollback.Call(OwnerBundle)
				ReleaseBundle := false
			return false
		} finally {
			if ReleaseBundle
				_ConfigWriteTerminalRelease(OwnerBundle)
		}
	} catch as err {
		try LoggerError("Onboarding", "Could not commit onboarding settings: {1}.", err.Message)
		_Onboarding_CommitError(
			"onboarding.error.commit_unexpected")
		return false
	}
	} finally Critical(PreviousCritical)
}

; Restores the published directory and the files a wizard commit changed after
; its reload was refused.
; @returns {Boolean} True when the rollback failed and the barrier stays
;   retained around the unresolved transition, so the bundle must not be released.
_Onboarding_RollbackRefusedReload(PreviousConfigDir, PreviousConfigurationFile,
		OwnerBundle) {
	global _ConfigDir, ConfigurationFile, _PathsFile
	_ConfigDir := PreviousConfigDir
	ConfigurationFile := PreviousConfigurationFile
	RollbackResult := ConfigTransitionRollbackOwned(_PathsFile, OwnerBundle)
	if ConfigTransitionResultIs(RollbackResult, "recovered_old")
			|| ConfigTransitionResultIs(RollbackResult, "absent")
		return false
	ConfigTransitionLogFailure("OnboardingRollback", RollbackResult)
	Retained := ConfigTransitionRetainBarrier(OwnerBundle)
	_Onboarding_CommitError("onboarding.error.commit_rollback")
	return Retained
}

; Reports a commit failure in the wizard's language.
; @param Key string Locale key of the message.
_Onboarding_CommitError(Key) {
	try LoggerError("Onboarding", "Onboarding commit failed ({1}).", Key)
	_Onboarding_ShowError(Key)
}

; Shows an error in the language the wizard is displayed in, with a safe
; fallback before any language was chosen.
; @param Key string Locale key of the message.
_Onboarding_ShowError(Key) {
	global _ob_locale, ONBOARDING_FIRST_RUN_LOCALE
	Code := IsSet(_ob_locale) && (_ob_locale is String) && _ob_locale != ""
		? _ob_locale : ONBOARDING_FIRST_RUN_LOCALE
	Message := _Onboarding_Translate(Code, Key)
	Title := _Onboarding_Translate(Code, "common.error_title")
	try Ui_MsgBox(Message, Title, "Icon!")
}
