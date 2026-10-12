<!-- docs/handovers/2026-10-11-groups-247/group4-windows-execution.md -->

# Group 4 Windows software delivery (2026-10-11)

Source baseline: `8d6e3a1198a16645e41b7d4bf0f56a013be6072a`.
Dedicated branch: `codex/groups-247-completion`.
Native Windows/macOS execution and physical qualification are not claimed.

## Implemented corrections

The three corrections are committed independently, with their regressions:

1. `runtime-process-identity`: strengthen native foreground readiness and model
   process identity. Launcher emits native child creation FILETIME obtained from
   retained HANDLE. The mandatory typed receipt (11 fields) requires the creation
   FILETIME as an exact positive integer and refuses missing or differently typed identity
   in READY and cancellation-only cleanup capture. Worker retains
   verified helper/launcher sources, immutable full inventory and exact receipt,
   verifies reopened process creation identity and native listener before/after
   exact managed pull. Child env is scoped without ambient OLLAMA/PATH mutation.
   Native regression additions preserve existing assertions.
2. `managed-native-files`: published-version read-only inspection, full pinned
   inventory reuse, exact runtime receipt retirement; typed physical proof in
   existing native port and undispatched vs unknown quiescence separation.
   Refuses missing/stale/replaced/older receipt ownership. Preserves installed
   versions/models and retains unknown files/WAL debt.
3. `production-managed-bootstrap`: replace default winget/browser installation
   with source-bound existing native file/runtime owners and native architecture;
   separate install/start/model/enable consent, original total deadline,
   cancellation/physical debt, fresh version and actual normalized-name Map
   receipt, private extraction/download tickets, cleanup and UI errors/retry.
   Legacy installer remains only explicitly injected fixture Port; default
   public legacy entry redirects to the managed flow.
   Source-bound exact enable writer handoff pre-renders expected complete bytes;
   it cannot adopt arbitrary later bytes or another backend/model/API entry.
   Actual version/tags/delete/chat/stream/warmup/menu consumers use native managed
   origin while READY, never localhost equivalence; withdrawn retained runtime
   refuses fallback until exact physical settlement. Model menu download uses
   captured managed worker, distinct consent, fresh tags, no ambient PATH CLI.

No local_servers.ahk changes (origin/main CaptureView/entries_bound/performance
changes remain final integration agent responsibility). No workflow, release,
performance-owner source, shared locale or shared policy/schema modifications.
Existing localized UI strings suffice. Native helper versions and shared JSON
catalogue/source qualification flags were not changed or falsely qualified.

## Container receipts (bounded)

- `node tools/test/test-windows-managed-bootstrap.cjs`: RED before default
  production dispatch edit, exit1 on legacy installer-default assertion;
  final GREEN exit0. Source wiring controls only; no Windows execution credit.
- AHK encoding and strict conventions passed at the implementation checkpoint;
  use the final common receipt for whole-tree counts. Neither is an AHK
  parser/runtime execution.
- `npx prettier --check tools/test/test-windows-managed-bootstrap.cjs`: exit0.
- `git diff --check -- <owned tracked paths>`: exit0.
- `node tools/test/test-managed-ollama-protocol.cjs`: exit0, original16 inert
  fixture byte-exact regeneration, portable Python/protocol/adapter controls;
  terminal explicitly states native Go/macOS build/signing/model exchange/SDK
  admission unexecuted. Includes portable controlled Lua adapters. Windows
  receiving branch requires win32 and was not run; no complete hosted-native
  claim follows from these controls.

The new native suites are UNEXECUTED: 29 managed AHK cases, 18 runtime-owner AHK
cases total (3 additions over original15), 9 bootstrap native file PS cases,
7 model import/native file/environment/TCP/process identity PS cases. Existing
9 controlled launcher PS cases receive additive creation-handle assertions;
existing31 native file assertions/cases are preserved unchanged. Tests with
injected process ports or source checks are not native production qualification.

## Native Windows VM commands and expected results

