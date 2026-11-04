"""Source-derived checks and unexecuted isolated AHK probe generation.

No desktop, clipboard, user configuration or production files are accessed.
This is source evidence, not AHK execution.
"""

from pathlib import Path
import hashlib
import re
import subprocess

ROOT = Path("/workspace/ergopti")
OUT = Path("/workspace/scratch/parity-flows/windows-clipboard/probes")
BASE = ROOT / "static/ergopti_plus/windows"
SHA = "213d65af24d2aa4845ba47743c9bab6787b61964"
assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip() == SHA
source = (BASE / "infra/hotstrings/hotstring_send.ahk").read_text(encoding="utf-8-sig")


def function(name):
    # Owner definitions end at a column-zero closing brace; all selected owners
    # use indented nested blocks. Preserve the exact source body otherwise.
    match = re.search(r"^" + re.escape(name) + r"\([^\n]*\) \{\n.*?^\}", source, re.M | re.S)
    assert match is not None, name
    return match.group()


guard = function("_SelectionCaptureStartCurrent")
assert "A_IsSuspended" in guard and "_SelectionCaptureNextId" in guard
assert "physical_generation" not in guard and "foreground" not in guard
start = function("GetSelectionAsync")
assert (
    start.index("GenerationFn.Call()")
    < start.index("SaveFn.Call()")
    < start.index("ClearFn.Call()")
    < start.index("SendFn.Call()")
)
assert "generation_fn" not in start.split("SaveFn.Call()", 1)[1]
print(
    "WCP-001: startup snapshots physical generation before Save; later startup guards omit it and foreground"
)

send = function("SendInstant")
assert "OldClipboard := CB_SaveAll()" in send
assert "A_IsSuspended" not in send and "KS_GetPhysicalInputGeneration" not in send
assert "WinExist(" not in send and "WIGetForegroundHwnd" not in send
after_save = send.split("OldClipboard := CB_SaveAll()", 1)[1]
assert "CB_WriteTextWithReceipt" in after_save and 'SendInput(Prefix . "^v")' in after_save
print("WCP-002: SendInstant has no target/pause admission after its yielding clipboard snapshot")

probe = """; Source-derived isolated native probe. NOT EXECUTED in Linux audit.
; Native SendInput and every clipboard boundary are recording functions only.
#Requires AutoHotkey v2.0
#SingleInstance Off
global _SendHook := 0, SEND_INSTANT_PASTE_DELAY_MS := 10000
global ProbeWrites := 0, ProbeSends := 0
CB_TryBeginPasteTransaction(*) => 1
CB_EndOwnedTransaction(*) => true
CB_IsBusy() => false
CB_HasImage() => false
CB_SaveAll() {
    Suspend(true)
    return "opaque original snapshot"
}
CB_WriteTextWithReceipt(Text, &OwnedSequence) {
    global ProbeWrites
    ProbeWrites += 1
    OwnedSequence := 42
    return true
}
ProbeSendInput(Keys) {
    global ProbeSends
    ProbeSends += 1
}
_SendInstantReport(*) => true
_SendInstant_RestoreClipboard(*) => true
LoggerDebug(*) => true
LoggerWarn(*) => true
LoggerError(*) => true
"""
probe += function("_SendVerdictSucceeded") + "\n\n"
probe += send.replace("SendInput(", "ProbeSendInput(") + "\n\n"
probe += """Suspend(false)
Result := SendInstant("synthetic selection")
if !A_IsSuspended || !Result || ProbeWrites != 1 || ProbeSends != 1
    throw Error("Audited stale-output observation changed")
FileAppend("OBSERVED suspended=1 writes=1 sends=1 result=1; no native clipboard/input invoked`n", "*")
ExitApp()
"""
path = OUT / "sendinstant-pause-native-probe.ahk"
path.write_text(probe, encoding="utf-8-sig", newline="\n")
print("UNEXECUTED AHK probe generated: " + str(path))
print("Exact SendInstant source sha256=" + hashlib.sha256(send.encode()).hexdigest())
print("Audited SHA=" + SHA)
