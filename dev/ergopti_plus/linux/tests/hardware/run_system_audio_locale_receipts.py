#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_system_audio_locale_receipts.py
#
# A private native PulseAudio null sink supplies actual localized pactl output.
# Production sampler, processes, gettext catalogs and Unix sockets execute for
# real. Sampler timestamps are explicit fixture inputs; no physical sound device
# or graphical session is involved, and no shell/audio adapter is mocked.

import os
import pathlib
import subprocess
import tempfile
import time


WORKER = r"""
local Metrics = require("modules.keylogger.system_metrics")
local interval = Metrics._sample_interval_ms()
local date = "2026-01-02"
Metrics.sample(0, date)
local day = assert(Metrics.sample(interval, date))
local expected = os.getenv("ERGOPTI_NATIVE_AUDIO_MUTED") == "true" and interval or 0
assert(day.audio_muted_ms == expected, "localized native mute state lost or invented elapsed time")
assert(day.awake_ms == interval and day.sleep_ms == 0)
"""


def main():
    assert os.getuid() != 0, "private audio receipts require an ordinary user"
    interpreter = os.environ.get("ERGOPTI_SYSTEM_TEST_LUA", "luajit")
    checks, failures = 0, 0
    with tempfile.TemporaryDirectory(prefix="ergopti-audio-locale-") as folder:
        root = pathlib.Path(folder)
        os.chmod(root, 0o700)
        socket = root / "native.socket"
        config = root / "start.pa"
        config.write_text(
            f'load-module module-native-protocol-unix socket="{socket}" auth-anonymous=1\n'
            "load-module module-null-sink sink_name=ergopti_synthetic\n"
            "set-default-sink ergopti_synthetic\n"
        )
        env = dict(os.environ)
        env.update({"XDG_RUNTIME_DIR": str(root), "PULSE_SERVER": "unix:" + str(socket)})
        args = [
            "pulseaudio",
            "-n",
            "--daemonize=no",
            "--use-pid-file=no",
            "--disable-shm=yes",
            "--exit-idle-time=-1",
            "--realtime=no",
            "-F",
            str(config),
        ]
        modules = os.environ.get("ERGOPTI_NATIVE_PULSE_MODULE_DIR")
        if modules:
            args += ["-p", modules]
        with (root / "server.log").open("w") as log:
            server = subprocess.Popen(args, env=env, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 5
                while True:
                    probe = subprocess.run(
                        ["pactl", "info"], env=env, capture_output=True, timeout=1
                    )
                    if probe.returncode == 0:
                        break
                    assert server.poll() is None, "owned PulseAudio server exited"
                    assert time.monotonic() < deadline, (
                        "owned PulseAudio server did not become ready"
                    )
                    time.sleep(0.02)
                for locale, yes, no in (
                    ("C", "yes", "no"),
                    ("fr_FR.UTF-8", "oui", "non"),
                    ("de_DE.UTF-8", "ja", "nein"),
                ):
                    for muted in (True, False):
                        checks += 1
                        selected = dict(env)
                        selected.update(
                            {
                                "LC_ALL": locale,
                                "LANGUAGE": locale.split("_")[0],
                                "XDG_CONFIG_HOME": str(root / (locale + str(muted)) / "config"),
                                "ERGOPTI_NATIVE_AUDIO_MUTED": "true" if muted else "false",
                                "LUA_PATH": "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
                            }
                        )
                        try:
                            subprocess.run(
                                ["pactl", "set-sink-mute", "@DEFAULT_SINK@", "1" if muted else "0"],
                                env=selected,
                                check=True,
                                capture_output=True,
                                timeout=2,
                            )
                            raw = subprocess.run(
                                ["pactl", "get-sink-mute", "@DEFAULT_SINK@"],
                                env=selected,
                                check=True,
                                capture_output=True,
                                text=True,
                                timeout=2,
                            )
                            assert raw.stdout.strip().endswith(yes if muted else no), (
                                "real gettext catalog/locale was not active"
                            )
                            child = subprocess.run(
                                [interpreter, "-e", WORKER],
                                env=selected,
                                capture_output=True,
                                text=True,
                                timeout=5,
                            )
                            assert child.returncode == 0, (child.stdout + child.stderr)[-1000:]
                            print(f"PASS native virtual audio {locale} muted={muted}", flush=True)
                        except (
                            AssertionError,
                            subprocess.TimeoutExpired,
                            subprocess.CalledProcessError,
                        ) as error:
                            failures += 1
                            print(
                                f"FAIL native virtual audio {locale} muted={muted}: {error}",
                                flush=True,
                            )
            finally:
                server.terminate()
                try:
                    server.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=3)
    print(f"Native virtual audio locale receipts: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
