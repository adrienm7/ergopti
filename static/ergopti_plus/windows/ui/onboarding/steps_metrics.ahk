; ui/onboarding/steps_metrics.ahk

; ==============================================================================
; MODULE: Onboarding / Metrics + Gestures Steps
; DESCRIPTION:
; Wizard steps covering typing-metrics opt-in and trackpad-gesture
; configuration. These two steps form the final group of the onboarding flow:
; they let the user enable keystroke logging and set up precision-touchpad
; gesture shortcuts via an automated PowerShell script or a manual tutorial.
;
; Split from ui/onboarding/steps.ahk; see ui/onboarding/init.ahk for the full
; module overview. Functions and globals are hoisted, so load order across the
; onboarding/*.ahk files is irrelevant.
; ==============================================================================

; Success token the elevated PowerShell worker writes to its result file
; ([string]$ErgoptiExitCode, 0 on success). Named because it is a NUMERIC
; STRING: comparing the reader's String|false result against `false` makes AHK
; v2 compare numerically, so "0" = false is TRUE and success reads as failure.
global GESTURE_AUTO_SUCCESS_TOKEN := "0"





; ====================================================
; ====================================================
; ======= 4.4/ Typing Metrics + Gestures Steps =======
; ====================================================
; ====================================================



; ========================================
; ===== 4.4) Step 4 — Typing metrics =====
; ========================================

_Onboarding_Step4() {
	global _ConfigDir
	g := Gui("+AlwaysOnTop", t("onboarding.welcome.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := ONBOARDING_MARGIN_Y

	; Progress dots — step 5 of 6.
	_Onboarding_AddProgressDots(g, 5)

	g.SetFont("s12 Bold")
	g.AddText("xm w" ONBOARDING_WIN_W - 40 " y+12 Center", _Onboarding_StripBrand(t("onboarding.metrics.title")))
	g.SetFont("s9 norm")
	g.AddText("xm w" ONBOARDING_WIN_W - 40 " y+8", t("onboarding.metrics.desc"))

	; The shared keylogger warning string uses ``%s`` (printf-style) so the same
	; text works on Hammerspoon (Lua's string.format) and AHK. AHK v2's
	; Format() expects {1}-style placeholders and would leave ``%s`` verbatim,
	; so the substitution is done with StrReplace here.
	; Normalise the path with forward slashes — the cross-platform locale string
	; is shared with the Hammerspoon driver, where macOS already uses ``/``;
	; matching that style on Windows keeps the displayed path consistent across
	; both drivers and avoids the visual clutter of Windows backslashes inside
	; the red warning block.
	metrics_path := StrReplace(_ConfigDir . "metrics", "\", "/")
	warning := Format(t("dialog.metrics.enable_warning"), metrics_path)
	; Warning: plain orange text between two horizontal rules — simpler and reliable.
	g.AddText("xm y+10 w" ONBOARDING_WIN_W - 40 " 0x10")  ; SS_ETCHEDHORZ — top separator
	g.SetFont("s9 norm", "Segoe UI")
	g.AddText("xm y+6 w" ONBOARDING_WIN_W - 40 " cFF8C00", Chr(0x26A0) " " warning)
	g.SetFont("s10 norm", "Segoe UI")
	g.AddText("xm y+6 w" ONBOARDING_WIN_W - 40 " 0x10")  ; SS_ETCHEDHORZ — bottom separator

	global _ob_metrics
	rYes := g.AddRadio("vMetricsChoice xm y+10" . (_ob_metrics ? " Checked" : ""), t("onboarding.yes"))
	rNo  := g.AddRadio((!_ob_metrics ? "Checked " : "") . "y+2", t("onboarding.no"))

	btns := _Onboarding_AddNavButtons(g, t("onboarding.back"), t("onboarding.next"))
	btnBack := btns[1]
	btnNext := btns[2]

	btnBack.OnEvent("Click", _Step4_Back.Bind(g))
	btnNext.OnEvent("Click", _Step4_Next.Bind(g, rYes))

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step4_Back(g, *) {
	_Onboarding_Navigate(_Onboarding_Step3)
}

_Step4_Next(g, rYes, *) {
	global _ob_metrics := (rYes.Value = 1)
	_Onboarding_Navigate(_Onboarding_Step5)
}



; ===========================================
; ===== 4.5) Step 5 — Trackpad gestures =====
; ===========================================

_Onboarding_Step5() {
	g := Gui("+AlwaysOnTop", t("onboarding.welcome.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := ONBOARDING_MARGIN_Y

	; Progress dots — step 6 of 6.
	_Onboarding_AddProgressDots(g, 6)

	g.SetFont("s12 Bold")
	g.AddText("xm w" ONBOARDING_WIN_W - 40 " y+12 Center", _Onboarding_StripBrand(t("onboarding.gestures.title")))
	g.SetFont("s9 norm")
	g.AddText("xm w" ONBOARDING_WIN_W - 40 " y+8", t("onboarding.gestures.desc"))
	g.SetFont("s10")

	; Restore the previously-saved Yes/No when the wizard was re-opened over
	; an existing config (pre-load step in _StepConfigDir_Next).
	global _ob_gestures
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+12", "")
	rYes := g.AddRadio("vGesturesChoice xm" . (_ob_gestures ? " Checked" : ""), t("onboarding.yes"))
	rNo  := g.AddRadio((!_ob_gestures ? "Checked " : "") . "y+2", t("onboarding.no"))

	; Registration panel — only visible when "Yes" is selected. We pre-build
	; every control as hidden so the layout does not jump when the user clicks
	; the radio buttons; visibility is toggled by _Step5_OnRadioChange.
	; All controls anchored xm so they align flush with the left margin.
	panelW := ONBOARDING_WIN_W - 40
	g.AddText("xm w" panelW " y+10 Hidden", "")
	regSectionLbl := g.AddText("xm w" panelW " Hidden",
		t("onboarding.gestures.register_section"))

	btnRegAuto := g.AddButton("xm w" panelW " y+6 Hidden",
		t("onboarding.gestures.register_auto"))
	g.SetFont("s8 italic")
	autoHint := g.AddText("xm w" panelW " y+4 Hidden",
		t("onboarding.gestures.register_auto_hint"))
	g.SetFont("s10 norm")

	btnRegManual := g.AddButton("xm w" panelW " y+6 Hidden",
		t("onboarding.gestures.register_manual"))
	g.SetFont("s8 italic")
	manualHint := g.AddText("xm w" panelW " y+4 Hidden",
		t("onboarding.gestures.register_manual_hint"))
	g.SetFont("s10 norm")

	; Status feedback (success / failure) sits below the buttons — also hidden
	; until the user actually triggers a registration attempt.
	statusLbl := g.AddText("w" ONBOARDING_WIN_W - 40 " y+10 Hidden", "")

	regControls := [regSectionLbl, btnRegAuto, autoHint, btnRegManual, manualHint]

	; Toggling visibility on radio change keeps the wizard tidy when the user
	; declines gesture support (the configuration step is irrelevant in that case).
	rYes.OnEvent("Click", _Step5_OnRadioChange.Bind(regControls, statusLbl, true))
	rNo.OnEvent("Click",  _Step5_OnRadioChange.Bind(regControls, statusLbl, false))

	; When the wizard was re-opened over an existing config that had gestures
	; enabled, mirror the auto-checked Yes radio by showing the registration
	; panel right away — otherwise the user sees Yes ticked but no controls.
	if _ob_gestures {
		_Step5_OnRadioChange(regControls, statusLbl, true)
	}

	btnRegAuto.OnEvent("Click",   _Step5_AutoRegister.Bind(statusLbl))
	btnRegManual.OnEvent("Click", _Step5_ShowManualTutorial.Bind(g))

	btns := _Onboarding_AddNavButtons(g, t("onboarding.back"), t("onboarding.finish"))
	btnBack   := btns[1]
	btnFinish := btns[2]

	btnBack.OnEvent("Click", _Step5_Back.Bind(g))
	btnFinish.OnEvent("Click", _Step5_Finish.Bind(g, rYes))

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step5_OnRadioChange(regControls, statusLbl, isYes, *) {
	for ctrl in regControls {
		try ctrl.Visible := isYes
	}
	; Clear any stale success/failure status when the user flips back to No
	if !isYes {
		try statusLbl.Visible := false
		try statusLbl.Text    := ""
	}
}

; The elevated worker writes its own result before it exits. Polling a PID and
; then asking OpenProcess for an exit code is racy: Windows may already have
; released the process object, and _SR_GetExitCode deliberately returns 0 in
; that case. A missing or malformed result is therefore a failure, never a
; false success shown to the user.
global _OnboardingGestureJob := Map("epoch", 0, "pid", 0, "script", "", "result", "", "done", 0)

_Onboarding_StartGestureAuto(OnDone) {
    global _OnboardingGestureJob
    if _OnboardingGestureJob["pid"] {
        if ProcessExist(_OnboardingGestureJob["pid"])
            return false
        ; A click can arrive after the process exited but before its one-shot
        ; poll ran. Deliver that completed job before replacing its state.
        _Onboarding_PollGestureAuto(_OnboardingGestureJob["epoch"])
        if _OnboardingGestureJob["pid"]
            return false
    }
    Epoch := _OnboardingGestureJob["epoch"] + 1
    JobStem := A_Temp . "\ergopti_gesture_config_" . DriverPid . "_" . Epoch
    ScriptPath := JobStem . ".ps1"
    ResultPath := JobStem . ".result"
    FSDelete(ResultPath)
    if !FSWrite(ScriptPath, _Onboarding_BuildGesturePsScript(ResultPath)) {
        try LoggerError("Onboarding", "Could not write gesture PS script.")
        return false
    }
    Pid := 0
    try Run('*RunAs powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' . ScriptPath . '"', , "Hide", &Pid)
    catch as err {
        FSDelete(ScriptPath)
        try LoggerError("Onboarding", "Gesture auto-config launch failed: {1}.", err.Message)
        return false
    }
    _OnboardingGestureJob := Map("epoch", Epoch, "pid", Pid, "script", ScriptPath, "result", ResultPath, "done", OnDone)
    SetTimer(_Onboarding_PollGestureAuto.Bind(Epoch), -100)
    return true
}

_Onboarding_PollGestureAuto(Epoch) {
    global _OnboardingGestureJob
    if (_OnboardingGestureJob["epoch"] != Epoch || !_OnboardingGestureJob["pid"])
        return
    ; Suspend does not stop timers. Do not mutate onboarding UI or invoke a
    ; callback while the keyboard driver is suspended; retain the job until it
    ; resumes instead.
    if A_IsSuspended {
        SetTimer(_Onboarding_PollGestureAuto.Bind(Epoch), -100)
        return
    }
    if ProcessExist(_OnboardingGestureJob["pid"]) {
        SetTimer(_Onboarding_PollGestureAuto.Bind(Epoch), -100)
        return
    }
    Ok := _Onboarding_ReadGestureAutoResult(_OnboardingGestureJob["result"])
    Done := _OnboardingGestureJob["done"]
    FSDelete(_OnboardingGestureJob["script"])
    FSDelete(_OnboardingGestureJob["result"])
    _OnboardingGestureJob["pid"] := 0
    _OnboardingGestureJob["done"] := 0
    if IsObject(Done)
        try Done.Call(Ok)
}

_Onboarding_ReadGestureAutoResult(ResultPath) {
    Result := FSRead(ResultPath)
    ; FSRead returns a String on success and the INTEGER false on failure. Never
    ; compare the result against false: AHK v2 compares NUMERICALLY when one side
    ; is a number and the other a numeric string, so the success token "0"
    ; satisfies `Result = false` (0 = 0) and every successful registration was
    ; swallowed as "result missing". `==` does not help — it is numeric-equal here
    ; too. Type-checking is the only correct discriminator.
    if !(Result is String) {
        try LoggerError("Onboarding", "Gesture auto-config result missing.")
        return false
    }
    Result := Trim(Result)
    if (Result != GESTURE_AUTO_SUCCESS_TOKEN) {
        try LoggerWarn("Onboarding", "Gesture auto-config returned invalid/failing result: {1}.", Result)
        return false
    }
    return true
}

_Step5_AutoRegister(statusLbl, *) {
	; Run the gesture auto-configuration SYNCHRONOUSLY via PowerShell so the
	; user sees a definitive red/green status the moment they click — no more
	; "will be configured on next start" deferred path. The PS script is
	; self-contained (it hardcodes the same registry value set that
	; modules/gestures.ahk would write) so this works at first-launch BEFORE
	; the gestures module's #Include block has had a chance to assign its
	; GESTURE_REG_* globals.
	;
	; A single elevated PowerShell does both halves (registry writes + the
	; touchpad PnP cycle), so the user sees ONE UAC prompt and the brief
	; ~2 s freeze that follows. We do not pre-update the status label to
	; "Configuring…" because RunWait blocks the message loop — the user
	; would never see the intermediate state.
	;
	; Implementation note: the previous version inlined the PS via
	; ``powershell -Command "…"`` and ran into argv-quoting / backtick
	; pitfalls — the script launched but silently exited without doing any
	; work. We now write the script to a temp ``.ps1`` file and invoke it
	; with ``-File``, which sidesteps every shell-quoting question.
	global _ob_register_pending := false  ; never defer anymore

	if !_Onboarding_StartGestureAuto((ok) => _Step5_ShowGestureStatus(statusLbl, ok))
		_Step5_ShowGestureStatus(statusLbl, false)
}

; Paints the status label red or green and makes it visible. Each call site
; (success / failure) was previously identical bar one constant, so we extract
; the duplication into this helper. The label was created with the ``Hidden``
; option so we explicitly clear that AND set ``.Visible := true`` — relying on
; the property alone has bitten us before when the layout reflowed.
;
; ALSO fires a MsgBox as a guaranteed fallback. Several users have reported
; "PowerShell flashes then nothing happens" — i.e. the status label never
; updated visibly. Whether that is a control-state bug, an autosize edge case
; or just the label being below the fold, the MsgBox makes sure the user
; ALWAYS gets a definitive confirmation that the registration finished.
;
; ``ok = true`` renders the success message in green; ``false`` paints failure
; in red. The translation key — not the literal message — is chosen up front
; so the locale's wording always wins over any cached string.
_Step5_ShowGestureStatus(statusLbl, ok) {
	global _ob_gui
	Key := ok ? "onboarding.gestures.register_success" : "onboarding.gestures.register_failed"
	Color := ok ? "cGreen" : "cRed"
	Msg := t(Key)
	try statusLbl.Opt("-Hidden")
	try statusLbl.SetFont("s9 " . Color)
	try statusLbl.Text    := Msg
	try statusLbl.Visible := true
	try statusLbl.Redraw()
	; Guaranteed visible feedback — see comment above. The wizard window is
	; +AlwaysOnTop (see _StepConfigDir_Browse in steps_config.ahk), which wins
	; the topmost tie against this MsgBox on Windows and renders it BEHIND the
	; wizard, appearing to hang. Drop the wizard's topmost flag for the
	; duration of the MsgBox, then restore it afterwards (try-wrapped so the
	; MsgBox still shows even if _ob_gui is unexpectedly 0).
	if (_ob_gui != 0)
		try _ob_gui.Opt("-AlwaysOnTop")
	try MsgBox(Msg, t("onboarding.gestures.title"), ok ? "Iconi" : "Icon!")
	if (_ob_gui != 0)
		try _ob_gui.Opt("+AlwaysOnTop")
}

; Builds a self-contained PowerShell script that writes every PrecisionTouchPad
; registry value AND restarts the touchpad PnP device so the new gesture map
; takes effect without a logout. Values are hardcoded inline — they mirror the
; ``GESTURE_REG_*`` maps in modules/gestures.ahk but live here so the wizard
; can call them before that module's auto-execute runs. Keep both copies in
; sync when adding / changing gesture slots.
;
; The returned text is a full .ps1 script (multi-line, comments allowed)
; written to a temp file by the caller — running it via ``-File`` avoids the
; argv-quoting issues that plagued the previous ``-Command`` inline variant.
_Onboarding_BuildGesturePsScript(ResultPath) {
	; KeyParams encoding: (VK << 16) | 0x07 where 0x07 = Ctrl|Shift|Win.
	; F1..F10 = 0x70..0x79. The script is assembled line-by-line instead of
	; via a multi-line continuation section because the latter — combined
	; with embedded ``foreach (...)`` lines — triggers a fail-fast crash
	; (STATUS_STACK_BUFFER_OVERRUN, 0xC0000409) during AHK v2's continuation-
	; section parser. Concatenating with explicit ``\`r\`n`` separators keeps
	; the parser happy AND yields identical .ps1 content on disk.
	CRLF := "`r`n"
	ResultLiteral := StrReplace(ResultPath, "'", "''")
	S := ""
	S .= "$ErrorActionPreference = 'Stop'" . CRLF
	S .= "$ResultPath = '" . ResultLiteral . "'" . CRLF
	S .= "$ErgoptiExitCode = 1" . CRLF
	S .= "$Reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad'" . CRLF
	; Create the PrecisionTouchPad key if missing (machines that never had a
	; precision touchpad driver loaded won't have it). Without this guard,
	; Set-ItemProperty -Force still fails with "Cannot find path" and the
	; whole script bails out before any value is written. -Force on New-Item
	; makes the call idempotent so it's safe when the key already exists.
	S .= "if (-not (Test-Path $Reg)) { New-Item -Path $Reg -Force | Out-Null }" . CRLF
	S .= "$V = @{" . CRLF
	; Master enables — turn the gesture families on
	S .= "  'ThreeFingerSlideEnabled' = 65535" . CRLF
	S .= "  'ThreeFingerTapEnabled'   = 65535" . CRLF
	S .= "  'FourFingerSlideEnabled'  = 65535" . CRLF
	S .= "  'FourFingerTapEnabled'    = 65535" . CRLF
	; Per-direction enables (swipe slots only)
	S .= "  'ThreeFingerUp'    = 65535" . CRLF
	S .= "  'ThreeFingerDown'  = 65535" . CRLF
	S .= "  'ThreeFingerLeft'  = 65535" . CRLF
	S .= "  'ThreeFingerRight' = 65535" . CRLF
	S .= "  'FourFingerUp'     = 65535" . CRLF
	S .= "  'FourFingerDown'   = 65535" . CRLF
	S .= "  'FourFingerLeft'   = 65535" . CRLF
	S .= "  'FourFingerRight'  = 65535" . CRLF
	; CustomXFingerTap = 7 sentinel (user-defined shortcut)
	S .= "  'CustomThreeFingerTap' = 7" . CRLF
	S .= "  'CustomFourFingerTap'  = 7" . CRLF
	; KeyParams — Fn key encoding for each slot (Ctrl+Win+Shift+Fn)
	S .= "  'CustomThreeFingerTapKeyParams' = 7340039"  . CRLF  ; F1
	S .= "  'ThreeFingerUpKeyParams'        = 7405575"  . CRLF  ; F2
	S .= "  'ThreeFingerDownKeyParams'      = 7471111"  . CRLF  ; F3
	S .= "  'ThreeFingerLeftKeyParams'      = 7536647"  . CRLF  ; F4
	S .= "  'ThreeFingerRightKeyParams'     = 7602183"  . CRLF  ; F5
	S .= "  'CustomFourFingerTapKeyParams'  = 7667719"  . CRLF  ; F6
	S .= "  'FourFingerUpKeyParams'         = 7733255"  . CRLF  ; F7
	S .= "  'FourFingerDownKeyParams'       = 7798791"  . CRLF  ; F8
	S .= "  'FourFingerLeftKeyParams'       = 7864327"  . CRLF  ; F9
	S .= "  'FourFingerRightKeyParams'      = 7929863"  . CRLF  ; F10
	; *Action = 65535 disables the new-system actions so KeyParams wins
	S .= "  'ThreeFingerTapAction'        = 65535" . CRLF
	S .= "  'ThreeFingerSlideUpAction'    = 65535" . CRLF
	S .= "  'ThreeFingerSlideDownAction'  = 65535" . CRLF
	S .= "  'ThreeFingerSlideLeftAction'  = 65535" . CRLF
	S .= "  'ThreeFingerSlideRightAction' = 65535" . CRLF
	S .= "  'FourFingerTapAction'         = 65535" . CRLF
	S .= "  'FourFingerSlideUpAction'     = 65535" . CRLF
	S .= "  'FourFingerSlideDownAction'   = 65535" . CRLF
	S .= "  'FourFingerSlideLeftAction'   = 65535" . CRLF
	S .= "  'FourFingerSlideRightAction'  = 65535" . CRLF
	S .= "}" . CRLF
	S .= "try {" . CRLF
	S .= "  foreach ($n in $V.Keys) {" . CRLF
	; New-ItemProperty -Force creates the property OR updates it in place.
	; Set-ItemProperty raises "Property X does not exist" on a first-time
	; PrecisionTouchPad key (one we may have just created above), which
	; aborts the whole script under $ErrorActionPreference='Stop'.
	S .= "    New-ItemProperty -Path $Reg -Name $n -Value $V[$n] -PropertyType DWord -Force | Out-Null" . CRLF
	S .= "  }" . CRLF
	S .= "  $devs = Get-PnpDevice -PresentOnly | Where-Object {" . CRLF
	S .= "    $_.Class -eq 'HIDClass' -and $_.FriendlyName -match 'Input Configuration|I2C HID'" . CRLF
	S .= "  }" . CRLF
	S .= "  foreach ($d in $devs) {" . CRLF
	S .= "    Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue" . CRLF
	S .= "  }" . CRLF
	S .= "  Start-Sleep -Milliseconds 500" . CRLF
	S .= "  foreach ($d in $devs) {" . CRLF
	S .= "    Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue" . CRLF
	S .= "  }" . CRLF
	S .= "  $ErgoptiExitCode = 0" . CRLF
	S .= "} catch {" . CRLF
	S .= "}" . CRLF
	S .= "try { [System.IO.File]::WriteAllText($ResultPath, [string]$ErgoptiExitCode, [System.Text.Encoding]::ASCII) } catch { exit 1 }" . CRLF
	S .= "exit $ErgoptiExitCode" . CRLF
	return S
}

_Step5_ShowManualTutorial(parentGui, *) {
	; Single source of truth lives in modules/gestures.ahk — both the tray
	; menu's "Manual tutorial" item and this wizard button render the same
	; popup (tutorial body + in-panel "Open touchpad settings" button).
	GestureShowManualTutorialDialog()
}

_Step5_Back(g, *) {
	_Onboarding_Navigate(_Onboarding_Step4)
}

_Step5_Finish(g, rYes, *) {
	global _ob_gestures := (rYes.Value = 1)
	if _Onboarding_Commit() {
		_Onboarding_DestroyActive()
		Reload
	}
}
