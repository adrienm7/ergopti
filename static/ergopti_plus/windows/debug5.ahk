#Requires AutoHotkey v2.0
#Include tests/test_framework.ahk
#Include lib/hotstrings/hotstring_engine.ahk
#Include lib/hotstrings/hotstring_engine_main.ahk

try {
    HSE_TestReset()
    CreateCaseSensitiveHotstrings("*?", "a", "b")

    For _, Spec in HSE_StarByTriggerCI["a"] {
        FileAppend("InWord: " Spec.InWord ", IsRepeat: " Spec.IsRepeat "`n", "debug5.txt")
    }
} catch Error as e {
    FileAppend("Error: " e.Message "`n", "debug5.txt")
}
ExitApp
