; tests/fixtures/menu_numeric_prompt_domain_body.ahk

; Only the InputBox display and publication destinations are private ports.
; The unmodified production prompt bodies and canonical parser run in this child.
#Requires AutoHotkey v2.0

global _MDPN_World := {Answer: {Result: "OK", Value: ""}, Calls: [], Prompts: 0, Notices: 0}
t(Key) => Key
LoggerWarn(*) => 0
Ui_InputBox(*) {
 global _MDPN_World
 _MDPN_World.Prompts += 1
 return _MDPN_World.Answer
}
Ui_MsgBox(*) {
 global _MDPN_World
 _MDPN_World.Notices += 1
}
HotstringsBaseDelay() => 0.75
; The base delay's manifest default, which a blank answer resets to (PCK-13).
ManifestDefaultFor(Path) {
 _MDPN_Require(Path == ConfigKey.HOTSTRINGS_EXPANSION_DELAY, "Only the base delay reads a manifest default")
 return 0.5
}
HotstringsResolve(*) => {HasOverride: true, Delay: 0.321}
_HS_CommitBaseDelay(Value) {
 global _MDPN_World
 _MDPN_World.Calls.Push({Field: "delay", Value: Value})
 return true
}
_HS_CommitDelayOverride(Category, Value, *) {
 global _MDPN_World
 _MDPN_Require(Category == "magickey", "The original category must reach publication")
 return _HS_CommitBaseDelay(Value)
}
_HS_ClearDelayOverride(Category, *) {
 global _MDPN_World
 _MDPN_Require(Category == "magickey", "The original category must reach its removal")
 _MDPN_World.Calls.Push({Field: "delay", Value: "inherit"})
 return true
}
class _MDPN_Owner {
 __New() => this.source := Map("label", "Private personal source")
 Resolve(*) => {Delay: 0.321, Priority: 47, Color: "123456"}
 Commit(Section, Field, Value) {
  global _MDPN_World
  _MDPN_Require(Section == "private", "The original personal section must reach publication")
  _MDPN_World.Calls.Push({Field: Field, Value: Value})
  return true
 }
}
_MDPN_Require(Condition, Message) {
 if !Condition
  throw Error(Message)
}
_MDPN_Run(Mode) {
 if Mode == "base"
  return _HS_PromptDefaultDelay()
 if Mode == "category"
  return _HS_PromptCategoryDelay("magickey", "private")
 return _HS_PromptPersonalFileField(_MDPN_Owner(), "private", Mode == "personal-delay" ? "delay" : "priority")
}
try {
 Mode := A_Args[1]
 _MDPN_Require(Mode == "base" || Mode == "category" || Mode == "personal-delay" || Mode == "personal-priority", "Explicit prompt mode required")
 ExpectedField := Mode == "personal-priority" ? "priority" : "delay"
 for Raw in ["3", "0003", "0"] {
  _MDPN_World.Answer := {Result: "OK", Value: Raw}
  Before := _MDPN_World.Calls.Length
  _MDPN_Run(Mode)
  _MDPN_Require(_MDPN_World.Calls.Length == Before + 1, "Ordinary, padded and zero values must still publish once")
  LastCall := _MDPN_World.Calls[-1]
  Expected := ExpectedField == "priority" ? Integer(Raw) : Integer(Raw) / 1000
  _MDPN_Require(LastCall.Field == ExpectedField && LastCall.Value == Expected, "The original numeric intention and field must survive")
 }
 _MDPN_World.Answer := {Result: "Cancel", Value: "3"}
 Before := _MDPN_World.Calls.Length
 _MDPN_Run(Mode)
 _MDPN_Require(_MDPN_World.Calls.Length == Before, "Cancel must publish nothing")
 ; A blank base delay resets to its default (PCK-13, 2026-11-21); a blank
 ; override removes itself, so the inherited value applies again (maintainer
 ; decision of 2026-11-22): the category clears its delay, a personal file
 ; commits the empty value its owner removes.
 _MDPN_World.Answer := {Result: "OK", Value: ""}
 Before := _MDPN_World.Calls.Length
 _MDPN_Run(Mode)
 _MDPN_Require(_MDPN_World.Calls.Length == Before + 1, "A blank answer must publish once")
 Blank := _MDPN_World.Calls[-1]
 _MDPN_Require(Blank.Field == ExpectedField, "A blank answer keeps its field")
 if Mode == "base"
  _MDPN_Require(Blank.Value == 0.5, "A blank base delay must publish its default")
 else if Mode == "category"
  _MDPN_Require(Blank.Value == "inherit", "A blank category delay must remove its override")
 else
  _MDPN_Require((Blank.Value is String) && Blank.Value == "", "A blank personal field must remove its value")
 for Raw in ["18446744073709551619", "00018446744073709551619", "9223372036854775808"] {
  _MDPN_World.Answer := {Result: "OK", Value: Raw}
  Before := _MDPN_World.Calls.Length
  _MDPN_Run(Mode)
  FileAppend("OBSERVATION menu-numeric mode=" . Mode . " raw=" . Raw . " publications=" . (_MDPN_World.Calls.Length - Before) . "`n", "*", "UTF-8-RAW")
  _MDPN_Require(_MDPN_World.Calls.Length == Before, "Invalid magnitude cannot alias an ordinary durable publication argument")
 }
 _MDPN_Require(_MDPN_World.Prompts == 8, "All eight cases must traverse the actual prompt display port")
 FileAppend("PASS menu-numeric-prompt-domain " . Mode . "`n", "*", "UTF-8-RAW")
 ExitApp(0)
} catch Any as MainFailure {
 FileAppend("FAIL menu-numeric-prompt-domain " . MainFailure.Message . "`n" . MainFailure.Stack . "`n", "*", "UTF-8-RAW")
 ExitApp(1)
}
