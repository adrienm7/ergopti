#Requires AutoHotkey v2.0
#Include lib/hotstrings/hotstring_engine.ahk
#Include lib/hotstrings/hotstring_engine_main.ahk

try {
    HSE_RegistryClear()
    CreateCaseSensitiveHotstrings("*?", "a", "b")

    global HSE_Buffer := "A"

    M := HSE_FindMatchAtEnd("A")

    if M {
        FileAppend("MATCH FOUND: " M.Trigger "`n", "debug2.txt")
    } else {
        FileAppend("NO MATCH FOUND!`n", "debug2.txt")
        
        FileAppend("HSE_MaxStarTriggerLen: " HSE_MaxStarTriggerLen "`n", "debug2.txt")
        FileAppend("HSE_StarByTriggerCI count: " HSE_StarByTriggerCI.Count "`n", "debug2.txt")
        for k, v in HSE_StarByTriggerCI {
            FileAppend("CI Key: " k "`n", "debug2.txt")
            for i, Spec in v {
                FileAppend("  Spec " i ": " Spec.Trigger ", InWord: " Spec.InWord "`n", "debug2.txt")
            }
        }
    }
} catch Error as e {
    FileAppend("ERROR: " e.Message "`nLine: " e.Line "`n", "debug2.txt")
}
ExitApp
