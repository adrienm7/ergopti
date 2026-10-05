"""Independently qualify native probe-wrapper cleanup on failed deadlines."""

import os
from pathlib import Path
import re
import subprocess
import sys


def main():
    """Observe actual descendants disappear after wrapper-owned timeout cleanup."""
    wrapper = Path(__file__).with_name("run_native_subreaper.py")
    import_and_run = """
import importlib.util, sys
spec = importlib.util.spec_from_file_location('owned_fixture_wrapper', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
sys.exit(module.main([sys.executable, '-c', sys.argv[2]], deadline_seconds=0.2))
"""
    programs = {
        "live leader with descendant": """
import os, signal, time
r, w = os.pipe()
child = os.fork()
if child == 0:
    os.close(r)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    os.write(w, b'ready')
    os.close(w)
    time.sleep(30)
    os._exit(0)
os.close(w)
os.read(r, 5)
os.close(r)
print('identities:' + str(os.getpid()) + ',' + str(child), flush=True)
time.sleep(30)
""",
        "exited leader with live descendant": """
import os, signal, time
r, w = os.pipe()
child = os.fork()
if child == 0:
    os.close(r)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    os.write(w, b'ready')
    os.close(w)
    time.sleep(30)
    os._exit(0)
os.close(w)
os.read(r, 5)
os.close(r)
print('identities:' + str(os.getpid()) + ',' + str(child), flush=True)
os._exit(3)
""",
    }
    for name, program in programs.items():
        result = subprocess.run(
            [sys.executable, "-B", "-c", import_and_run, str(wrapper), program],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=8,
        )
        match = re.search(r"^identities:(\d+),(\d+)$", result.stdout, re.MULTILINE)
        assert match is not None, (
            f"the actual fixture failed to publish identities: {result.stderr}"
        )
        assert result.returncode != 0, "a failed native fixture cannot become successful"
        if name.startswith("live"):
            assert "native owned-process probe exceeded its deadline" in result.stderr
        else:
            assert "independent teardown killed and physically reaped them" in result.stderr
        for identity in match.groups():
            try:
                os.kill(int(identity), 0)
            except ProcessLookupError:
                continue
            raise AssertionError(f"native fixture identity {identity} survived its failed wrapper")
        print(f"PASS wrapper cleanup: {name}")
    print("Native wrapper failure teardown: 2 passed, 0 failed")


if __name__ == "__main__":
    main()
