; static/ergopti_plus/windows/tests/e2e/run_e2e.ahk

; ==============================================================================
; MODULE: E2E Virtual-Keyboard Test Harness (AutoHotkey)
; DESCRIPTION:
; End-to-end test harness for the ErgoptiPlus hotstring engine. Validates the
; full expansion pipeline using two complementary strategies:
;
;   Strategy A — Pure engine injection (headless):
;     Feeds characters one by one into HSE_FeedChar to drive the custom
;     hotstring engine, then inspects _Stub_RecordedSends to verify that
;     the correct backspace sequence and replacement text were dispatched.
;     This runs entirely in-process without any OS window and is safe in
;     headless CI (GitHub Actions windows-latest).
;
;   Strategy B — Real GUI window injection (optional, skipped in headless CI):
;     Creates an AHK Gui with an Edit control, sends the trigger via
;     SendInput, waits for the InputHook to fire, and reads back the control
;     text via ControlGetText. Enabled only when E2E_REAL_GUI is set to 1
;     on the command line (e.g. "AutoHotkey.exe run_e2e.ahk 1").
;
; CORPUS:
; Every shared vector is replayed through the production registration factories,
; matching, dispatch and intercepted native sender. A virtual document applies
; the actual emitted deletions and text, proving retained context and casing.
; Explicit terminator consumption selects the end-character path, matching the
; macOS and Linux corpus consumers. The sender is the sole substituted boundary.
;
; USAGE (headless CI):
;   AutoHotkey64.exe run_e2e.ahk
; USAGE (real GUI):
;   AutoHotkey64.exe run_e2e.ahk 1
; ==============================================================================

#Requires Autohotkey v2.0+
SetWorkingDir(A_ScriptDir)
#Warn All, StdOut
#Warn VarUnset, Off
global _AHK_DRY_RUN := false

; Load the test framework first so Assert / Test / RunTests are available.
#Include ../test_framework.ahk
; Override the default A_Temp path so CI finds the results file next to this
; script (the workflow step looks for test_results.txt in tests/e2e/).
global TEST_RESULTS_FILE := A_ScriptDir . "\test_results.txt"
; The shared app-context simulators publish into KLHook, just as the main
; runner does. Load the definition here so E2E never depends on ambient state.
#Include ../../modules/keylogger/keylogger_hook.ahk
#Include ../test_stubs.ahk

; Production engine dependencies (same order as run_all.ahk).
#Include ../../infra/json.ahk
#Include ../../infra/app_state.ahk
#Include ../../_generated/window_titles.ahk
#Include ../../infra/native_dialogs.ahk
#Include ../../infra/ui_style.ahk
#Include ../../_generated/app_dirs.ahk
#Include ../../infra/logger.ahk
#Include ../../infra/hotpath_profiler.ahk

#Include ../../infra/window_utils.ahk
#Include ../../infra/text_utils.ahk
#Include ../../infra/hotstrings/hotstring_engine.ahk
#Include ../../infra/hotstrings/hotstring_engine_main.ahk
; Project the same shipped terminator catalogue that production boot loads.
; The bare engine's parser defaults omit the configurable magic terminator.
#Include ../../_generated/terminators.ahk
#Include ../../infra/hotstrings/hotstrings_catalogue.ahk
global HSE_Terminators := Terminators()
global HSE_WORD_TERMINATORS := HSE_TerminatorDefaultWordDelimiters()
global HSE_CONSUMED_DELIMITERS := HSE_TerminatorDefaultConsumedDelimiters()
; Every expansion is sent through the tap-hold owner, which lifts an AltGr a
; tap-hold holds around the output (_HSE_SendWithAltGrUp). Without these files
; the call failed, the dispatch logged it and sent nothing, so the harness saw
; an empty expansion. They load in run_all.ahk's order.
#Include ../../adapters/text_sender.ahk
#Include ../../adapters/key_state.ahk
#Include ../../platform/remap/constants.ahk
#Include ../../platform/remap/tap_hold_roll.ahk

; Intercept all Send* calls so they are captured rather than typed to the OS.
InstallHotstringHooks()





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; Whether Strategy B (real Gui window injection) is requested.
; Set to 1 by passing any truthy first argument on the command line.
global E2E_REAL_GUI := (A_Args.Length >= 1 and A_Args[1] == "1")

; Magic sentinel used by the engine (mirrors ErgoptiPlus.ahk).
global E2E_MAGIC_KEY := Chr(0x2605)  ; ★ U+2605


; Load the canonical corpus; missing/empty data must fail instead of skipping.
global E2E_SCENARIOS := JsonParse(FileRead(A_ScriptDir
    . "\..\..\..\_shared\tests\corpus\hotstrings\vectors.json", "UTF-8"))["vectors"]
if !(E2E_SCENARIOS is Array) or E2E_SCENARIOS.Length == 0
    throw Error("The shared hotstring corpus contains no E2E vectors.")






