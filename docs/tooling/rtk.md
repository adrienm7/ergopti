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

## Keep machine data raw

RTK 0.43.0 is a lossy presentation adapter at the human/LLM boundary. Use the
launcher only when the command's output will be read as terminal output. Run
the child directly whenever stdout must remain byte- or syntax-exact, including
input to a pipe, redirection, command capture, JSON or CSV parser, hash,
generator, or test assertion.

For example, these machine-to-machine commands deliberately bypass RTK:

```powershell
$commit = git rev-parse HEAD
git diff --raw > candidate.diff
```

```sh
commit=$(git rev-parse HEAD)
git diff --raw > candidate.diff
```

Never put `rtk.ps1`, `rtk.sh`, or a bare `rtk` command on the producer side of
such a boundary. The child may still invoke and validate its own subprocesses;
only the outer stdout path determines whether the launcher is appropriate.

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
