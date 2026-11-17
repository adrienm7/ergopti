; tests/unit/gestures/engine/test_unblock_selected_file_reparse.ahk

#Requires AutoHotkey v2.0

#Include %A_LineFile%\..\..\..\..\fixtures\host_capability_probes.ahk

_SAFR_SelectedFile(Reparse) {
 Root := A_Temp . "\ergopti_selected_file_reparse_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(100000, 999999)
 Created := FSCreateDirectoryExclusiveStrict(Root)
 AssertTrue(Created is Integer && Created == 1, "The fixture root must be exclusively owned")
 Link := Root . "\selected-link.txt", Outside := Root . "\outside", Target := Outside . "\owned.txt"
 try {
  DirCreate(Outside)
  FileAppend("owned external sibling", Target)
  FileAppend("[ZoneTransfer]`r`nZoneId=3`r`n", Target . ":Zone.Identifier")
  AssertTrue(_SAJ_StreamExists(Target), "The exact owned target begins with its native zone stream")
  ; Both paths are private. The flag permits Developer Mode when available;
  ; an actual privilege refusal is setup failure, never a product observation.
  Native := DllCall("Kernel32\CreateSymbolicLinkW", "Str", Link, "Str", Target, "UInt", 2, "UChar")
  NativeError := A_LastError
  _TestAppendProgress("# RECEIPT selected-file-reparse setup=" . Native . " error=" . NativeError)
  ; Both cases share this setup, so an account without the privilege runs neither.
  TestRequireHostCapability(TestFileSymlinkReceipt.Bind(Native, NativeError))
  AssertTrue(Native != 0, "A genuine owned file symlink is required before the action can be qualified")
  Attributes := DllCall("Kernel32\GetFileAttributesW", "Str", Link, "UInt")
  AssertTrue(Attributes != 0xFFFFFFFF && Attributes & 0x400, "The selected file must itself carry FILE_ATTRIBUTE_REPARSE_POINT")
  AssertFalse(Attributes & 0x10, "This sibling is a file symlink, not a directory junction")
  AssertEqual("owned external sibling", FileRead(Link), "The link must resolve to the separate private target")
  Lines := _SAJ_RunIsolated(_SAJ_NativeControl(Reparse ? Link : Target))
  Remaining := _SAJ_StreamExists(Target), Errors := 0
  for Line in Lines
   Errors += InStr(Line, "could not be processed") ? 1 : 0
  _TestAppendProgress("# RECEIPT selected-file-reparse selected_link=" . Reparse . " target_stream=" . Remaining . " errors=" . Errors)
  AssertEqual(Reparse, Remaining, "A directly selected file reparse point cannot lend unblock authority to its external target; an ordinary selected file must still work")
  if Reparse
   AssertEqual(1, Errors, "Refused file reparse mutation must report incomplete processing")
 } finally {
  if FileExist(Link)
   FileDelete(Link)
  DirDelete(Root, true)
 }
}
Test("Unblock selected file: native symlink is refused (unblock-selected-file-reparse)", _SAFR_SelectedFile.Bind(true))
Test("Unblock selected file: native ordinary file works (unblock-selected-file-reparse)", _SAFR_SelectedFile.Bind(false))