; =====================================================
; =====================================================
; ======= 2/ Strategy A — Pure engine injection =======
; =====================================================
; =====================================================

; Drive real registration and dispatch while applying captured sends to a virtual
; document. Native input hooks and the OS sender are outside this headless tier.
E2E_RunScenarioPure(Scenario) {
    global _HotstringRegistrar, HSE_CONSUMED_DELIMITERS
    SavedRegistrar := _HotstringRegistrar
    SavedConsumed := HSE_CONSUMED_DELIMITERS
    HSE_RegistryClear()
    HSE_HardReset()
    HSE_FeedReset(true)
    HSE_Suppress(false)
    ResetHotstringRecorders()
    SimulateRegularApp()
    Trigger := Scenario["trigger"]
    InputBuffer := Scenario.Get("buffer", "")
    Term := Scenario.Get("terminator", " ")
    AssertTrue(_TextCodepointLength(Term) <= 1, "the corpus terminator must describe one physical character")
    Flags := Scenario.Get("is_word", false) ? "" : "?"
    ; An explicit consumption policy describes the END path; STAR would fire
    ; before that future character exists. Both Lua E2E consumers do the same.
    if Scenario.Get("auto_expand", false) and !Scenario.Has("terminator_consumed")
        Flags .= "*"
    if Scenario.Get("is_case_sensitive_strict", false)
        Flags .= "C"
    HSE_CONSUMED_DELIMITERS := Scenario.Get("terminator_consumed", false) ? Term : ""
    Document := ""
    DispatchCount := 0
    LogicalBackspaces := 0
    NextSend := 1
    try {
        ; The production factory publishes to HSE directly; the optional
        ; registration recorder is unnecessary. Native output remains intercepted.
        _HotstringRegistrar := 0
        HSE_RegisterFromTomlFlags(Scenario.Get("is_case_sensitive", false),
            Flags, Trigger, Scenario["replacement"],
            Map("OnlyText", true, "Priority", HSE_PRIORITY_COMMON))
        for Char in _TextCodepoints(InputBuffer . Term) {
            Document .= Char
            Match := HSE_FeedChar(Char)
            if !IsObject(Match)
                continue
            EndChar := HSE_LastEndChar
            AssertTrue(HSE_DispatchMatch(Match, EndChar), "an admitted match must actually dispatch")
            DispatchCount += 1
            EmittedBackspaces := _E2E_ApplyRecordedEdit(&Document, &NextSend)
            ; Windows deletes an already visible end character and replays it
            ; when retained. The shared count excludes only that physical replay.
            ReplayedEnd := EndChar != "" and !InStr(HSE_CONSUMED_DELIMITERS, EndChar)
            LogicalBackspaces += EmittedBackspaces - (ReplayedEnd ? _TextCodepointLength(EndChar) : 0)
        }
        return Map("matched", DispatchCount > 0, "document", Document,
            "backspace_count", LogicalBackspaces, "dispatch_count", DispatchCount)
    } finally {
        _HotstringRegistrar := SavedRegistrar
        HSE_CONSUMED_DELIMITERS := SavedConsumed
        HSE_RegistryClear()
        HSE_HardReset()
    }
}

; Decode the actual atomic edit, never the registry's desired replacement.
_E2E_ApplyRecordedEdit(&Document, &NextSend) {
    global _Stub_RecordedSends
    Deleted := 0
    Applied := 0
    while NextSend <= _Stub_RecordedSends.Length {
        Entry := _Stub_RecordedSends[NextSend++]
        AssertTrue(Entry.args.Length > 0, "a captured native send must carry its payload")
        Payload := Entry.args[1]
        AssertTrue(RegExMatch(Payload, "^\{BackSpace (\d+)\}\{Text\}([\s\S]*)$", &Edit),
            "the intercepted sender must emit a recognized atomic text edit: " . Payload)
        Count := Integer(Edit[1])
        AssertTrue(Count <= _TextCodepointLength(Document), "an expansion must never delete before the virtual document starts")
        Document := SubStr(Document, 1, StrLen(Document) - _TextTailCodeUnits(Document, Count)) . Edit[2]
        Deleted += Count
        Applied += 1
    }
    AssertTrue(Applied > 0, "successful dispatch must produce actual native output")
    return Deleted
}






; ==================================================
; ==================================================
; ======= 3/ Strategy B — Real GUI injection =======
; ==================================================
; ==================================================