Preconditions: final exact branch/SHA, stock AutoHotkey v2.0.26 shipped/pinned
by repository, Windows PowerShell5.1 (not pwsh/Linux), current-user desktop,
System32 curl / native proxy/TLS and canonical ShellRunner available.
For the protocol collector additionally activate Node 22.22.2 with frozen npm
dependencies, Python 3.13.5, PowerShell 7 (`pwsh.exe`) and Lua 5.4.7.
The directly invoked native file/model scripts use Windows PowerShell 5.1;
allow their reviewed local scripts through a process-scoped execution policy. Use clean
per-user test profile; record final source SHA and complete real output. No
administrator winget/system Ollama installation required for managed path.

```powershell
# From final repository root; use repository's pinned AutoHotkey executable.
$AhkPinned = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
# Replace this path only with an independently verified AutoHotkey 2.0.26 x64.
& $AhkPinned /ErrorStdOut static/ergopti_plus/windows/tests/run_all.ahk --dry-run
& $AhkPinned /ErrorStdOut static/ergopti_plus/windows/tests/run_all.ahk --only '(groups247-managed)'
& $AhkPinned /ErrorStdOut static/ergopti_plus/windows/tests/run_all.ahk --only 'Ollama runtime:'
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File static/ergopti_plus/windows/tests/unit/test_ollama_install_files.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File static/ergopti_plus/windows/tests/unit/test_ollama_managed_bootstrap.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File static/ergopti_plus/windows/tests/unit/test_ollama_model_pull.ps1
node tools/test/test-managed-ollama-protocol.cjs
```

Expected: dry-run parses complete original registration; focused groups247 =
30 cases (29 bootstrap + mandatory-creation owner case); original runtime filter
=17 registered cases; files original31 pass, newfiles9 pass, model7 pass.
Protocol win32 lane receives actual production launcher functions through nine
controlled native boundaries with complete original plus creation assertions.
None alone qualifies a real managed archive/model/server installation.
File fixture scripts retain explicit private artifacts for examination; remove
only those exact recorded test paths after observed handle/tree closure.

Before whole-driver startup, generate and review the current native DLL/manifest
with the official Windows MSVC command in [Group 7](group7-native-execution.md).
A stale manifest is a prerequisite failure. Then start final
`static/ergopti_plus/windows/ErgoptiPlus.ahk` using pinned AHK.
Use tray Ollama warning/rescue Ctrl+Alt+Shift+I on clean per-user profile, with
AI-enabled preference and catalogue display model selected. Expect native host
architecture exact asset, independently prompted install then start then model
consent, official finite archive size/hash and full executable/library receipt,
exact foreground listener127.0.0.1 and native models root, fresh pinned version
and configured canonical tag, successful real inference/warmup/streaming.

Repeat decline each consent, held dialog backend/model/source change, pause,
manual page close, timeout/proxy/TLS/redirect/digest refusal, retry, stop/restart,
quit while downloading/extracting/launching/pulling, and unknown/locked cleanup.
Expect no unauthorized dispatch, no false READY/native cleanup grant, exact
owners retained on refusal, no external server termination, installed versions
and models/config foreign values preserved. After READY, explicit enable write
must retain exact daemon; unrelated user config mutation must retire it.

Run external preinstalled server on selected port and repeat discovery/chat;
expect unchanged external server/config and no managed acquisition. Run foreign
IPv6/localhost listener alongside managed IPv4 where feasible; managed
version/tags/chat/stream/warmup/delete must bind only admitted127 listener.
Exercise PID replacement/created-filetime mismatch and an older readiness
receipt: model dispatch/retirement must refuse, never borrow reused PID identity.

A native VM suffices for file ACLs/handles/jobs/TCP/proxy/download/model/inference,
consent GUI, source/config persistence, quit/restart and interpreter compilation.
A native VM can also qualify GDI/pixel/geometry behavior at its recorded virtual
DPI. TODO88 perceived typography, real monitor/DPI transitions and actual typing
need the corresponding physical display/keyboard; keep those results separate
from VM screenshots and the transversal physical input cases. Linux source/mocks do not substitute for these.
