#Requires AutoHotkey v2.0
#Include tests/test_stubs.ahk
#Include lib/hotstrings/hotstring_engine.ahk
#Include lib/hotstrings/hotstring_engine_main.ahk

try {
    HSE_RegistryClear()

    ; Create the meta manually to match Conform exactly
    ConformMeta := { Category: "", Section: "", Priority: 50, IsRepeat: false, CaseConform: true, ConformOneChar: true, InWord: true }

    ; Pass Abbrev="a" as it is done in CreateCaseSensitiveHotstrings
    HSE_Register("*?", "a", 0, ConformMeta)

    HSE_Buffer := "A"
    HSE_StartIsWordBoundary := true

    Match := HSE_FindMatchAtEnd("A")

    if Match {
        FileAppend("Match found! Trigger: " Match.Trigger "`n", "debug6.txt")
    } else {
        FileAppend("Match is NULL!`n", "debug6.txt")
        FileAppend("MaxStarTriggerLen: " HSE_MaxStarTriggerLen "`n", "debug6.txt")
        FileAppend("Has 'a' in CI: " HSE_StarByTriggerCI.Has("a") "`n", "debug6.txt")
        
        if HSE_StarByTriggerCI.Has("a") {
            for _, Spec in HSE_StarByTriggerCI["a"] {
                FileAppend("  Spec Trigger: " Spec.Trigger ", Length: " Spec.Length ", InWord: " Spec.InWord "`n", "debug6.txt")
                AnsBeats := _HSE_Beats(Spec, "")
                FileAppend("  _HSE_Beats(Spec, `"`"): " AnsBeats "`n", "debug6.txt")
                AnsWord := _HSE_WordBoundaryAllows("A", Spec)
                FileAppend("  _HSE_WordBoundaryAllows('A', Spec): " AnsWord "`n", "debug6.txt")
            }
        }
    }
} catch Error as e {
    FileAppend("Runtime Error: " e.Message "`nLine: " e.Line "`n", "debug6.txt")
}
ExitApp
