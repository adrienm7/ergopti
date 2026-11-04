"""Source-only evidence and unexecuted recording-boundary AHK probe generator."""

from pathlib import Path
import hashlib, re, subprocess

root = Path("/workspace/ergopti")
out = Path("/workspace/scratch/parity-flows/windows-config/probes")
sha = "213d65af24d2aa4845ba47743c9bab6787b61964"
assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip() == sha
path = root / "static/ergopti_plus/windows/ui/wpm/wpm_config.ahk"
src = path.read_text(encoding="utf-8-sig")
body = re.search(r"^_WPMWidget_StorePosition\([^\n]+\) \{\n.*?^\}", src, re.M | re.S).group()
rollback = body.split("if !Stored {", 1)[1].split("return ConfigReportPersistenceFailure", 1)[0]
assert "try Store.Call(WPMWidgetConst.STORE_X, PreviousX)" in rollback
assert "try Store.Call(WPMWidgetConst.STORE_Y, PreviousY)" in rollback
assert "if " not in rollback and ":=" not in rollback
assert body.index("STORE_X, TargetX") < body.index("STORE_Y, TargetY")
print("WCF-001: actual paired storage writes are separate; both rollback receipts discarded")
print("Actual owner body sha256=" + hashlib.sha256(body.encode()).hexdigest())
probe = """; UNEXECUTED isolated native probe; no Registry or installed config access.
; Owner body below is verbatim production source. Store is a recording port.
#Requires AutoHotkey v2.0
class WPMWidget {
    static pos_x := 10
    static pos_y := 20
}
class WPMWidgetConst {
    static STORE_X := "x"
    static STORE_Y := "y"
}
global ProbeDisk := Map("x", 10, "y", 20), ProbeCalls := [], ProbeFailures := 0
ProbeStore(Key, Value) {
    global ProbeDisk, ProbeCalls
    ProbeCalls.Push([Key, Value])
    if ProbeCalls.Length != 1
        return false
    ProbeDisk[Key] := Value
    return true
}
global ProbeNested := false
ProbeNestedStore(Key, Value) {
    global ProbeDisk, ProbeNested
    ProbeDisk[Key] := Value
    if !ProbeNested {
        ProbeNested := true
        if !_WPMWidget_StorePosition(300, 400, ProbeNestedStore)
            throw Error("Nested position was unexpectedly refused")
    }
    return true
}
_WPMWidget_StoreSet(*) => false
ConfigReportPersistenceFailure(Context, NotifyFn := 0, Detail := "", StateUnchanged := true) {
    global ProbeFailures
    ProbeFailures += 1
    return false
}
"""
probe += body + "\n\n"
probe += """Result := _WPMWidget_StorePosition(100, 200, ProbeStore)
if Result || ProbeDisk["x"] != 100 || ProbeDisk["y"] != 20
    throw Error("Audited failed-compensation posture changed")
if WPMWidget.pos_x != 10 || WPMWidget.pos_y != 20 || ProbeFailures != 1 || ProbeCalls.Length != 4
    throw Error("The actual owner must keep RAM old and report its primary failure")
FileAppend("OBSERVED false result; RAM=(10,20); durable=(100,20); rollback receipts ignored`n", "*")
ProbeDisk := Map("x", 10, "y", 20)
WPMWidget.pos_x := 10, WPMWidget.pos_y := 20
if !_WPMWidget_StorePosition(100, 200, ProbeNestedStore)
    throw Error("Outer position was unexpectedly refused")
if WPMWidget.pos_x != 100 || WPMWidget.pos_y != 200 || ProbeDisk["x"] != 300 || ProbeDisk["y"] != 200
    throw Error("Audited reentrant mixed-coordinate posture changed")
FileAppend("OBSERVED both writes succeed; RAM=(100,200); durable=(300,200); nested position interleaves`n", "*")
ExitApp()
"""
(out / "wpm-position-rollback-native.ahk").write_text(probe, encoding="utf-8-sig", newline="\n")
print("Generated unexecuted probe: wpm-position-rollback-native.ahk")
print("Audited SHA=" + sha)
