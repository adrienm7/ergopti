; tests/fixtures/personal_priority_paste_domain_body.ahk

; Native paste and the complete public handlers are real. Only the final draft
; publication and its deferred success callback are passive private destinations.
#Requires AutoHotkey v2.0

global _PPNC_State := {Publications: [], PasteCalls: 0}
global _PersonalEditorEntryBusy := false
global _PersonalEditorData := 0
global _PersonalEditorSection := "private"
global _PersonalEditorPrioCtrl := 0
LoggerWarn(*) => 0
LoggerError(*) => 0
LoggerDebug(*) => 0
LoggerInfo(*) => 0
t(Key) => Key
_PersonalEditorCompleteAddedEntry(*) => 0
_PersonalEditorSaveEntryCandidate(Window, List, Status, Candidate, *) {
 global _PPNC_State
 _PPNC_State.Publications.Push(Candidate)
 Status.Value := "published"
 return 1
}
_PPNC_Require(Condition, Message) {
 if !Condition
  throw Error(Message)
}
; Read native UTF-16 independently of the getter to identify the actual admission boundary.
; Only the child-owned Edit is queried; diagnostics never send input.
_PPNC_RawTextReceipt(Hwnd) {
 Reported := DllCall("User32\GetWindowTextLengthW", "Ptr", Hwnd, "Int")
 _PPNC_Require(Reported >= 0 && Reported <= 64, "The private diagnostic text must fit its bounded native receipt")
 Bytes := Buffer((Reported + 1) * 2, 0)
 Copied := DllCall("User32\GetWindowTextW", "Ptr", Hwnd, "Ptr", Bytes.Ptr, "Int", Reported + 1, "Int")
 _PPNC_Require(Copied >= 0 && Copied <= Reported, "The native text receipt cannot exceed its retained allocation")
 Units := ""
 loop Copied
  Units .= (A_Index == 1 ? "" : ",") . Format("{:04X}", NumGet(Bytes, (A_Index - 1) * 2, "UShort"))
 return {Length: Copied, Reported: Reported, Units: Units}
}
_PPNC_StringUnits(Value) {
 Text := String(Value), Units := ""
 _PPNC_Require(StrLen(Text) <= 64, "A private diagnostic value must stay bounded")
 loop StrLen(Text)
  Units .= (A_Index == 1 ? "" : ",") . Format("{:04X}", NumGet(StrPtr(Text), (A_Index - 1) * 2, "UShort"))
 return {Length: StrLen(Text), Units: Units}
}
_PPNC_ReadValueReceipt(Edit, Stage, Requested) {
 Before := _PPNC_RawTextReceipt(Edit.Hwnd)
 HasValue := false, GetterError := 0
 try {
  Value := Edit.Value
  HasValue := true
 } catch Any as ReadError
  GetterError := ReadError
 After := _PPNC_RawTextReceipt(Edit.Hwnd)
 RequestedUnits := _PPNC_StringUnits(Requested)
 ValueType := HasValue ? Type(Value) : "unavailable"
 ValueUnits := HasValue && (Value is String || Value is Number) ? _PPNC_StringUnits(Value) : {Length: -1, Units: "unavailable"}
 NumericValue := HasValue && Value is Number ? String(Value) : "not-number"
 FileAppend("OBSERVATION priority-native-value stage=" . Stage . " requested_units=" . RequestedUnits.Units
  . " before_reported=" . Before.Reported . " before_len=" . Before.Length . " before_units=" . Before.Units
  . " value_type=" . ValueType . " value_number=" . NumericValue . " value_len=" . ValueUnits.Length . " value_units=" . ValueUnits.Units
  . " after_reported=" . After.Reported . " after_len=" . After.Length . " after_units=" . After.Units
  . " getter_error=" . (IsObject(GetterError) ? Type(GetterError) : "none") . "`n", "*", "UTF-8-RAW")
 if IsObject(GetterError)
  throw GetterError
 return Value
}

