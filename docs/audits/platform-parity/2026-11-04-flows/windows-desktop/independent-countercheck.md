# Independent bounded Windows fixed-system-action countercheck

Audited source HEAD `213d65af24d2aa4845ba47743c9bab6787b61964` on 2026-11-04. Read-only countercheck limited to `quit_frontmost_app` and `empty_trash`, their SystemControl adapter, dispatch containment and possible existing worker monitoring. No AHK, Windows, native messages, Recycle Bin, user input or user-state mutation was executed. Parent-supplied `worker-proof.py`/`.json` was inspected, not rerun here.

## WDS-001: retain with narrowly stated diagnostic failure

The source claim survives countercheck. `adapters/system_control.ahk:117-119` returns the boolean result of native PostMessageW; ordinary refusal is false and need not throw. `modules/gestures/system_actions.ahk:369-375` adds accepted posts to `Closed`, then emits only an informational count. If all enumerated ordinary-process windows refuse, the observable log says `Asked process ... to close its 0 window(s).` No error or warning identifies rejected WM_CLOSE requests. In the shared-host branch at `:361-365`, the same false contract explicitly produces LoggerError. Generic dispatch cannot repair the difference: `_GestureRunSystemAction:109-120` catches exceptions only; `_GestureRunAction` in `config.ahk:787-820` catches exceptions and times dispatch, without inspecting or promoting individual false native receipts.

Qualifications required in the integrated finding:

- Do **not** say the log falsely claims the application closed. Its wording says _asked_, and 0 is visible to a reader. The defect is failure to diagnose known rejected requests, compared with the explicit false-reporting contract and sibling branch.
- Accepted WM_CLOSE also does not prove quit completion: save prompts, refusal by the application, or unresponsive application processing are outside this finding. No worker/process-exit monitoring is required merely to repair the false receipt.
- All-false due to elevated target/UIPI is a valid native scenario, but it was **not reproduced on Windows** here. Zero enumerated windows is a separate possible reason for 0 and should not be called native refusal without an attempted false post. Mixed true/false is likewise underdiagnosed, but only the exact all-false source path is the retained parent candidate.
- Native graceful WM_CLOSE and per-window shared-host protection are explicit product policy. That does not justify downgrading false to unqualified informational-only output. Adapter header `:24-26` explicitly says failures are returned/thrown and logged by the module.

Current tests in `tests/unit/modules/gestures/test_system_actions.ahk:273-340` verify target enumeration/shared-host policy with the default `_SysActionsFake.PostClose` success recorder. They do not establish false-result diagnostics. No executable native or AHK check was added by this review.

## WDS-002: retain as lost asynchronous failure receipt, not false success

The source claim survives countercheck. `system_actions.ahk:57` runs `powershell.exe -NoProfile -NonInteractive -Command "Clear-RecycleBin -Force -ErrorAction Stop"`; `GestureSysEmptyTrash:448-457` launches hidden and does not retain its returned PID. `SystemControl.Launch:99-103` uses AHK Run and returns immediately with PID, not worker exit. The handler catch therefore covers a refused **launch**, not a later Clear-RecycleBin error. The only ordinary log says `Emptying the Recycle Bin.` It is progressive/start acknowledgement, **not a completed-success claim**.

The explicit rationale is bounded driver-thread work: module header `:18-21`, constant comment `:55-56` and adapter header `:20-23` deliberately move a potentially long bin operation to a process. That is a sound documented reason for asynchronous execution; it does not document a deliberate policy of dropping execution errors. The header promise that failures are reported remains stronger than the actual worker receipt.

Counterchecks:

- Confirmation at `config.ahk:606-645` authorizes this action, but does not establish native completion. Registered runner `system_actions.ahk:103,167-176` defers it; generic catches see no child exit exception after successful Run.
- Repo production search found real exit supervision in `adapters/shell_runner.ahk` (including GetExitCodeProcess), and a separate touchpad-restart job/result poll in `modules/gestures/config.ahk:900-959`. Neither wraps `SystemControl.Launch` nor receives this discarded PID/job identity. Thus the existence of those monitors does not refute this particular missing completion/error receipt.
- Parent proof executes the exact extracted command **body** with PowerShell 7.4.6 on Linux, substituting only Clear-RecycleBin: success yields exit0; terminating fake refusal yields exit1. This demonstrates a lost differentiating worker result in the specified test environment. It is **not** Windows PowerShell5.1, real Clear-RecycleBin/native Recycle Bin, actual AHK launch, or UI error visibility validation.
- The current test at `test_system_actions.ahk:343-350` pins command/options only, without a native worker completion/refusal assertion.

Suggested report language: after successful hidden worker launch, a later bin operation error can remain unreported by ErgoptiPlus because no result/error receipt is retained. Do not describe an explicit success notification, a blocking action, automatic cancellation on pause, or a measured real-Windows failure.

## Disposition

Both candidates remain source-confirmed reporting/receipt gaps with distinct constraints. Strongest native Windows scenarios remain unexecuted; WDS-002 additionally has the parent's real PowerShell7/body-only refusal evidence. Neither should be inflated into incorrect target mutation, application closure confirmation, or an OS feature absence. No production/test changes or native effects were made by this countercheck.
