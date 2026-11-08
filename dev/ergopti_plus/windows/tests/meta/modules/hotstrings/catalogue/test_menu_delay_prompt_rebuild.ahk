; tests/meta/modules/hotstrings/catalogue/test_menu_delay_prompt_rebuild.ahk

; ==============================================================================
; MODULE: Tray delay prompts re-register hotstrings after persisting
; DESCRIPTION:
; Hotstring expansion delays are baked into each spec at REGISTRATION time
; (LoadHotstringsSection folds the resolved delay into the spec meta). The tray
; delay prompts (_HS_PromptDefaultDelay / _HS_PromptCategoryDelay for magickey,
; autocorrection, dynamichotstrings, and the base expansion delay) ended at HotstringsSetOverride, which
; only bumps the resolve generation and writes the override file — nothing
; re-registered, so every live spec kept its old delay until a full Reload or an
; unrelated section toggle. Each override write must re-register live, the same path
; a section toggle uses. (F32, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_MDPR_OverrideWriteRebuildsLive(FuncName, Helper) {
	Body := _DriverFuncBody(FuncName)
	Assert(Body != "", FuncName . " must exist in ui/menu/menu_hotstrings.ahk")
	Assert(InStr(Body, Helper . "(") > 0,
		FuncName . " must route persistence and live rebuilding through the shared strict-result helper")
}

; Both persistence helpers accept only a strict successful write, then hand the
; live re-registration to the one rebuild owner.
_MDPR_HelperRebuildsAfterStrictWrite(Helper, Writer) {
	Commit := _DriverFuncBody(Helper)
	Assert(Commit != "", Helper . " must exist in ui/menu/menu_hotstrings.ahk")
	SetPos := InStr(Commit, Writer . "(")
	StrictPos := InStr(Commit, "Committed is Integer")
	RebuildPos := InStr(Commit, "_HS_RebuildAfterDelayChange(")
	Assert(SetPos > 0, Helper . " must persist through " . Writer)
	Assert(StrictPos > SetPos and RebuildPos > StrictPos,
		Helper . " must accept only a strict successful persist BEFORE rebuilding live hotstrings; a refused write must never rebuild from stale state")
}

_MDPR_BothDelayPromptsRebuild() {
	_MDPR_OverrideWriteRebuildsLive("_HS_PromptDefaultDelay", "_HS_CommitBaseDelay")
	_MDPR_OverrideWriteRebuildsLive("_HS_PromptCategoryDelay", "_HS_CommitDelayOverride")
	_MDPR_HelperRebuildsAfterStrictWrite("_HS_CommitDelayOverride", "HotstringsSetOverride")
	_MDPR_HelperRebuildsAfterStrictWrite("_HS_CommitBaseDelay", "HotstringsSetBaseDelay")

	Rebuild := _DriverFuncBody("_HS_RebuildAfterDelayChange")
	Assert(Rebuild != "", "_HS_RebuildAfterDelayChange must exist in ui/menu/menu_hotstrings.ahk")
	Assert(InStr(Rebuild, "RebuildHotstringsLive()") > 0,
		"the rebuild owner must re-register the hotstrings live")
}
Test("menu: hotstring delay prompts rebuild only after strict durable success",
	_MDPR_BothDelayPromptsRebuild)


_MDPN_Source() {
 global _DriverDir
 Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n"
 NumberOwner := _DriverProductionFileForSymbol("NumberTryParseInputInteger", _DriverDir)
 AssertTrue(NumberOwner != "", "The canonical integer parser must have its genuine owner")
 Source .= "#Include " . NumberOwner . "`n"
 for Symbol in ["_HS_PromptDefaultDelay", "_HS_PromptCategoryDelay", "_HS_PromptPersonalFileField"] {
  Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
  AssertTrue(Owner != "", "Every prompt must resolve its actual production owner")
  Text := FSReadStrict(Owner)
  Body := _DriverExtractFunctionBody(&Text, Symbol)
  AssertTrue(Body != "", "Every production prompt body must be copied whole and unmodified")
  Source .= Body . "`n"
 }
 return Source . "#Include " . _DriverDir . "\tests\fixtures\menu_numeric_prompt_domain_body.ahk`n"
}
_MDPN_Done(State, Code, Output, ErrorText) {
 State.Calls += 1, State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}
_MDPN_Case(Mode) {
 global _DriverDir
 static Debt := 0
 AssertFalse(IsObject(Debt), "A retained child prevents another timer case")
 Root := A_Temp . "\ergopti_menu_numeric_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
 FSCreateDirectoryExclusiveStrict(Root)
 State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
 PreviousCritical := Critical("Off")
 try {
  Script := Root . "\subject.ahk"
  AssertEqual(1, FSWriteCreateDurable(Script, Chr(0xFEFF) . _MDPN_Source()))
  _TestPrint("# menu-numeric-prompt-domain source=" . CryptoSha256Bytes(FSReadBytesStrict(Script)))
  Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode, Root, _DriverDir . "\..\_shared"], _MDPN_Done.Bind(State))
  AssertTrue(Handle.start(), "The exact private timer child must really start")
  Started := A_TickCount
  while !State.Calls && TickElapsed64(Started) < 15000 {
   _SR_TreePoll()
   Sleep(10)
  }
  _TestPrint("# menu-numeric-prompt-domain mode=" . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
  AssertEqual(1, State.Calls)
  AssertEqual("", State.ErrorText)
  AssertEqual(0, State.Code, State.Output)
  AssertContains(State.Output, "PASS menu-numeric-prompt-domain " . Mode)
 } catch Any as Failure
  Primary := Failure
 try {
  Receipt := IsObject(Handle) ? Handle.terminate() : 1
  Retired := Receipt is Integer && Receipt == 1
 } catch Any as Failure {
  if !IsObject(Primary)
   Primary := Failure
 }
 try {
  if !Retired
   Debt := {Root: Root, Handle: Handle}
  else if !IsObject(Primary)
   DirDelete(Root, true)
 } finally Critical(PreviousCritical)
 if IsObject(Primary)
  throw Primary
 AssertTrue(Retired, "The precise native process tree must retire before private cleanup")
}
for _MDPN_Mode in ["base", "category", "personal-delay", "personal-priority"]
 Test("Hotstring menu numeric prompt: " . _MDPN_Mode . " rejects integer aliases (menu-numeric-prompt-domain)", _MDPN_Case.Bind(_MDPN_Mode))
