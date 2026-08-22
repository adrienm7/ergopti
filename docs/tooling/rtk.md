# Project RTK

This repository uses [Rust Token Killer](https://github.com/rtk-ai/rtk) to
reduce shell-output tokens. The integration is project-owned: no global agent
instruction file or global hook is required.

Use the launcher for the current operating system:

```powershell
.\tools\rtk\rtk.ps1 git status
```

```sh
./tools/rtk/rtk.sh git status
```

The first invocation accepts an already-installed copy only when its version
matches the pinned Rust Token Killer release and its `gain` command works. If
none is available, it downloads that release into the current user's data
directory, verifies its SHA-256, and
caches only its resolved path under the repository's ignored `.rtk/` folder.
It never modifies a shell profile or persistent `PATH`.

CI never downloads RTK. Without a valid installed binary, the launcher runs
the child command unfiltered so builds remain independent of this convenience
tool.

Explicit checks are available with `bootstrap.ps1 verify` or
`bootstrap.sh verify`. A similarly named binary without the `gain` command is
not Rust Token Killer and is never removed or overwritten by these scripts.
