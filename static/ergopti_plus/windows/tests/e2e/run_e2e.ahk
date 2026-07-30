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
; Five scenarios are derived from the shared cross-driver corpus at
; static/ergopti_plus/_shared/tests/corpus/hotstrings/vectors.json (the same
; source the AHK unit meta-tests use). The vectors are reproduced inline
; here (as constants) so the harness is self-contained and does not require
; a JSON parser at E2E time.
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
#Include ../test_stubs.ahk

; Production engine dependencies (same order as run_all.ahk).
#Include ../../lib/app_state.ahk
#Include ../../lib/ui_style.ahk
#Include ../../lib/logger.ahk

#Include ../../lib/window_utils.ahk
#Include ../../lib/text_utils.ahk
#Include ../../lib/hotstrings/hotstring_engine.ahk
#Include ../../lib/hotstrings/hotstring_engine_main.ahk

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


; Corpus scenario definitions — inline transcription of the 5 E2E vectors
; from static/ergopti_plus/_shared/tests/corpus/hotstrings/vectors.json.
; Each entry is a Map with keys: id, trigger, replacement, is_word, is_cs,
; buffer, terminator, expect_match, expect_replacement, expect_bs_count.
global E2E_SCENARIOS := [
    Map(
        "id",                 "simple_expansion",
        "trigger",            "btw",
        "replacement",        "by the way",
        "is_word",            false,
        "is_cs",              false,
        "buffer",             "btw",
        "terminator",         " ",
        "expect_match",       true,
        "expect_replacement", "by the way",
        "expect_bs_count",    4
    ),
    Map(
        "id",                 "no_match_unrelated_buffer",
        "trigger",            "btw",
        "replacement",        "by the way",
        "is_word",            false,
        "is_cs",              false,
        "buffer",             "hello",
        "terminator",         " ",
        "expect_match",       false,
        "expect_replacement", "",
        "expect_bs_count",    0
    ),
    Map(
        "id",                 "word_boundary_mid_word_blocked",
        "trigger",            "the",
        "replacement",        "THE",
        "is_word",            true,
        "is_cs",              false,
        "buffer",             "othe",
        "terminator",         " ",
        "expect_match",       false,
        "expect_replacement", "",
        "expect_bs_count",    0
    ),
    Map(
        "id",                 "word_boundary_start_of_buffer",
        "trigger",            "the",
        "replacement",        "THE",
        "is_word",            true,
        "is_cs",              false,
        "buffer",             "the",
        "terminator",         " ",
        "expect_match",       true,
        "expect_replacement", "THE",
        "expect_bs_count",    4
    ),
    Map(
        "id",                 "case_sensitive_no_match",
        "trigger",            "BTW",
        "replacement",        "by the way",
        "is_word",            false,
        "is_cs",              true,
        "buffer",             "btw",
        "terminator",         " ",
        "expect_match",       false,
        "expect_replacement", "",
        "expect_bs_count",    0
    )
]





; =====================================================
; =====================================================
; ======= 2/ Strategy A — Pure engine injection =======
; =====================================================
; =====================================================

; Resets the engine and stubs, registers a single trigger, feeds the buffer
; char-by-char then the terminator, and returns a result Map with keys:
;   matched         (bool)   — whether HSE dispatched an expansion
;   replacement     (string) — the replacement text sent (empty if no match)
;   backspace_count (int)    — number of backspace strokes sent
E2E_RunScenarioPure(Scenario) {
    ; Fresh state for each scenario.
    HSE_RegistryClear()
    HSE_HardReset()
    HSE_FeedReset(true)
    HSE_Suppress(false)
    ResetHotstringRecorders()
    SimulateRegularApp()

    Trigger  := Scenario["trigger"]
    Repl     := Scenario["replacement"]
    IsWord   := Scenario["is_word"]
    IsCS     := Scenario["is_cs"]
    InputBuffer := Scenario["buffer"]
    Term        := Scenario["terminator"]

    ; Build HSE flags from the scenario options.
    Flags := ""
    if IsWord {
        ; is_word = word-boundary required = default (no "?" flag).
        ; No "?" means word boundary IS enforced — do not append anything.
    } else {
        ; No word-boundary restriction.
        Flags .= "?"
    }
    if IsCS {
        Flags .= "C"
    }

    ; Register the trigger. Meta carries Replacement so HSE_DispatchMatch
    ; performs the full BackSpace+Replacement burst via the send hook.
    HSE_Register(Flags, Trigger, 0, Map("Replacement", Repl, "OnlyText", true))

    ; Feed each character of the buffer into the engine.
    Loop StrLen(InputBuffer) {
        Match := HSE_FeedChar(SubStr(InputBuffer, A_Index, 1))
        if (Match != "") {
            HSE_DispatchMatch(Match, HSE_LastEndChar)
        }
    }

    ; Feed the terminator — this is what triggers the match check.
    Match := HSE_FeedChar(Term)
    if (Match != "") {
        HSE_DispatchMatch(Match, HSE_LastEndChar)
    }

    ; Analyse what the send hook captured.
    Sends := _Stub_RecordedSends
    Matched     := false
    Replacement := ""
    BSCount     := 0

    for Entry in Sends {
        Args := Entry.args
        if (Args.Length >= 1) {
            Payload := Args[1]
            ; Atomic format: "{BackSpace N}{Text}replacement endchar" or
            ; "{BackSpace N}replacement endchar" — produced by SendInput after
            ; the atomic-burst refactor (f7d69826c).
            if RegExMatch(Payload, "^\{BackSpace (\d+)\}(.*)", &M) {
                BSCount  := Integer(M[1])
                Matched  := true
                Rest     := M[2]
                ; Strip optional {Text} prefix injected for OnlyText=true entries.
                Rest     := RegExReplace(Rest, "^\{Text\}", "")
                ; The replacement is everything except the trailing end-char (1 char).
                ; If Rest is empty the expansion had no replacement text.
                if (StrLen(Rest) > 1) {
                    Replacement := SubStr(Rest, 1, StrLen(Rest) - 1)
                } else if (StrLen(Rest) == 1) {
                    ; Only one char: it is the end-char, no replacement text.
                    Replacement := ""
                }
            ; Legacy two-send format: backspace-only entry followed by replacement.
            } else if RegExMatch(Payload, "^\{BackSpace (\d+)\}$", &M) {
                BSCount := Integer(M[1])
                Matched := true
            } else if Matched and Payload != "" {
                if (Replacement == "") {
                    Replacement := Payload
                }
            }
        }
    }

    return Map(
        "matched",         Matched,
        "replacement",     Replacement,
        "backspace_count", BSCount
    )
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
    Result      := E2E_RunScenarioPure(Sc)
    ExpectMatch := Sc["expect_match"]
    ExpectRepl  := Sc["expect_replacement"]
    ExpectBS    := Sc["expect_bs_count"]
    if ExpectMatch {
        AssertEqual(ExpectRepl, Result["replacement"])
        AssertEqual(ExpectBS,   Result["backspace_count"])
    } else {
        AssertEqual(false, Result["matched"])
    }
}

; Register one Test() case per scenario for Strategy A (pure engine).
; .Bind(Sc) creates a new callable with Sc pre-filled as the first argument,
; avoiding the closure-over-loop-variable capture problem.
for _Sc in E2E_SCENARIOS {
    Test("e2e[pure] " . _Sc["id"], _E2E_RunPureTest.Bind(_Sc))
}


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