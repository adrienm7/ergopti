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
;   Strategy B — Owned native Windows Edit controls (mandatory):
;     Feeds the same production registration, matching and dispatch pipeline,
;     inserts literal text with native Edit messages and forwards actual emitted
;     atomic payloads to a private hidden Edit. The control's
;     text is observed independently after every input and expansion. This tier
;     covers native Unicode erasure and text storage. Physical InputHook and
;     SendInput delivery remain outside this isolated tier.
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
; ==============================================================================

#Requires Autohotkey v2.0+
SetWorkingDir(A_ScriptDir)
#Warn All, StdOut
#Warn VarUnset, Off
global _AHK_DRY_RUN := false

; Load the test framework first so Assert / Test / RunTests are available.
#Include ../test_framework.ahk
; Explicit launch receipts remain private; ordinary CI keeps its sibling file.
global TEST_RESULTS_FILE := _TestResultsPath(A_ScriptDir . "\test_results.txt")
_TestResultsBeginRun()
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
E2E_RunScenarioPure(Scenario, NativeControl := unset) {
    global _HotstringRegistrar, HSE_CONSUMED_DELIMITERS, _SendHook
    SavedSendHook := _SendHook
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
        if IsSet(NativeControl)
            _SendHook := _E2E_SendToNativeEdit.Bind(NativeControl)
        HSE_RegisterFromTomlFlags(Scenario.Get("is_case_sensitive", false),
            Flags, Trigger, Scenario["replacement"],
            Map("OnlyText", true, "Priority", HSE_PRIORITY_COMMON))
        for Char in _TextCodepoints(InputBuffer . Term) {
            Document .= Char
            if IsSet(NativeControl) {
                _E2E_InsertNativeText(NativeControl, Char)
                AssertEqual(Document, NativeControl.Value, "input must reach the owned native Edit")
            }
            Match := HSE_FeedChar(Char)
            if !IsObject(Match)
                continue
            EndChar := HSE_LastEndChar
            AssertTrue(HSE_DispatchMatch(Match, EndChar), "an admitted match must actually dispatch")
            DispatchCount += 1
            EmittedBackspaces := _E2E_ApplyRecordedEdit(&Document, &NextSend)
            if IsSet(NativeControl)
                AssertEqual(Document, NativeControl.Value, "native output must match the independently decoded edit")
            ; Windows deletes an already visible end character and replays it
            ; when retained. The shared count excludes only that physical replay.
            ReplayedEnd := EndChar != "" and !InStr(HSE_CONSUMED_DELIMITERS, EndChar)
            LogicalBackspaces += EmittedBackspaces - (ReplayedEnd ? _TextCodepointLength(EndChar) : 0)
        }
        return Map("matched", DispatchCount > 0, "document", Document,
            "backspace_count", LogicalBackspaces, "dispatch_count", DispatchCount)
    } finally {
        _SendHook := SavedSendHook
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
; ======= 3/ Strategy B — Native Edit output =======
; ==================================================
; ==================================================

/** Rejects destroyed, visible or foreign controls before any native message. */
_E2E_AssertNativeControlOwner(EditControl) {
    AssertTrue(DllCall("IsWindow", "Ptr", EditControl.Hwnd), "the owned native Edit must remain alive")
    AssertFalse(DllCall("IsWindowVisible", "Ptr", EditControl.Hwnd), "the owned native Edit must remain hidden")
    AssertEqual(DllCall("GetCurrentProcessId", "UInt"), WinGetPID(EditControl.Hwnd),
        "the native Edit must belong to this test process")
}

/** Inserts literal text through the owned native Edit message boundary. */
_E2E_InsertNativeText(EditControl, Text) {
    _E2E_AssertNativeControlOwner(EditControl)
    SendMessage(0x00C2, 1, StrPtr(Text), EditControl)
}

/** Applies the production sender payload to one owned native control. */
_E2E_SendToNativeEdit(EditControl, FnName, Args*) {
    _E2E_AssertNativeControlOwner(EditControl)
    AssertEqual("SendFinalResult", FnName, "the native tier must receive the production final sender")
    AssertTrue(Args.Length == 2 and !Args[2], "the native sender must preserve its command payload")
    _HOOK_RecordSend(FnName, Args*)
    AssertTrue(RegExMatch(Args[1], "^\{BackSpace (\d+)\}\{Text\}([\s\S]*)$", &Edit),
        "the native tier must receive a recognized atomic edit")
    loop Integer(Edit[1])
        SendMessage(0x0102, 8, 1, EditControl)
    _E2E_InsertNativeText(EditControl, Edit[2])
    return true
}

/** Replays real registration, matching and output into a hidden Windows Edit. */
_E2E_RunNativeEditTest(Scenario) {
    Window := Gui()
    EditControl := Window.AddEdit("w400 h100 Multi WantTab", "")
    Window.Show("Hide")
    try {
        AssertFalse(DllCall("IsWindowVisible", "Ptr", Window.Hwnd),
            "the native fixture must remain hidden")
        AssertEqual(DllCall("GetCurrentProcessId", "UInt"),
            WinGetPID(Window.Hwnd), "the native fixture must belong to this test process")
        Result := E2E_RunScenarioPure(Scenario, EditControl)
        _E2E_AssertScenario(Scenario, Result)
        AssertEqual(Result["document"], EditControl.Value,
            "the owned native control must retain the exact final document")
        return Result
    } finally {
        Window.Destroy()
    }
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
    _E2E_AssertScenario(Sc, Result)
    return Result
}

/** Shares verdict assertions while keeping native output independently observed. */
_E2E_AssertScenario(Sc, Result) {
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
_E2E_UnicodeReplay(Runner := _E2E_RunPureTest) {
    global HSE_WORD_TERMINATORS
    Saved := HSE_WORD_TERMINATORS
    Emoji := Chr(0x1F600)
    try {
        Scenario := Map("trigger", Emoji . "x", "buffer", "A" . Emoji . "x",
            "replacement", "R", "terminator", "", "auto_expand", true,
            "is_case_sensitive", true, "is_case_sensitive_strict", true,
            "expected", Map("matched", true, "replacement", "R", "backspace_count", 2))
        _E2E_AssertScenario(Scenario, Runner.Call(Scenario))
        HSE_WORD_TERMINATORS .= Emoji
        Scenario := Map("trigger", "xy", "buffer", "Axy", "replacement", "R",
            "terminator", Emoji, "terminator_consumed", true,
            "is_case_sensitive", true, "is_case_sensitive_strict", true,
            "expected", Map("matched", true, "replacement", "R", "backspace_count", 3))
        _E2E_AssertScenario(Scenario, Runner.Call(Scenario))
    } finally {
        HSE_WORD_TERMINATORS := Saved
    }
}
Test("e2e[pure] supplementary trigger and completion preserve native edits (unicode-erase)",
    _E2E_UnicodeReplay)
Test("e2e[native-edit] supplementary trigger and completion preserve native edits (unicode-erase)",
    _E2E_UnicodeReplay.Bind(_E2E_RunNativeEditTest))

; The native control tier is mandatory and never activates a user window.
for _Sc in E2E_SCENARIOS {
    Test("e2e[native-edit] " . _Sc["id"], _E2E_RunNativeEditTest.Bind(_Sc))
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
