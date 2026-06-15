#Requires AutoHotkey v2.0
#Include tests/test_framework.ahk
#Include lib/hotstrings/hotstring_engine.ahk
#Include lib/hotstrings/hotstring_engine_main.ahk

HSE_TestReset()
CreateCaseSensitiveHotstrings("*?", "a", "b")
HSE_FeedReset(true)

global HSE_Buffer
HSE_Buffer .= "A"
Char := "A"
JustTypedChar := "A"

BufLen := StrLen(HSE_Buffer)
MaxSuffix := Min(BufLen, HSE_MaxStarTriggerLen)
FileAppend("HSE_Buffer: " HSE_Buffer "`n", "debug_out.txt")
FileAppend("BufLen: " BufLen "`n", "debug_out.txt")
FileAppend("HSE_MaxStarTriggerLen: " HSE_MaxStarTriggerLen "`n", "debug_out.txt")
FileAppend("MaxSuffix: " MaxSuffix "`n", "debug_out.txt")

loop MaxSuffix {
    Suffix := SubStr(HSE_Buffer, -A_Index)
    LowerSuffix := StrLower(Suffix)
    FileAppend("Suffix: " Suffix ", LowerSuffix: " LowerSuffix "`n", "debug_out.txt")
    if HSE_StarByTriggerCI.Has(LowerSuffix) {
        FileAppend("FOUND IN CI MAP!`n", "debug_out.txt")
        for _, Spec in HSE_StarByTriggerCI[LowerSuffix] {
            Beats := _HSE_Beats(Spec, "")
            FileAppend("Beats: " Beats "`n", "debug_out.txt")
            WordOk := _HSE_WordBoundaryAllows(HSE_Buffer, Spec)
            FileAppend("WordOk: " WordOk "`n", "debug_out.txt")
        }
    } else {
        FileAppend("NOT IN CI MAP!`n", "debug_out.txt")
        for k, v in HSE_StarByTriggerCI {
            FileAppend("Key in CI: " k "`n", "debug_out.txt")
        }
    }
}

M := HSE_FindMatchAtEnd("A")
FileAppend("Match: " (M ? M.Trigger : "NULL") "`n", "debug_out.txt")
