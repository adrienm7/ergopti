# Fresh-container worker prompt

Assigned group: config-menus
Branch: feat/config-menus

Work on ErgoptiPlus in adrienm7/ergopti. Do not work on the website. Your task
is to finish the assigned group's remaining items in
`docs/ERGOPTIPLUS_TODO.md`, easiest genuinely finishable slices first.

Use `$cloud-environment-onboarding:setup` to prepare the actual new container;
read its saved setup draft before changing it. Read `AGENTS.md`,
`docs/memory/README.md`, relevant routed memory and skills, and
`docs/handovers/2026-10-04-parallel-containers/README.md` plus
`PARALLEL-WORK.md` before modifying files. Start from actual `origin/dev`,
not a historical SHA, and create or resume only your assigned feature branch.
Inspect the index and working tree and preserve existing changes.

You have explicit authorization to work autonomously for hours, use parallel
subagents or isolated worktrees when useful, commit each coherent fix/feature
and push your feature branch immediately. Do not ask for that authorization
again. Do not push or merge dev/main: the integration coordinator owns them.
Do not use backup branches, reset, clean, stash or force-push. Fetch and merge
incoming dev regularly, preserving upstream Windows/Linux fixes.

Own only the item IDs assigned to your group in PARALLEL-WORK.md. Coordinate
with the existing Windows workstation agent and fix/linux agent before overlap.
Tell the coordinator before modifying shared manifests/schema/locales/generators
or CI, and serialize overlapping paths. Update only your assigned TODO blocks
in every feature/fix commit. Remove an item only when its whole stated behavior
and required validation actually pass; never remove or weaken assertions.
Use tools/rtk/rtk.sh and verify-change. Run JS and native suites serially when
artifact drift controls can mutate generated output. Stage exact owned paths.

Centralize logic, data, menus and policy in shared code; OS folders implement
native ports. Aim for equivalent behavior on Windows/macOS/Linux and make real
unavailability explicit. Code, technical docs and commits are English; new labels
need genuine translations in all 21 locales. AHK is UTF-8 with BOM; all text LF.
Regenerate artifacts through their owner, never by hand. Recover only the pending
candidate packets relevant to your group, inspect their preimages, complete
review and qualify the final composed source. A saved patch is not a delivered
feature. Read the handover's real failed/unexecuted validations.

After every push cancel automatic workflows for its exact SHA to prevent
releases. Report your exact SHA and affected OS to the coordinator, who owns
the single codex/ci-validation branch and dispatches ci.yml only for affected
OS using os_lanes. Do not move that CI ref or create extra CI branches. Manual
runs must never publish releases and must finish; do not cancel them on later
pushes. Provide exact run URLs and passed/failed/skipped/unexecuted outcomes.
A Linux cloud container can run real Linux native components when the needed
runtime/display/input permissions are present. Inspect those prerequisites;
unit stubs are not real X11/Wayland or physical-input acceptance. Windows and
macOS native execution requires the relevant CI runners or real machines.

Persist your work early and regularly. At every checkpoint leave a clean,
pushed branch or explicitly saved pending candidate patches with SHA, base,
review/test status and recovery instructions. Finish by reporting the branch,
commits, completed TODO IDs, remaining limitations and integration order.