; Creates a hidden Gui with an Edit control, sends the trigger string and
; terminator via SendInput, and reads back the control text. Returns the
; full text content of the Edit control after the injection.
;
; NOTE: This path requires a real WindowServer session and the AHK hotstring
; engine to be wired to an InputHook listening on the window — it is NOT
; wired by default in the test harness because InstallHotstringHooks()
; redirects all sends to the stub recorder. This function is provided as a
; proof-of-concept scaffold; see PLAN_E2E_REAL_AHK.md for the full unblocking
; path.
E2E_RunScenarioGui(Trigger, Terminator) {
    TestGui := Gui("+AlwaysOnTop", "E2E Target")
    EditCtrl := TestGui.AddEdit("w400 h100", "")
    TestGui.Show("x10 y10")

    ; Give the window time to appear and become the active target.
    WinWaitActive("E2E Target",, 3)
    if ErrorLevel {
        TestGui.Destroy()
        return "ERROR: window did not activate"
    }

    ControlFocus(EditCtrl, "E2E Target")
    ; Send the trigger + terminator directly via SendInput.
    SendInput(Trigger . Terminator)
    ; Wait for any pending expansion to settle.
    Sleep(150)

    Result := ControlGetText(EditCtrl, "E2E Target")
    TestGui.Destroy()
    return Result
}





; ====================================
; ====================================
; ======= 4/ Test registration =======
; ====================================
; ====================================

; Named helper used by the loop below — receives the scenario Map directly
; so each Test() callback is bound to a specific scenario via .Bind().
_E2E_RunPureTest(Sc) {
    Result := E2E_RunScenarioPure(Sc)
    Expected := Sc["expected"]
    InputBuffer := Sc.Get("buffer", "")
    Term := Sc.Get("terminator", " ")
    AssertEqual(Expected["matched"], Result["matched"], "dispatch verdict must match the shared vector")
    if Expected["matched"] {
        AssertEqual(1, Result["dispatch_count"], "a single-trigger vector must dispatch exactly once")
        Prefix := SubStr(InputBuffer, 1, StrLen(InputBuffer) - StrLen(Sc["trigger"]))
        RetainedEnd := Sc.Get("terminator_consumed", false) ? "" : Term
        AssertEqual(Prefix . Expected["replacement"] . RetainedEnd, Result["document"],
            "actual emitted edits must preserve context and produce the exact replacement")
        AssertEqual(Expected["backspace_count"], Result["backspace_count"],
            "the real edit must replace the logical number of typed characters")
    } else {
        AssertEqual(0, Result["dispatch_count"], "a rejected mapping must emit no expansion")
        AssertEqual(InputBuffer . Term, Result["document"], "a non-match must leave physical input unchanged")
    }
}

; Register one Test() case per scenario for Strategy A (pure engine).
; .Bind(Sc) creates a new callable with Sc pre-filled as the first argument,
; avoiding the closure-over-loop-variable capture problem.
for _Sc in E2E_SCENARIOS {
    Test("e2e[pure] " . _Sc["id"], _E2E_RunPureTest.Bind(_Sc))
}


; Supplementary characters must exercise the same actual sender replay.
_E2E_UnicodeReplay() {
    global HSE_WORD_TERMINATORS
    Saved := HSE_WORD_TERMINATORS
    Emoji := Chr(0x1F600)
    try {
        _E2E_RunPureTest(Map("trigger", Emoji . "x", "buffer", "A" . Emoji . "x",
            "replacement", "R", "terminator", "", "auto_expand", true,
            "is_case_sensitive", true, "is_case_sensitive_strict", true,
            "expected", Map("matched", true, "replacement", "R", "backspace_count", 2)))
        HSE_WORD_TERMINATORS .= Emoji
        _E2E_RunPureTest(Map("trigger", "xy", "buffer", "Axy", "replacement", "R",
            "terminator", Emoji, "terminator_consumed", true,
            "is_case_sensitive", true, "is_case_sensitive_strict", true,
            "expected", Map("matched", true, "replacement", "R", "backspace_count", 3)))
    } finally {
        HSE_WORD_TERMINATORS := Saved
    }
}
Test("e2e[pure] supplementary trigger and completion preserve native edits (unicode-erase)",
    _E2E_UnicodeReplay)

; Strategy B — real GUI — registered only when E2E_REAL_GUI is set.
; In that mode the test creates a visible Edit control, types the trigger,
; and asserts the expansion appeared in the text. Skipped in headless CI.
if E2E_REAL_GUI {
    Test("e2e[gui] simple_expansion — btw expands in Edit control", _E2E_RunGuiTest)
}

_E2E_RunGuiTest() {
    Text := E2E_RunScenarioGui("btw", " ")
    AssertEqual("by the way ", Text)
}





; ==============================
; ==============================
; ======= 5/ Entry point =======
; ==============================
; ==============================

; Safety watchdog: kill the process if RunTests does not exit within 30 s.
; This prevents the CI job from hanging indefinitely if AHK's message loop
; stays alive after ExitApp (e.g. a pending one-shot SetTimer keeps the
; process persistent on some CI runners).
SetTimer(_E2E_Watchdog, -30000)

_E2E_Watchdog() {
    try FileAppend("WATCHDOG: forced exit after 30 s`r`n", "*")
    ExitApp(2)
}

RunTests()
