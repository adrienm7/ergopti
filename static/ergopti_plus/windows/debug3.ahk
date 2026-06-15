#Requires AutoHotkey v2.0
#Include tests/test_framework.ahk

try {
    Cand := { Length: 1 }
    Best := ""
    FileAppend("Cand.Length > Best.Length: " (Cand.Length > Best.Length) "`n", "debug9.txt")
} catch Error as e {
    FileAppend("Error: " e.Message "`n", "debug9.txt")
}
ExitApp
