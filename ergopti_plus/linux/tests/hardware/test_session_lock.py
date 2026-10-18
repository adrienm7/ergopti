"""Exercise the real launcher and daemon bootstrap with live flock ownership."""

import os
import pathlib
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


class SessionLockTests(unittest.TestCase):
    """Children must never keep a terminated daemon's singleton lock alive."""

    def test_direct_cli_marker_admission(self):
        driver = pathlib.Path(__file__).resolve().parents[2]
        runtime = shutil.which("luajit")
        self.assertIsNotNone(runtime, "This native regression requires Linux LuaJIT")
        with tempfile.TemporaryDirectory() as temporary:
            bootstrap = pathlib.Path(temporary) / "bootstrap.lua"
            bootstrap.write_text(
                "package.preload['compat.utf8'] = function() os.exit(0) end\n",
                encoding="utf-8",
            )
            for marker in (None, "invalid", "2", "9"):
                with self.subTest(marker=marker):
                    environment = dict(os.environ)
                    environment.pop("ERGOPTI_SESSION_LOCK_FD", None)
                    if marker is not None:
                        environment["ERGOPTI_SESSION_LOCK_FD"] = marker
                    result = subprocess.run(
                        [
                            runtime,
                            "-e",
                            "dofile(" + repr(str(bootstrap)) + ")",
                            str(driver / "ergopti_hotstrings.lua"),
                            "--help",
                        ],
                        env=environment,
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    self.assertEqual(result.returncode, 0 if marker is None else 78, result.stderr)
                    if marker is not None:
                        self.assertIn("[session_lock]", result.stderr)

    def test_child_outlives_daemon_without_retaining_lock(self):
        driver = pathlib.Path(__file__).resolve().parents[2]
        runtime = shutil.which("luajit")
        self.assertIsNotNone(runtime, "This native regression requires Linux LuaJIT")
        for termination in (signal.SIGTERM, signal.SIGKILL):
            with self.subTest(termination=termination), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                stubs = root / "bin"
                stubs.mkdir()
                ready = root / "ready"
                child_pid = root / "child.pid"
                child = None
                daemon = None
                log = root / "daemon.log"
                try:
                    # Only account lookup is controlled. The launcher, daemon's
                    # actual bootstrap, LuaJIT, fork/exec and flock are native.
                    (stubs / "id").write_text(
                        '#!/bin/bash\nif [ "$1" = -u ]; then echo 1000; '
                        "else echo 'users input uinput'; fi\n",
                        encoding="utf-8",
                    )
                    bootstrap = root / "bootstrap.lua"
                    bootstrap.write_text(
                        "package.preload['compat.utf8'] = function()\n"
                        "  assert(os.getenv('ERGOPTI_SESSION_LOCK_FD') == nil)\n"
                        "  local status = os.execute(os.getenv('TEST_CHILD_COMMAND'))\n"
                        "  assert(status == 0 or status == true)\n"
                        "  local ready = assert(io.open(os.getenv('TEST_READY'), 'w'))\n"
                        "  ready:write('ready'); ready:close()\n"
                        "  require('ffi').cdef('int pause(void);')\n"
                        "  while true do require('ffi').C.pause() end\n"
                        "end\n",
                        encoding="utf-8",
                    )
                    (stubs / "luajit").write_text(
                        "#!/bin/bash\nexec "
                        + shlex.quote(runtime)
                        + ' -e \'dofile(os.getenv("TEST_BOOTSTRAP"))\' "$@"\n',
                        encoding="utf-8",
                    )
                    for command in stubs.iterdir():
                        command.chmod(0o755)
                    environment = dict(os.environ)
                    environment.update(
                        PATH=str(stubs) + os.pathsep + environment.get("PATH", ""),
                        XDG_RUNTIME_DIR=str(root / "runtime"),
                        TEST_READY=str(ready),
                        TEST_CHILD_PID=str(child_pid),
                        TEST_BOOTSTRAP=str(bootstrap),
                        TEST_CHILD_COMMAND="sleep 30 & echo $! > " + shlex.quote(str(child_pid)),
                    )
                    # A stale marker inherited from a parent must be replaced
                    # by the launcher's actual freshly acquired descriptor.
                    environment["ERGOPTI_SESSION_LOCK_FD"] = "invalid-parent-marker"
                    with log.open("wb") as output:
                        daemon = subprocess.Popen(
                            ["bash", str(driver / "install/launch.sh"), "--service", "--tray"],
                            env=environment,
                            stdout=output,
                            stderr=output,
                        )
                    deadline = time.monotonic() + 5
                    while (
                        not ready.exists() and daemon.poll() is None and time.monotonic() < deadline
                    ):
                        time.sleep(0.01)
                    self.assertTrue(ready.exists(), log.read_text())
                    child = int(child_pid.read_text())
                    lock = root / "runtime/ergopti/ergopti.lock"
                    busy = subprocess.run(["flock", "-n", str(lock), "true"], check=False)
                    self.assertEqual(busy.returncode, 1, "The living daemon must retain its lock")
                    daemon.send_signal(termination)
                    daemon.wait(timeout=5)
                    os.kill(child, 0)
                    available = subprocess.run(["flock", "-n", str(lock), "true"], check=False)
                    self.assertEqual(
                        available.returncode,
                        0,
                        "A live external child still owns the terminated daemon's lock; restart is blocked",
                    )
                finally:
                    if daemon is not None and daemon.poll() is None:
                        daemon.kill()
                        daemon.wait(timeout=5)
                    if child is None and child_pid.exists():
                        child = int(child_pid.read_text())
                    if child is not None:
                        try:
                            os.kill(child, signal.SIGKILL)
                        except ProcessLookupError:
                            pass


if __name__ == "__main__":
    unittest.main()
