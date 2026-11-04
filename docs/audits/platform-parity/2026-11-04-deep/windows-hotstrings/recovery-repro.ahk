; Native policy reproduction. Not executed in the Linux audit environment.
#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\..\..\ergopti\static\ergopti_plus\_shared\modules\hotstrings\user_code.ahk

owner := UserHotstringOwner(Map("capture", (*) => Map(), "current", (*) => true,
    "invoke", (*) => false, "commit", (*) => true, "report", (*) => true))
rule := Map("id", "clock", "suffix", "@clock", "preview", "Current time", "callback", (*) => "12:34")
source := Map("path", "personal_dynamic_hotstrings.ahk", "present", true, "content", "valid fixture")
if !owner.SetEnabled(true)
    throw Error("Initial enable was refused")
; The real reload failure calls this, leaving the persisted user request enabled.
owner.RefuseSource("source-load-failed")
; The real UserHotstringsReload Done callback calls Reload, then clears the problem.
if !owner.Reload([rule], source)
    throw Error("Repaired metadata was refused")
if !owner.ready || owner.enabled || owner.Find("@clock") is Map
    throw Error("Expected audited failed-recovery posture changed")
FileAppend("Reproduced: repaired metadata ready=1, enabled=0, Find(@clock)=false`n", "*")
; This is the operation the Lua driver applies after a successful reload.
if !owner.SetEnabled(true) || !(owner.Find("@clock") is Map)
    throw Error("Restoring the requested admission did not restore matching")
FileAppend("Control: restoring desired enable makes Find(@clock) succeed`n", "*")
