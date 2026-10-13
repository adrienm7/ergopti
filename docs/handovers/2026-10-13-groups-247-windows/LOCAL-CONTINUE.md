<!-- docs/handovers/2026-10-13-groups-247-windows/LOCAL-CONTINUE.md -->

# Local Windows continuation prompt

You take over CLOUD Ergopti groups 2/4/7 on an actual Windows machine. Continue
implementation and actual receiving; do not stop at an audit. Reuse an existing
clean checkout, preserving every unrelated file and running process. Read
AGENTS.md, docs/memory/README.md and the routed Windows/workflow topics; apply
ship-fix, verify-change, ahk-driver, cross-driver-parity and i18n as appropriate.
The previous local session is archived: do not restart it.

Fetch explicit dev and codex/groups-247-completion mappings. Compare origin/dev
with ls-remote; do not trust a main-only refspec. Inspect status before switching.
Continue on codex/groups-247-completion, whose completed fifteen AI cuts are
already applied. Read this handover's README and atomic-source-checkpoint.json,
docs/ERGOPTIPLUS_TODO.md and docs/handovers/2026-10-11-groups-247/windows-delivery.md.
First integrate fresh dev by rebase preserving commits, never force/squash.
Root owns CI/test infrastructure, inventories/workflows and publication; coordinate
shared paths before touching them. Main advances only at Root's authorized release
checkpoint. No direct main push and no change to existing release/CI policy.

Use pinned Node22.22.2, AutoHotkey2.0.26 x64, PowerShell5.1, official MSVC x64 and
Windows SDK. Resolve repository-supported tool prerequisites before executing;
never fabricate provenance or bypass signature/hash validation. Set ERGOPTI_AHK_RUNTIME
to the actual pinned executable. Preserve personal config and external servers.
Run each command separately, retaining its own natural exit and exact selected
case count; a footer is not proof if the process exits nonzero:

```powershell
node tools/test/test-windows-managed-bootstrap.cjs
node tools/test/test-windows-rewrite-prompt-wiring.cjs
node tools/test/test-ahk-encoding.cjs
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only=groups247-offer-affinity
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only=managed-origin-custody
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only=todo46-manual-requester
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only=agent-app-picker-tail
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only=aux-final-origin-currency
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only=personal-metadata-source-type
node tools/test/test-ahk-full-startup-smoke.cjs
```

Require respectively 35, 17, 25, six, five and eight AHK cases, zero failures,
zero empty selections/skips and exit0. Do not weaken assertions or treat source
guards as executed AHK. Then run the verification planner's full Windows unit/E2E,
format/JS and build/startup gates. Triage baseline/tool/native defects separately;
Root's unpublished infrastructure fixes cannot be presumed present.

Receive the actual managed Windows local AI flow: separate runtime/model consents,
per-user install/start/readiness, missing model, stream, warmup, errors, refusal,
cancellation, retained cleanup and source/requester replacement. Include agent
app-exclusion save and screen disable/re-enable. Old callbacks must stay silent,
successors must retain ownership, and personal config/external servers must survive.

Continue TODO49's unfinished software. Review the preserved registration draft
and observer hint candidate. Implement the actual C Begin/Plan output alias gap
with meaningful original-red/fixed-green regressions. Compose against the exact
nineteen-path native bundle and preserve its original assertions. Follow
terminal-complete-receiving.md for preimage checks and official native rebuilding:

```powershell
powershell -NoProfile -File tools/build/build_windows_nav_owner.ps1 -UpdateTracked
powershell -NoProfile -File tools/build/build_windows_nav_owner.ps1
```

Require eight replay/eleven output matrices, all44 native owner cases, an exact
41-export hardened x64 DLL and authentic regenerated source provenance. Commit
source/DLL/manifest coherently only after receiving. Never enable a native
qualification flag merely to unblock execution. Run the listed 667 terminal and
91 KLE cases, then the explicitly opted-in standalone user32 fixture under its
owned idle desktop prerequisites. Preserve unknown output debt and natural exit;
do not force-kill a pending fixture or guess cleanup. Complete cohort conversion
and production policy only with their real contracts and measured Windows data.

Prepare the actual application build using the existing documented Windows builder
recipe. Open Diagnostics and click "Collecter le diagnostic Windows"; receive
archive/source integrity, cleanup, cancellation and close/reopen ownership. Provide
a usable local artifact and its exact SHA to the maintainer/Root for publication.
Stable1.0.1 lacks these fixes. Root coordinates the release containing the one-click
collector; do not publish from main or alter the release workflow independently.
Keep private evidence outside Git; review redaction before sharing any archive.

Windows VM receiving and actual device acceptance are separate. Keep physical
keyboard/hook-order/modifier/ISO, display/DPI/UIA and installed-app claims open until
actually exercised. Keep native macOS open for issue94/tap-hold/symbol wrap/ISO10-50,
API addition/oMLX discovery and managed service receiving. Linux is unavailable to
the maintainer currently; preserve its container receipts and native UNRUN status.
No Mac/Linux native claim follows from Windows tests or Hammerspoon doubles.

Commit one correction plus causal regressions at a time in English. Update only
owned TODO sections with exact passed/failed/skipped/UNRUN outcomes. Fetch at safe
boundaries and immediately before each regular dev push; preserve incoming commits,
revalidate touched composition and push without force. Save unfinished source on
the group branch. Finish with published SHA, exact commands/exits, remaining
software/native/device work and a usable diagnostics artifact.
