; ui/onboarding/finish.ahk

; ==============================================================================
; MODULE: Onboarding / Config Write + GUI Utilities
; DESCRIPTION:
; Final config write and driver reload, plus the GUI utility helpers shared by every step (centering, progress-dots row, dynamic-width nav buttons, active-Gui cleanup).
;
; Split out of the former infra/onboarding.ahk (the module split); see
; ui/onboarding/init.ahk for the module overview. Functions and globals are
; hoisted, so load order across the onboarding/*.ahk files is irrelevant.
; ==============================================================================





; ==========================================
; ==========================================
; ======= 5/ Config write and reload =======
; ==========================================
; ==========================================

; Write all collected wizard answers to config.toml in one atomic call, then
; reload so ErgoptiPlus boots with a fully-configured environment.
; Persist the chosen config dir to paths.toml. Same format produced by
; the FilePathsEditor dialog (infra/onboarding-independent helper in
; ErgoptiPlus.ahk) so a wizard pass and a later edit-via-tray produce
; structurally identical files.
; The config folder the wizard's answers will actually land in. _ConfigDir is
; deliberately NOT updated until the commit succeeds, so any page rendered
; after the folder step must resolve through here — reading _ConfigDir shows
; the boot folder, which is how the keystroke-logging consent text ended up
; naming a path that keystrokes were never going to be written to.
_Onboarding_EffectiveConfigDir() {
	global _ob_config_dir, _ConfigDir
	Dir := (IsSet(_ob_config_dir) and _ob_config_dir != "")
		? _ob_config_dir
		: (IsSet(_ConfigDir) ? _ConfigDir : "")
	if (Dir != "" and !RegExMatch(Dir, "\\$"))
		Dir .= "\"
	return Dir
}

_Onboarding_Commit(BeforeReloadFn := 0) {
	; If the user picked a custom config directory in the StepConfigDir
	; wizard step, persist its candidate config before pointing paths.toml at it.
	; The boot path resolver will then route ConfigurationFile to the new location
	; on the upcoming Reload. We publish the in-memory ``ConfigurationFile`` only
	; after both writes succeed. An empty ``_ob_config_dir`` means
	; "use the OS default" — which is a REQUEST, not a no-op: when the driver
	; is currently redirected elsewhere it has to be moved back and paths.toml
	; rewritten, or the user's ask to leave that folder is silently dropped.
	global _ob_config_dir, _ConfigDir, _DefaultConfigDir, _PathsFile, ConfigurationFile, _AhkSubDir
	PreviousCritical := Critical("Off")
	try {
	try {
		PreviousConfigDir := _ConfigDir
		PreviousConfigurationFile := ConfigurationFile
		CandidateDir := _ConfigDir
		CandidateConfig := ConfigurationFile
		PathRedirectRequired := false
		if (IsSet(_ob_config_dir) and _ob_config_dir != "") {
			CandidateDir := _ob_config_dir
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

		updates := [
		{ Section: "script",       Key: "locale",                   Value: _ob_locale    },
		{ Section: "layout",   Key: "ergopti_base",             Value: _ob_layout    },
		{ Section: "layout",   Key: "ergopti_alt_gr",           Value: _ob_layout    },
		{ Section: "layout",   Key: "ergopti_plus",             Value: _ob_layout    },
		{ Section: "hotstrings",   Key: "trigger_char",             Value: _ob_magic_key },
		{ Section: "metrics",  Key: "metrics_enabled",          Value: _ob_metrics   },
		{ Section: "gestures", Key: "enabled",                  Value: _ob_gestures  },
	]

	; Defer the Precision-Touchpad registry writes to the post-reload pass —
	; the gestures module reads ``auto_configure_on_next_start`` after its
	; globals are populated and runs the actual ``GestureAutoConfigureRegistry``
	; there. The flag is one-shot: the module clears it after a successful
	; (or failed) attempt so subsequent reloads don't keep rewriting the
	; same values.
		if _ob_register_pending
			updates.Push({ Section: "gestures", Key: "auto_configure_on_next_start", Value: true })

		; The wizard is reachable from the live tray as well as first boot. Hold
		; current config ownership from native/WAL quiescence through candidate
		; write, paths.toml replacement, live publication and Reload. A release
		; before Reload lets an already-open trigger dialog commit to whichever
		; path the partial transition exposed.
		TransitionPaths := [CandidateConfig]
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
			if !LLM_Menu_QuiesceTriggerForLifecycle(OwnerBundle) {
				_Onboarding_CommitError(
					"onboarding.error.commit_trigger_recovery")
				return false
			}
			CandidateResult := TOML_BuildUpdatedContent(CandidateConfig, updates)
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
			if PathRedirectRequired {
				try LocatorContent := ConfigTransitionPathsTomlContent(
					CandidateDir, _DefaultConfigDir)
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

			; Publish only the fully persisted state. The teardown callback runs from
			; the reload hand-off only after every refusal gate accepts, so a failed
			; reload keeps the existing wizard alive for retry.
			_ConfigDir := CandidateDir
			ConfigurationFile := CandidateConfig
			Reloaded := ReloadPreservingSuspend(BeforeReloadFn, OwnerBundle)
			if (Reloaded is Integer) && Reloaded == 1
				return true
			_ConfigDir := PreviousConfigDir
			ConfigurationFile := PreviousConfigurationFile
			RollbackResult := ConfigTransitionRollbackOwned(_PathsFile,
				OwnerBundle)
			if !ConfigTransitionResultIs(RollbackResult, "recovered_old")
					&& !ConfigTransitionResultIs(RollbackResult, "absent") {
				ConfigTransitionLogFailure("OnboardingRollback", RollbackResult)
				if ConfigTransitionRetainBarrier(OwnerBundle)
					ReleaseBundle := false
				_Onboarding_CommitError(
					"onboarding.error.commit_rollback")
			}
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

_Onboarding_CommitError(Key) {
	global _ob_locale
	Code := IsSet(_ob_locale) && (_ob_locale is String) && _ob_locale != ""
		? _ob_locale : "en"
	Message := _Onboarding_Translate(Code, Key)
	Title := _Onboarding_Translate(Code, "onboarding.error.title")
	try LoggerError("Onboarding", "Onboarding commit failed ({1}).", Key)
	try MsgBox(Message, Title, "Icon!")
}





; ======================================
; ======================================
; ======= 6/ GUI utility helpers =======
; ======================================
; ======================================



; ======================================
; ===== 6.1) Centering and display =====
; ======================================


; Center the wizard window on the primary monitor and show it. Also wire a
; Close handler so the X button does not leave Onboarding_Run() looping on a
; window that is no longer visible — instead it cleanly clears ``_ob_gui``
; and lets the caller decide what to do next.
;
; @param g       Gui  The wizard window object.
; @param widthW  Int  Optional override width. Defaults to the standard
;                     ONBOARDING_WIN_W — Step 2 passes ONBOARDING_STEP2_W
;                     so the layout preview JPG renders larger.
_Onboarding_Show(g, widthW := unset) {
	g.OnEvent("Close", _Onboarding_OnGuiClose)
	w := IsSet(widthW) ? widthW : ONBOARDING_WIN_W
	; Always centre: same-width pages land on the exact same spot (no jump), and
	; the wider step-2 page grows symmetrically about the centre. The seamless
	; feel comes from _Onboarding_Navigate building this page BEFORE destroying
	; the previous one, so the screen never shows a gap between them.
	g.Show("w" w " AutoSize Center")
}



; ==========================================
; ===== 6.1c) Wizard progress-dots row =====
; ==========================================

; Draws the wizard's top progress row: ONBOARDING_TOTAL_STEPS circled-number
; glyphs centred across the content width. The current step uses a filled
; (negative) circled digit in the accent colour; completed and upcoming steps
; use an outline circled digit in a lighter blue / gray respectively. One Text
; control per glyph so each is coloured independently. MUST be the first
; controls added to the page so they sit at the top margin; the caller then
; adds its bold section title via ``y+N`` directly below.
; @param g          Gui  The active wizard window.
; @param stepIndex  Int  1-based index of the current step.
; @param winW       Int  Page width; defaults to ONBOARDING_WIN_W (step 2 passes the wider canvas).
_Onboarding_AddProgressDots(g, stepIndex, winW := 0) {
	global ONBOARDING_WIN_W, ONBOARDING_TOTAL_STEPS, ONBOARDING_DOT_PITCH
	global ONBOARDING_DOT_ACTIVE, ONBOARDING_DOT_IDLE, ONBOARDING_DOT_DONE
	if (winW = 0)
		winW := ONBOARDING_WIN_W
	contentW := winW - 40                        ; usable width inside the 20 px side margins
	runW     := (ONBOARDING_TOTAL_STEPS - 1) * ONBOARDING_DOT_PITCH
	startX   := 20 + (contentW - runW) // 2      ; left edge that centres the glyph run
	; Three visual states, all the same nominal width (circled digits share a
	; common advance in Segoe UI):
	;   - current step  → FILLED (negative) circled digit ➊..➏ in accent blue:
	;     the disc is blue and the digit is knocked out, reading as white-on-blue.
	;   - completed step → outline circled digit ➀..➅ in accent blue.
	;   - upcoming step  → outline circled digit ➀..➅ in gray.
	; Code points: 0x2776..0x277B = ➊..➏ (filled), 0x2780..0x2785 = ➀..➅ (outline);
	; Three glyph series, all from the same Segoe UI font block so metrics match:
	;   Active  → U+2776+i  (➊➋➌➍➎➏) filled disc, digit knocked out — blue/green
	;   Done    → U+2460+i-1 (①②③④⑤⑥) thin circle outline — blue
	;   Upcoming→ same outline series — gray
	; All rendered at s13 Bold so the advance widths are identical across states.
	g.SetFont("s13 Bold")
	loop ONBOARDING_TOTAL_STEPS {
		i := A_Index
		x := startX + (i - 1) * ONBOARDING_DOT_PITCH
		if (i = stepIndex) {
			color := ONBOARDING_DOT_ACTIVE            ; current step — always blue
			glyph := Chr(0x2775 + i)   ; ➊=U+2776 … ➏=U+277B  filled disc
		} else if (i < stepIndex) {
			color := ONBOARDING_DOT_DONE              ; completed steps — green
			glyph := Chr(0x245F + i)   ; ①=U+2460 … ⑥=U+2465  outline
		} else {
			color := ONBOARDING_DOT_IDLE              ; upcoming steps — gray
			glyph := Chr(0x245F + i)
		}
		if (i = 1)
			g.AddText("x" x " c" color, glyph)
		else
			g.AddText("x" x " yp c" color, glyph)
	}
	g.SetFont("s10 norm")                         ; restore the body font for the caller
}




; =====================================================
; ===== 6.1b) Dynamic-width nav button row helper =====
; =====================================================

; Minimum width applied to every Back / Next / Finish button so the wizard
; keeps its proportions even when the active locale's labels are extremely
; short (e.g. ``OK``/``次``). 90 px matches the historical fixed width.
global ONBOARDING_BTN_MIN_W := 90

; Builds the bottom navigation row (Back + Next, or just Next on step 1) with
; both buttons sized to the longest label so they line up symmetrically across
; locales. Without this, ``w90``/``w110`` clipped long German captions like
; ``Durchsuchen`` or ``Auto-Konfiguration``.
;
; The helper creates both buttons with auto-width first, measures their
; natural widths via GetPos, computes a shared width, then pins Back to the
; left margin and Next to the right margin of the wizard window.
;
; @param g          Gui      The active wizard window.
; @param backLabel  String   Localised Back label, or "" to skip the Back button.
; @param nextLabel  String   Localised Next/Finish label (always shown).
; @param isDefault  Bool     true → Next gets the ``Default`` option (Enter key triggers it).
; @returns          [btnBack | unset, btnNext]   The control objects, ready for OnEvent wiring.
_Onboarding_AddNavButtons(g, backLabel, nextLabel, isDefault := true) {
	; ``y+16`` advances past whatever the previous control on the page was so
	; the row sits visually separated. ``yp`` on the second control keeps both
	; buttons on the same row.
	hasBack := (backLabel != "")
	if hasBack {
		btnBack := g.AddButton("x20 y+16",                       backLabel)
		btnNext := g.AddButton((isDefault ? "Default " : "") . "yp", nextLabel)
	} else {
		btnBack := unset
		btnNext := g.AddButton((isDefault ? "Default " : "") . "x20 y+16", nextLabel)
	}

	; Harmonise widths via the shared GUI helper so this wizard inherits the
	; same dynamic-button policy applied across every other dialog. Pinning
	; Next to the right margin happens AFTER harmonise so the shared width is
	; the one used to compute the right-edge anchor.
	sharedW := Gui_HarmoniseButtonWidths(hasBack ? [btnBack, btnNext] : [btnNext], ONBOARDING_BTN_MIN_W)
	btnNext.Move(ONBOARDING_WIN_W - 20 - sharedW)

	return hasBack ? [btnBack, btnNext] : [unset, btnNext]
}

; Single close handler reused by every wizard page. Triggered when the user
; clicks the window's X button or hits Alt+F4.
_Onboarding_OnGuiClose(g, *) {
	; Restore AltGr behaviour for the rest of the session — the user closed
	; the wizard without committing, so we are about to either ExitApp (first
	; launch) or return control to the running script (menu-triggered relaunch).
	; In the latter case keeping the flag set would silently break AltGr until
	; the next reload.
	global _OB_ALTGR_PASSTHROUGH := false
	_Onboarding_DestroyActive()
}



; ===================================
; ===== 6.2) Active Gui cleanup =====
; ===================================

; Releases the step-1 language-preview machinery: cancels the debounce timer and
; unhooks its WM_KEYDOWN handler. Called when leaving step 1 (and during a full
; teardown) so neither fires against a torn-down ListView afterwards.
_Onboarding_ReleaseStep1Hooks() {
	global _ob_s1_lv_hwnd
	; Cancel the debounce timer — if it fired after the ListView is gone,
	; _Step1_DebounceRender would call GetNext() on a dead reference and throw.
	SetTimer(_Step1_DebounceRender, 0)
	; Unhook the WM_KEYDOWN handler so it cannot fire on a stale hwnd later.
	if (_ob_s1_lv_hwnd != 0) {
		OnMessage(0x0100, _Step1_LvKeyDown, 0)
		_ob_s1_lv_hwnd := 0
	}
}

; Transitions from the current page to the next by BUILDING the new page before
; destroying the old one — the opposite of a naive destroy-then-build, which
; flashes the desktop between pages. The new page is shown centred (same spot for
; same-width pages) and AlwaysOnTop, so it covers the old window; only then is the
; old one destroyed, giving a seamless content swap with no gap between pages.
; @param stepFn Func  Next-page builder (e.g. _Onboarding_Step2); it must set the
;                     global _ob_gui to its freshly-created Gui and show it.
_Onboarding_Navigate(stepFn) {
	global _ob_gui
	oldGui := (_ob_gui != 0) ? _ob_gui : 0
	; Step 1 owns a debounce timer + a WM_KEYDOWN hook; release them before we
	; leave it so they never fire against the ListView we are about to destroy.
	_Onboarding_ReleaseStep1Hooks()
	; Build + show the new page (sets _ob_gui to the new Gui). It is shown centred
	; and AlwaysOnTop, covering the old page; only AFTER it is up do we destroy
	; the old one — so the screen never shows a gap/flash between pages.
	stepFn()
	if (oldGui != 0 && oldGui != _ob_gui) {
		try oldGui.Destroy()
	}
}

; Fully tear down the active wizard Gui — used for terminal exits (the user
; closed the window, or the wizard committed and is about to Reload), NOT for
; page-to-page navigation (use _Onboarding_Navigate for that, to avoid the
; inter-page desktop flash). Keeps at most one page alive.
_Onboarding_DestroyActive() {
	global _ob_gui
	_Onboarding_ReleaseStep1Hooks()
	try {
		if (_ob_gui != 0) {
			_ob_gui.Destroy()
		}
	}
	_ob_gui := 0
}
