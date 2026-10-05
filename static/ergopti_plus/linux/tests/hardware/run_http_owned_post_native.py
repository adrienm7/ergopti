"""Run paired real POST receipts through the existing exact native subreaper."""

import argparse
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("driver_root", type=Path)
parser.add_argument("--shared-lua", type=Path)
parser.add_argument("--lua", required=True)
parser.add_argument("--child-command", nargs=argparse.REMAINDER)
args = parser.parse_args()
driver = args.driver_root.resolve()
shared = args.shared_lua.resolve() if args.shared_lua else driver.parent / "_shared/lua"
hardware = driver / "tests/hardware"
helper = hardware / "run_native_subreaper.py"
if args.child_command:
    spec = importlib.util.spec_from_file_location("owned_post_subreaper", helper)
    owner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(owner)
    sys.exit(owner.main(args.child_command, deadline_seconds=20))

for descendants in [False, True]:
    with tempfile.TemporaryDirectory(
        prefix="owned-post-", dir=os.environ.get("TMPDIR", "/var/tmp")
    ) as temporary:
        directory = Path(temporary)
        marker = directory / "descendant.pid"
        environment = dict(os.environ)
        if descendants:
            wrapper = directory / "curl"
            wrapper.write_text(
                "#!/usr/bin/python3\nimport os, signal, subprocess, sys, time\nread_fd, write_fd = os.pipe()\nchild = os.fork()\nif child == 0:\n    os.close(read_fd)\n    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n    null_fd = os.open('/dev/null', os.O_RDWR)\n    for descriptor in (0, 1, 2):\n        os.dup2(null_fd, descriptor)\n    if null_fd > 2:\n        os.close(null_fd)\n    os.close(3)\n    with open(os.environ['ERGOPTI_POST_DESCENDANT'], 'w') as receipt:\n        receipt.write(str(os.getpid()))\n    os.write(write_fd, b'READY')\n    os.close(write_fd)\n    time.sleep(30)\n    os._exit(0)\nos.close(write_fd)\nready = os.read(read_fd, 5)\nos.close(read_fd)\nif ready != b'READY':\n    raise RuntimeError('exact native sibling readiness was not acknowledged')\n# Curl starts only after the actual child installs its handler and closes its\n# inherited streams/body FD. The existing outer subreaper owns failure teardown.\nresult = subprocess.run(['/usr/bin/curl', *sys.argv[1:]], pass_fds=(3,))\nsys.exit(result.returncode)\n"
            )
            wrapper.chmod(0o700)
            environment["PATH"] = str(directory) + os.pathsep + environment.get("PATH", "")
            environment["ERGOPTI_POST_DESCENDANT"] = str(marker)
        command = [
            sys.executable,
            str(Path(__file__)),
            str(driver),
            "--shared-lua",
            str(shared),
            "--lua",
            args.lua,
            "--child-command",
            args.lua,
            str(hardware / "run_http_owned_post_native.lua"),
            str(driver),
            str(shared),
            str(marker) if descendants else "",
        ]
        result = subprocess.run(
            command, env=environment, cwd=driver, capture_output=True, text=True
        )
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        if result.returncode != 0:
            sys.exit(result.returncode)
        expected = f"Actual owned POST: {5 if descendants else 4} passed, 0 failed; exact native cleanup complete."
        lines = result.stdout.splitlines()
        reapers = [
            line
            for line in lines
            if re.fullmatch(r"Native subreaper: \d+ adopted descendants physically reaped", line)
        ]
        if (
            lines.count(expected) != 1
            or len(reapers) != 1
            or re.search(r"\bSKIP(?:PED)?\b", result.stdout + result.stderr, re.I)
        ):
            raise RuntimeError("paired native POST receipt incomplete or skipped")
print("Actual owned POST paired receipts: 9 passed, 0 failed.")
