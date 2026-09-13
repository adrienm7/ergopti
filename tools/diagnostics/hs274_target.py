# tools/diagnostics/hs274_target.py
"""Own the external Cocoa fixture independently of the Hammerspoon consumer."""
from contextlib import contextmanager
import os
from pathlib import Path
import subprocess


@contextmanager
def owned_target(output, report, lifecycle):
    """Keep the exact target executable under bounded native process cleanup."""
    executable = Path(os.environ["HS274_CONTEXT_TARGET"]).resolve(strict=True)
    if not executable.is_file():
        raise ValueError("Native context target executable is missing")
    request, response = output / "hs274-target-request.json", output / "hs274-target-response.json"
    if request.exists() or response.exists():
        raise ValueError("Native target outputs already exist")
    native = lifecycle.NativeProcesses()
    if native.matching(executable):
        raise RuntimeError("Native target executable already has an owner")
    with (output / "hs274-target.log").open("xb") as log:
        process = subprocess.Popen([str(executable), str(request), str(response)], stdout=log, stderr=subprocess.STDOUT)
        state = report["context_target"] = {"pid": process.pid, "executable": str(executable), "settled": False}
        primary = None
        try:
            yield {"target_pid": process.pid, "target_request": str(request), "target_response": str(response)}
        except BaseException as error:
            primary = error
            raise
        finally:
            try:
                lifecycle.cleanup(native, executable, process)
                state["settled"], state["exit"] = True, process.returncode
                if process.returncode not in (0, -15):
                    raise RuntimeError("Native context target exited unsuccessfully")
            except Exception as error:
                state["cleanup_error"] = f"{type(error).__name__}: {error}"
                if primary is None:
                    raise
