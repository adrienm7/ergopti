# Running a fix/<os> agent pass

Read this when the maintainer asks for a new `fix/linux`, `fix/macos` or
`fix/windows` pass (one agent per OS). The 28 October passes were squashed onto
dev as `fix(macos|linux|windows): land the fix/<os> audit branch`; their
original histories are the `archive/fix-<os>` tags once the maintainer has run
the [remote branch cleanup](../../../../docs/tooling/remote-branch-cleanup.md).
Read the previous pass's handover first: `docs/audits/macos/2026-10-28/`
(`TODO.md`, `report.md`), `docs/audits/linux/2026-10-28-closeout/`
(`README.md`, "Outstanding TODO"), `docs/audits/windows-2026-10-28/`
(`README.md` "Remaining findings", `POST_VALIDATION.md` "Resume from a fresh
checkout").

## How a pass runs, so no time is lost

1. Branch `fix/<os>` from the current `dev`, never from an old fix branch. Keep
   it linear: rebase onto dev, never `git merge dev` into it. The 28 October
   passes merged dev a dozen times each, so they could not be replayed commit
   by commit and had to be squashed.
2. Push every hour and dispatch
   `gh workflow run ci.yml --ref fix/<os> -f os_lanes=<os>`. A pass is done
   only when its lane and Common are green. On 28 October the Windows pass
   stopped with 3 unit groups red and the Linux pass with the RPM and AppImage
   installed-data checks red; the coordinator had to fix both before the
   release.
3. Stay in the OS's own files. Shared tests (`tools/test/*.cjs`) touched by two
   passes conflicted: the macOS and Linux passes rewrote the same App Cloner,
   bash-resolution and PAC source tests in different ways. Leave shared files
   to the coordinator, or announce them first.
4. Workflows (`.github/workflows/*`) may be edited when a fix needs it; say so
   in the commit.
5. Evidence goes into one `docs/audits/<os>/<date>/` folder: a README with the
   remaining work at the top, then any archives, each under 10 MB.
6. Host: run as a normal user with `USER` and `LOGNAME` set (the JS suite
   refuses root); Node 22.22.2, Ruff 0.15.8, and PowerShell 7 for the Windows
   host checks. AutoHotkey under Wine is narrower evidence only and never
   replaces Windows CI. The Linux container's known host-only reds are in
   `docs/memory/workflow-and-verification.md`
   ("project-linux-container-host-only-reds").
