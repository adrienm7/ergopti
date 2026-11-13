"""Exercise configured Lua selection through the real native payload control."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    """Keep incompatible bare Lua separate from the configured real interpreter."""
    diagnostic, root, parent_lua, control, temporary = sys.argv[1:]
    canonical = shutil.which(parent_lua)
    refusing = shutil.which("false")
    assert canonical and refusing, "real configured and refusing executables are required"
    canonical = str(Path(canonical).absolute())
    with tempfile.TemporaryDirectory(prefix="payload-lua-", dir=temporary) as directory:
        private = Path(directory)
        bare = private / "lua"
        selected = private / "configured-lua"
        selected.symlink_to(canonical)
        valid = control in ("absolute", "name")
        bare.symlink_to(refusing if valid else canonical)
        environment = dict(os.environ)
        environment["PATH"] = str(private) + os.pathsep + environment.get("PATH", "")
        choices = {
            "absolute": str(selected),
            "name": selected.name,
            "missing": str(private / "missing-lua"),
            "empty": "",
        }
        environment["LUA"] = choices[control]
        result = subprocess.run(
            [sys.executable, diagnostic, root],
            env=environment,
            capture_output=True,
            text=True,
            timeout=90,
            check=False,
        )
        if valid:
            assert result.returncode == 0, result.stdout + result.stderr
            receipt = json.loads(result.stdout)
            assert receipt["passed"] == 2
            assert receipt["umask"] == "0022"
            assert receipt["parent_umask_preserved"] is True
            assert set(receipt["observations"]) == {"mlx", "ollama"}
            native_cases = 2
        else:
            assert result.returncode != 0, "configured refusal must not fall back to bare Lua"
            assert result.stdout == ""
            assert "Lua 5.4 is required for the native private-file control" in result.stderr
            native_cases = 0
        print(json.dumps({"control": control, "native_cases": native_cases, "passed": True}))


if __name__ == "__main__":
    main()
