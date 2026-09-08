#!/usr/bin/env python3
"""Supervise a real, isolated Hammerspoon reader benchmark on macOS."""

import argparse
import ctypes
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


class NativeProcesses:
    """Resolve process capabilities by the unique copied executable path."""

    def __init__(self):
        self.lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.lib.proc_listpids.argtypes = [ctypes.c_uint, ctypes.c_uint,
                                          ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_listpids.restype = ctypes.c_int
        self.lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint]
        self.lib.proc_pidpath.restype = ctypes.c_int

    def path(self, pid):
        buffer = ctypes.create_string_buffer(4096)
        if self.lib.proc_pidpath(pid, buffer, len(buffer)) <= 0:
            return None
        return os.fsdecode(buffer.value)

    def matching(self, executable):
        size = self.lib.proc_listpids(1, 0, None, 0)
        if size <= 0:
            raise RuntimeError('native process enumeration failed')
        buffer = (ctypes.c_int * (size // ctypes.sizeof(ctypes.c_int) + 1024))()
        used = self.lib.proc_listpids(1, 0, buffer, ctypes.sizeof(buffer))
        if used <= 0 or used >= ctypes.sizeof(buffer):
            raise RuntimeError('native process enumeration failed or overflowed')
        return [pid for pid in buffer[:used // ctypes.sizeof(ctypes.c_int)]
                if pid > 0 and self.path(pid) == str(executable)]

    def signal(self, pid, executable, kind):
        # Never signal a PID merely because it appeared in an earlier snapshot.
        if self.path(pid) != str(executable):
            return
        try:
            os.kill(pid, kind)
        except ProcessLookupError:
            pass


def validate_result(result):
    if not isinstance(result, dict) or result.get('status') != 'ok':
        raise RuntimeError('native benchmark did not report success')
    samples = result.get('manifest_ms')
    if (not isinstance(samples, list) or len(samples) != 11
            or any(isinstance(value, bool) or not isinstance(value, (int, float))
                   or not math.isfinite(value) or value < 0 for value in samples)
            or result.get('rows') != 224 or result.get('ui') != 'unmeasured'
            or result.get('runtime') != 'native Hammerspoon'):
        raise RuntimeError('native benchmark result has an invalid measurement contract')


def cleanup(native, executable, launcher):
    # A fresh copy is exclusive to this invocation. Retain scratch on failure.
    for kind, budget in [(signal.SIGTERM, 5), (signal.SIGKILL, 3)]:
        deadline = time.monotonic() + budget
        while True:
            owners = native.matching(executable)
            if not owners:
                break
            for pid in owners:
                native.signal(pid, executable, kind)
            if time.monotonic() >= deadline:
                break
            time.sleep(0.1)
        if not native.matching(executable):
            break
    if native.matching(executable):
        raise RuntimeError('exact Hammerspoon owner did not exit')
    try:
        launcher.wait(timeout=3)
    except subprocess.TimeoutExpired:
        launcher.terminate()
        try:
            launcher.wait(timeout=3)
        except subprocess.TimeoutExpired:
            launcher.kill()
            launcher.wait(timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path,
                        help='fresh, nonexistent result directory')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('unsupported: requires native macOS and Hammerspoon')
    app = args.app.resolve(strict=True)
    if not (app / 'Contents/MacOS/Hammerspoon').is_file():
        parser.error('--app must identify Hammerspoon.app')
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    scratch = Path(tempfile.mkdtemp(prefix='ergopti-metrics-hs-')).resolve()
    report = {'status': 'error', 'ui': 'unmeasured', 'scratch': str(scratch)}
    launcher = None
    native = None
    executable = scratch / 'Hammerspoon.app/Contents/MacOS/Hammerspoon'
    failure = None
    try:
        subprocess.run(['/usr/bin/ditto', str(app), str(scratch / 'Hammerspoon.app')],
                       check=True, timeout=60)
        here = Path(__file__).resolve().parent
        shutil.copyfile(here / 'init.lua', scratch / 'init.lua')
        (scratch / 'bench-config.json').write_text(json.dumps({
            'repo_root': str(here.parents[2]), 'output_dir': str(output.resolve())
        }), encoding='utf-8')
        native = NativeProcesses()
        with (output / 'launch.log').open('wb') as log:
            launcher = subprocess.Popen([
                '/usr/bin/open', '-n', '-g', '-W', str(scratch / 'Hammerspoon.app'),
                '--args', '-MJConfigFile', str(scratch / 'init.lua')
            ], stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 60
            observed = False
            while time.monotonic() < deadline:
                observed = observed or bool(native.matching(executable))
                result_path = output / 'result.json'
                if result_path.exists():
                    try:
                        result = json.loads(result_path.read_text(encoding='utf-8'))
                    except json.JSONDecodeError:
                        # The producer writes directly; publication may still be in flight.
                        time.sleep(0.05)
                        continue
                    validate_result(result)
                    if not observed:
                        raise RuntimeError('no exact native Hammerspoon process was observed')
                    report.update(status='ok', native_process_observed=True,
                                  gui_paint='unmeasured', result=result)
                    break
                if launcher.poll() is not None:
                    raise RuntimeError('Launch Services exited before a benchmark receipt')
                time.sleep(0.05)
            else:
                raise RuntimeError('native benchmark exceeded the 60-second deadline')
    except Exception as error:
        failure = str(error)
    finally:
        if launcher is not None:
            try:
                cleanup(native, executable, launcher)
                report['cleanup'] = 'confirmed'
            except Exception as error:
                failure = (failure + '; ' if failure else '') + 'cleanup: ' + str(error)
        if failure:
            report.update(status='error', error=failure)
        (output / 'supervisor.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report))
    return 0 if report['status'] == 'ok' else 1


if __name__ == '__main__':
    sys.exit(main())
