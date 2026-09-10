# tools/diagnostics/hs274_disconnect.py
"""Observe a capture client's failure when its output pipe has no reader."""

import os
import subprocess


def disconnected_capture(command, output, report, timeout=20):
    """Own the pipe and child until an explicit output failure is reaped."""
    path = output / "hs274-remap-disconnected-stream-stderr.log"
    with path.open("x", encoding="utf-8") as diagnostics:
        reader, writer = os.pipe()
        os.close(reader)
        try:
            process = subprocess.Popen(command, stdout=writer, stderr=diagnostics)
        finally:
            os.close(writer)
        state = report.setdefault("processes", {}).setdefault("disconnected-stream", {"pid": process.pid})
        try:
            process.wait(timeout=timeout)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)
                state["forced_cleanup"] = True
            state["exit"] = process.returncode
            state["reaped"] = process.poll() is not None
    diagnostic = path.read_text(encoding="utf-8")
    report["stream_disconnect"] = {"stderr": diagnostic}
    if process.returncode != 1 or "Physical capture failed: Capture output disconnected" not in diagnostic:
        raise RuntimeError("Capture did not report the expected disconnected output failure")
