"""Execute the shipped MLX workspace owners, including real POSIX signals."""

import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "static/ergopti_plus/macos/modules/llm/ensure-mlx-deps.sh"


class WorkspaceOwnership(unittest.TestCase):
    def run_owner(self, owner, mode, caught_signal=None):
        source = SOURCE.read_text(encoding="utf-8")
        start_marker = (
            "cleanup_mlx_bootstrap_workspace() {"
            if "cleanup_mlx_bootstrap_workspace() {" in source
            else "install_pinned_uv() {"
        )
        assert source.count(start_marker) == 1
        uv = source[source.index(start_marker) : source.index('\nUV_BIN=""')]
        start = source.index("native_install_managed_python_without_python() {")
        end = source.index('\nif [ -n "$SYSTEM_PYTHON" ]; then', start)
        python = source[start:end]
        with tempfile.TemporaryDirectory(prefix="mlx workspace ") as temporary:
            folder = Path(temporary)
            ready = folder / "ready.json"
            outer_exit = folder / "outer-exit"
            wheel = folder / "fixture.whl"
            with zipfile.ZipFile(wheel, "w") as archive:
                release = (SOURCE.parent / "uv-release.sh").read_text()
                version = release.split('UV_RELEASE_VERSION="', 1)[1].split('"', 1)[0]
                archive.writestr(f"uv-{version}.data/scripts/uv", b"#!/bin/sh\nexit 0\n")
            executable = folder / "native-python"
            executable.write_text("#!/bin/sh\nexit 0\n")
            executable.chmod(0o755)
            uv_port = folder / "uv-port"
            uv_port.write_text(
                "#!/bin/bash\nset -eu\n"
                'case "$1 $2" in\n'
                '"python install") [ "$#" -eq 7 ] || exit 91; '
                '[ "$3" = "$MANAGED_EXPECTED_REQUEST" ] || exit 92; '
                '[ "$4" = --offline ] && [ "$5" = --no-config ] && '
                '[ "$6" = --python-downloads-json-url ] || exit 93; '
                '[ "$7" = "$EXPECTED_DOWNLOADS" ] || exit 94; '
                '[ "$UV_PYTHON_DOWNLOADS" = manual ] && '
                '[ -f "$UV_PYTHON_CACHE_DIR/$MANAGED_EXPECTED_BASENAME" ] || exit 95; '
                'exit "$INSTALL_STATUS";;\n'
                '"python find") [ "$#" -eq 4 ] && [ "$4" = --offline ] || exit 96; '
                'printf "%s\\n" "$NATIVE_PYTHON";;\n'
                "*) exit 97;; esac\n"
            )
            uv_port.chmod(0o755)
            port = folder / "download.py"
            port.write_text(
                "import json,os,pathlib,shutil,signal,sys\n"
                "assert len(sys.argv)==6\n"
                "url,destination,digest,empty,policy=sys.argv[1:]\n"
                "assert (url,digest,empty,policy)==(os.environ['EXPECTED_URL'],os.environ['EXPECTED_SHA'],'','resilient')\n"
                "target=pathlib.Path(destination)\n"
                "shutil.copyfile(os.environ['FIXTURE_WHEEL'],target)\n"
                "if os.environ['MODE']=='foreign':\n"
                " target.parent.rename(str(target.parent)+'.original')\n"
                " target.parent.mkdir()\n"
                " (target.parent/'foreign').write_text('retain')\n"
                "ready=pathlib.Path(os.environ['READY'])\n"
                "pending=ready.with_suffix('.pending')\n"
                "pending.write_text(json.dumps({'payload':str(target),'pid':os.getppid()}))\n"
                "pending.replace(ready)\n"
                "if os.environ['MODE']=='group_block': signal.pause()\n"
                "sys.exit(1 if os.environ['MODE']=='failure' else 0)\n"
            )
            # macOS executes the actual BSD stat; other POSIX hosts port only that
            # native API boundary and still inspect real directory identities.
            if sys.platform != "darwin":
                stat = folder / "stat-port"
                stat.write_text(
                    f"#!{sys.executable}\n"
                    "import os,sys\n"
                    "assert len(sys.argv)==4 and sys.argv[1:3]==['-f','%d:%i']\n"
                    "value=os.stat(sys.argv[3],follow_symlinks=False)\n"
                    "print(f'{value.st_dev}:{value.st_ino}')\n"
                )
                stat.chmod(0o755)
                uv = uv.replace("/usr/bin/stat", shlex.quote(str(stat)))
                python = python.replace("/usr/bin/stat", shlex.quote(str(stat)))
            script = folder / "owner.sh"
            script.write_text(
                "set -eu\nset -o pipefail\n"
                + f"SCRIPT_DIR={shlex.quote(str(SOURCE.parent))}\n"
                + "ERGOPTI_NATIVE_ARCH=arm64\nPYTHON_VERSION=3.11\n"
                + 'source "$SCRIPT_DIR/uv-release.sh"\n'
                + 'source "$SCRIPT_DIR/managed-python-release.sh"\n'
                + 'export MANAGED_EXPECTED_REQUEST="$MANAGED_PYTHON_REQUEST"\n'
                + 'export MANAGED_EXPECTED_BASENAME="$MANAGED_PYTHON_CACHE_BASENAME"\n'
                + 'export EXPECTED_DOWNLOADS="$SCRIPT_DIR/$MANAGED_PYTHON_DOWNLOADS_BASENAME"\n'
                + (
                    'export EXPECTED_URL="$UV_WHEEL_ARM64_URL"\n'
                    if owner == "uv"
                    else 'export EXPECTED_URL="$MANAGED_PYTHON_URL"\n'
                )
                + (
                    'export EXPECTED_SHA="$UV_WHEEL_ARM64_SHA256"\n'
                    if owner == "uv"
                    else 'export EXPECTED_SHA="$MANAGED_PYTHON_SHA256"\n'
                )
                + 'UV_WHEEL_ARM64_SHA256="$FIXTURE_SHA"\n'
                + ('export EXPECTED_SHA="$FIXTURE_SHA"\n' if owner == "uv" else "")
                + 'UV_BIN="$UV_PORT"\n'
                + 'log_error() { printf "%s\\n" "$*" >&2; }\n'
                + "lacks_native_slice() { return 1; }\n"
                + 'managed_bootstrap_download() { "$TEST_PYTHON" "$DOWNLOAD_PORT" "$@" || return $?; '
                + 'if [ "$MODE" = block ]; then while :; do :; done; fi; }\n'
                + uv
                + "\n"
                + python
                + "\ntrap 'printf outer > \"$OUTER_EXIT\"' EXIT\n"
                + f"if {'install_pinned_uv' if owner == 'uv' else 'native_install_managed_python_without_python'}; then\n"
                + (
                    ' [ "$ERGOPTI_BOOTSTRAP_PYTHON" = "$NATIVE_PYTHON" ] || exit 98\n'
                    if owner == "python"
                    else ' [ -x "$UV_INSTALL_DIR/uv" ] || exit 98\n'
                )
                + " exit 0\nelse exit $?; fi\n"
            )
            environment = dict(
                os.environ,
                TMPDIR=temporary,
                HOME=temporary,
                MODE=mode,
                READY=str(ready),
                OUTER_EXIT=str(outer_exit),
                TEST_PYTHON=sys.executable,
                DOWNLOAD_PORT=str(port),
                FIXTURE_WHEEL=str(wheel),
                FIXTURE_SHA=hashlib.sha256(wheel.read_bytes()).hexdigest(),
                UV_PORT=str(uv_port),
                UV_INSTALL_DIR=str(folder / "installed"),
                NATIVE_PYTHON=str(executable),
                INSTALL_STATUS="47" if mode == "install_failure" else "0",
            )
            process = subprocess.Popen(
                ["/bin/bash", str(script)],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                if not ready.exists():
                    self.fail(f"download was not reached: {process.communicate(timeout=5)!r}")
                # Owner-only cases stop after the downloader exits. Group cases
                # interrupt both the waiting owner and its live download child.
                receipt = json.loads(ready.read_text())
                if caught_signal is not None:
                    if mode == "group_block":
                        os.killpg(process.pid, caught_signal)
                    else:
                        os.kill(receipt["pid"], caught_signal)
                stdout, stderr = process.communicate(timeout=5)
                expected = (
                    -caught_signal
                    if mode == "group_block"
                    else 128 + caught_signal
                    if caught_signal
                    else (
                        47
                        if mode == "install_failure"
                        else 95
                        if mode == "foreign" and owner == "python"
                        else 1
                        if mode in {"failure", "foreign"}
                        else 0
                    )
                )
                payload = Path(receipt["payload"])
                if mode == "foreign":
                    self.assertEqual((payload.parent / "foreign").read_text(), "retain")
                    self.assertTrue(Path(str(payload.parent) + ".original").exists())
                else:
                    self.assertFalse(payload.parent.exists(), (mode, stderr))
                self.assertEqual(process.returncode, expected, (stdout, stderr))
                if mode != "group_block":
                    self.assertEqual(outer_exit.read_text(), "outer")
                print(f"PASS MLX workspace owner={owner} mode={mode} signal={caught_signal or 0}")
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=5)

    def test_signal_retirement(self):
        for owner in ("uv", "python"):
            for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                with self.subTest(owner=owner, signal=number):
                    self.run_owner(owner, "block", number)

    def test_download_process_group_retirement(self):
        for owner in ("uv", "python"):
            with self.subTest(owner=owner):
                self.run_owner(owner, "group_block", signal.SIGTERM)

    def test_success_and_download_failure(self):
        for owner in ("uv", "python"):
            for mode in ("success", "failure"):
                with self.subTest(owner=owner, mode=mode):
                    self.run_owner(owner, mode)

    def test_python_installer_status(self):
        self.run_owner("python", "install_failure")

    def test_foreign_identity_is_retained(self):
        for owner in ("uv", "python"):
            with self.subTest(owner=owner):
                self.run_owner(owner, "foreign")


if __name__ == "__main__":
    unittest.main()
