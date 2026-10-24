# Coordination state (session started 2026-10-24 ~09:45 UTC)

User: away; wants whole todo done (parity, optimisation per OS). Push each commit to dev, cancel CI of each push
(MCP actions_run_trigger cancel_workflow_run; gh CLI is NOT authenticated). No Co-Authored-By (repo rule).
I am the only writer to dev now. Delete fix/linux, fix/macos, fix/windows on origin after their commits land.

## Local agents (worktrees /home/user/wt/<name>, branch wt/<name>, base d501c43d or 1a6e1349)
health, linux-perf, par-timing, par-ui-gates, par-lua-helpers, par-ownership, par-shared-parsers, par-corpora,
par-instrumentation, linux-llm, linux-ui-parity, par-theme, par-reasons, par-llm-plan, par-menu-frames,
fix-linux, fix-macos, fix-windows (rebase agents)

## Remote worker sessions (push to origin agent/<name>)
- linux-perf-lab     session_01S34DJksSQUouzhitFndsbi
- linux-ci-lanes     session_01FBxukgwDM19DW15JZNwSRv
- linux-packaging    session_01F5kLpz77zUdRn3Wc5K1Kd4
- macos-lua-perf     session_01XuUqCmgMsZ8qjetr8Y6C1u
- windows-ahk-wine   session_019Dqz9fyqvPEnd3VVib1r4u
- par-19             session_01Hogit999g15KP4Y5DTD4kU
- par-67             session_01R2NGphNroL8YbeWtk9MpFV
- par-77-73          session_01XsLFS4zi1csVNQ2MyMZZ42
- par-74-84          session_01AButEgg72kTUDMmRdkkkg1
- par-22-34-40       session_01UTkjG1dpSeJRVTancpsc2z
- par-59-63-64       session_01Rg136HjWnPZJsUVJjmdvZG
- par-71             session_01Xs7oxKoT1KG2CrW5GpEqYb

## Not yet assigned (todo)
PAR-6, PAR-8 (maintainer decisions), PAR-14 Windows Atom fallback (AHK), PAR-15 macOS per-key thresholds (decision),
PAR-30 signing (CI), PAR-43 remainder, PAR-58 Windows consumer of shared Lua contracts (AHK), PAR-76 long refactors
(plans), Wave 2 config policy remainders, backlog items 5, 13/35, 97/98, 107/108, 139, 142, 120, CI items.

## Landing procedure
1. Review workflow on branch diff (adversarial lenses) -> fixes in its worktree.
2. scratchpad/land.sh <branch>  (rebase onto origin/dev, push commit by commit, ff local dev)
3. Cancel every in-progress/queued run on dev (CI, remap runtime, linux layout).
4. Update docs/ERGOPTIPLUS_TODO.md from the agent report (commit docs(todo): ...), push, cancel.

## Landed
(none yet)

## Review workflow (reuse with Workflow({scriptPath, args:{worktree, ref, commits, report}}))
/root/.claude/projects/-home-user-ergopti/a1289939-fd47-5b65-a929-48c61fdb6fa0/workflows/scripts/review-and-land-branch-wf_c53a6a86-b2d.js
Land worktrees: /home/user/wt/land-<name> on branch land/<name> from origin/agent/<name>.
- macos-suite-health session_01GnavooU7rfVR7Q2Sb1nbG5 (owns macOS stubbed suite reds; health agent keeps JS + Linux)
- par-71: COMPLETED, review wf_c53a6a86-b2d running (land/par-71)
Known dev reds (from par-71 report): Linux 85 failures; JS inventory dup ordinal 466; macOS stubbed ~495 reds.

## Usage-limit pause (maintainer, 11:15 UTC): 5h window at 80%, resets 14:40 UTC (16:40 Paris); weekly resets 15:00 UTC
Maintainer wants every container resumed at 14:40 and max spend 14:40-15:00 UTC (then keep going).
- One-shot triggers at 14:41 UTC wake each remote session (generic "resume where you stopped" prompt).
- Coordinator wakes at 14:41 (main) and 14:46 (backup) via send_later.
- Detached loop scratchpad/backup.sh (log backup.log) pushes every 4 min until 15:30 UTC:
  local wt/* -> origin agent/wt-<name>, land/* -> origin agent/land-<name>, this state -> origin agent/coordinator-state.
- local-prompts/*.txt: each local agent's agentId + original prompt (for SendMessage resume or fresh relaunch).
- remote/{win-par-14-pac,win-par-58,par-43,par-30,par-76,wave2-backlog}.prompt: NEW remote sessions to create at wake
  (create_session env env_014BZGSc2kAVpX7FJrCQtJPX, source_url https://github.com/adrienm7/ergopti, revision dev).
- Triggers created: 12 remote resumes at 14:41 (trig_0191CT.., 016q7X.., 011xY2.., 016vAG.., 01B228.., 01P1f5.., 01YHqc..,
  01U9tK.., 01XtW5.., 018SZa.., 01CiSh.., 01J4iB..); coordinator trig_01WCwgS2DPBvaKcKxUDjPfG8 (14:41),
  trig_0135Pju7ojjuv8yhhNcN92Bn (14:46). par-71 session is completed: not woken.