_PPNC_Paste(Edit, Text, ExpectedNative) {
 global _PPNC_State
 Edit.Value := ""
 if Text == ""
  return
 Token := CB_TryBeginPasteTransaction("personal_priority_paste_fixture")
 _PPNC_Require(Token > 0, "A private paste must own its exact process-wide transaction")
 Saved := CB_SaveAll(), Sequence := 0
 try {
  _PPNC_Require(!(Saved is String && Saved == "__CB_SAVE_ERROR__"), "The complete original clipboard must be retained before publication")
  _PPNC_Require(CB_WriteTextWithReceipt(Text, &Sequence) && Sequence > 0, "Only an acknowledged native text publication may authorize paste")
  PreviousCritical := Critical("On")
  try {
   _PPNC_Require(CB_GetSequenceNumber() == Sequence, "A foreign later copy cannot supply the private paste")
   DllCall("User32\SendMessageW", "Ptr", Edit.Hwnd, "UInt", 0x0302, "Ptr", 0, "Ptr", 0, "Ptr")
   _PPNC_State.PasteCalls += 1
   NativeText := _PPNC_RawTextReceipt(Edit.Hwnd), ExpectedUnits := _PPNC_StringUnits(ExpectedNative)
   _PPNC_Require(NativeText.Length == ExpectedUnits.Length && NativeText.Units == ExpectedUnits.Units, "Raw UTF-16 must establish admission before the Value getter runs")
   PastedValue := _PPNC_ReadValueReceipt(Edit, "post-paste", Text)
   _PPNC_Require(PastedValue == ExpectedNative, "The genuine numeric Edit must retain exactly the declared admitted text")
  } finally Critical(PreviousCritical)
 } finally {
  if Sequence > 0 {
   Settled := CB_RestoreOwnedAllEventually(Saved, Sequence, Token, "personal_priority_paste_fixture")
   Started := A_TickCount
   while CB_HasRestoreDebtForOwner(Token) && TickElapsed64(Started) < 2000 {
    CB_RetryRestoreDebt()
    Sleep(10)
   }
   _PPNC_Require(!CB_HasRestoreDebtForOwner(Token), "The exact opaque clipboard restore must settle before testing a handler")
  } else if !CB_HasRestoreDebtForOwner(Token)
   CB_EndOwnedTransaction(Token)
 }
}
_PPNC_Run(Mode) {
 global _PPNC_State, _PersonalEditorData, _PersonalEditorPrioCtrl, _PersonalEditorSection
 Fields := StrSplit(Mode, "-")
 _PPNC_Require(Fields.Length == 2 && (Fields[1] == "add" || Fields[1] == "save") && (Fields[2] == "invalid" || Fields[2] == "current"), "Explicit public handler and input mode are required")
 Adding := Fields[1] == "add", Invalid := Fields[2] == "invalid"
 Window := Gui("", "Private personal priority paste")
 try {
  Trigger := Window.AddEdit("w180", "abcd")
  Output := Window.AddEdit("w180", "replacement")
  Checks := []
  loop 5
   Checks.Push(Window.AddCheckbox("", "private"))
  Checks[2].Value := 1
  Priority := Window.Add("Edit", "w64 h22 +Number +Limit3")
  Window.Add("UpDown", "Range0-100")
  Button := Window.AddButton("", "Private focus target")
  List := Window.AddListView("w240 r1", ["Trigger", "Output"])
  List.Add("", "abcd", "original")
  List.Modify(1, "Select Focus")
  Status := Window.AddText("w240", "initial")
  Window.Show("NA")
  _PersonalEditorPrioCtrl := Priority
  _PPNC_Require(WinGetClass("ahk_id " . Priority.Hwnd) == "Edit" && WinGetPID("ahk_id " . Priority.Hwnd) == ProcessExist(), "Only the child-owned native Edit can receive paste")
  _PPNC_Require((WinGetStyle("ahk_id " . Priority.Hwnd) & 0x2000) != 0, "The shipped ES_NUMBER style must be genuine")
  _PPNC_Require(DllCall("User32\SendMessageW", "Ptr", Priority.Hwnd, "UInt", 0x00D5, "Ptr", 0, "Ptr", 0, "Ptr") == 3, "The shipped native three-character limit must remain active")
  ; Genuine WM_PASTE rejects noninteger text before any public handler reads it.
  Vectors := Invalid ? [["abc", ""], ["1.5", ""]] : [["47", 47], ["", ""], ["999", 100], ["-3", 0]]
  for Vector in Vectors {
   Existing := Map("trigger", "abcd", "output", "original", "line_index", 17, "priority", 47)
   _PersonalEditorData := Map("sections", Map("private", Map("entries", Adding ? [] : [Existing])))
   Before := _PersonalEditorData, BeforeCount := _PPNC_State.Publications.Length
   Status.Value := "initial"
   ExpectedNative := Invalid ? "" : Vector[1]
   _PPNC_Paste(Priority, Vector[1], ExpectedNative)
   Button.Focus()
   FocusedValue := _PPNC_ReadValueReceipt(Priority, "post-focus", Vector[1])
   _PPNC_Require(FocusedValue == ExpectedNative, "The admitted native value must survive leaving the UpDown buddy")
   if Invalid {
    _PPNC_Require(_PPNC_State.Publications.Length == BeforeCount && Status.Value == "initial", "Rejected native input must not publish or invoke a form action")
    _PPNC_Require(_PersonalEditorData == Before && Existing["priority"] == 47 && Existing["output"] == "original", "Rejected native input must preserve the exact displayed model")
    FileAppend("OBSERVATION personal-priority mode=" . Mode . " text=" . Vector[1] . " rejected_before_handler=1 publications=0`n", "*", "UTF-8-RAW")
    continue
   }
   Failure := 0
   try {
    if Adding
     Result := _AddEntry(Window, List, Trigger, Output, Checks[1], Checks[2], Checks[3], Checks[4], Checks[5], Status)
    else
     Result := _SaveEntry(Window, List, Trigger, Output, Checks[1], Checks[2], Checks[3], Checks[4], Status)
   } catch Any as ErrorValue
    Failure := ErrorValue
   FileAppend("OBSERVATION personal-priority mode=" . Mode . " text=" . Vector[1] . " pastes=" . _PPNC_State.PasteCalls
    . " publications=" . (_PPNC_State.Publications.Length - BeforeCount) . " exception=" . (IsObject(Failure) ? Type(Failure) . ":" . Failure.Message : "none") . " status=" . Status.Value . "`n", "*", "UTF-8-RAW")
   _PPNC_Require(!IsObject(Failure), "Accepted native integer and inherited priority must complete without an exception")
   _PPNC_Require(_PersonalEditorData == Before, "The displayed model cannot change before the explicit private publication acknowledgement")
   _PPNC_Require(Before["sections"]["private"]["entries"].Length == (Adding ? 0 : 1), "Building a candidate cannot mutate the original collection")
   if !Adding
    _PPNC_Require(Existing["priority"] == 47 && Existing["output"] == "original" && Existing["line_index"] == 17, "The actual selected source entry cannot be changed before publication")
   _PPNC_Require(_PPNC_State.Publications.Length == BeforeCount + 1, "Every ordinary and inherited priority must still reach publication exactly once")
   Candidate := _PPNC_State.Publications[-1]
   Entry := Candidate["sections"]["private"]["entries"][1]
   _PPNC_Require(Type(Entry["priority"]) == Type(Vector[2]) && Entry["priority"] == Vector[2], "Accepted blank, integer and clamped priorities retain their original semantics")
   if !Adding
    _PPNC_Require(Entry["line_index"] == 17, "Saving preserves the exact selected source record")
  }
 } finally {
  _PersonalEditorPrioCtrl := 0
  Window.Destroy()
 }
}
try {
 _PPNC_Run(A_Args[1])
 FileAppend("PASS personal-priority-paste-domain " . A_Args[1] . "`n", "*", "UTF-8-RAW")
 ExitApp(0)
} catch Any as MainFailure {
 FileAppend("FAIL personal-priority-paste-domain " . MainFailure.Message . "`n" . MainFailure.Stack . "`n", "*", "UTF-8-RAW")
 ExitApp(1)
}
