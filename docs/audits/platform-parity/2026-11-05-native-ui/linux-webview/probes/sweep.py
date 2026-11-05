"""Replay the complete bounded audit cohort; argv: source-root, sweep-name."""

import pathlib
import subprocess
import sys

source = pathlib.Path(sys.argv[1]).resolve()
name = sys.argv[2]
here = pathlib.Path(__file__).resolve().parent
logs = here.parent / "logs"
lua = pathlib.Path("/workspace/scratch/parity-toolchain/ci-bin/luajit")
assert (
    subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    == "3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a"
)
for filename in ("scope.lua", "editor.lua", "personal.lua"):
    result = subprocess.run(
        [str(lua), str(here / filename), str(source)], text=True, capture_output=True
    )
    (logs / f"{name}-{filename}.log").write_text(result.stdout + result.stderr)
    assert result.returncode == 0, (filename, result.returncode, result.stderr)
    print(filename, "exit=0", "lines=" + str(len(result.stdout.splitlines())))
print("SWEEP_RECEIPT", name, "all_three_processes_exit=0")
