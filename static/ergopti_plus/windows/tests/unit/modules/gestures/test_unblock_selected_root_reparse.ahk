; tests/unit/modules/gestures/test_unblock_selected_root_reparse.ahk

#Requires AutoHotkey v2.0

_SARR_SelectedRoot(Reparse) {
 Root := A_Temp . "\ergopti_selected_root_reparse_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(100000, 999999)
 Created := FSCreateDirectoryExclusiveStrict(Root)
 AssertTrue(Created is Integer && Created == 1, "The fixture root must be exclusively owned")
 Link := Root . "\selected-link", Outside := Root . "\outside", FilePath := Outside . "\owned.txt"
 try {
  DirCreate(Outside)
  FileAppend("owned external sibling", FilePath)
  FileAppend("[ZoneTransfer]`r`nZoneId=3`r`n", FilePath . ":Zone.Identifier")
  AssertTrue(_SAJ_StreamExists(FilePath), "The exact owned target begins with its native zone stream")
  Code := RunWait('"' . A_ComSpec . '" /D /C mklink /J "' . Link . '" "' . Outside . '"', , "Hide")
  AssertEqual(0, Code, "A genuine owned NTFS junction must be created")
  AssertTrue(InStr(FileExist(Link), "L") > 0, "The selected root must itself be a native reparse point")
  AssertEqual("owned external sibling", FileRead(Link . "\owned.txt"), "The link must actually resolve to the separate private target")
  Lines := _SAJ_RunIsolated(_SAJ_NativeControl(Reparse ? Link : Outside))
  Remaining := _SAJ_StreamExists(FilePath), Errors := 0
  for Line in Lines
   Errors += InStr(Line, "could not be processed") ? 1 : 0
  _TestAppendProgress("# RECEIPT selected-root-reparse selected_link=" . Reparse . " target_stream=" . Remaining . " errors=" . Errors)
  AssertEqual(Reparse, Remaining, "A selected reparse root cannot lend unblock authority to its external target; a genuine ordinary root must still work")
  if Reparse
   AssertEqual(1, Errors, "Refused root traversal must report incomplete processing")
 } finally {
  if DirExist(Link)
   DirDelete(Link)
  DirDelete(Root, true)
 }
}
Test("Unblock selected root: native junction is refused (unblock-selected-root-reparse)", _SARR_SelectedRoot.Bind(true))
Test("Unblock selected root: native ordinary folder works (unblock-selected-root-reparse)", _SARR_SelectedRoot.Bind(false))
