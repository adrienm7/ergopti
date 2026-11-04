import os, pathlib, subprocess, tempfile, time, shlex

PORT = "/workspace/ergopti/static/ergopti_plus/macos/tests/support/release_rename_physical_port.py"
LUA = "/workspace/scratch/parity-toolchain/ci-bin/lua"
SCRIPT = str(pathlib.Path(__file__).with_suffix(".lua"))


def write(p, s, executable=False):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(s)
    if executable:
        p.chmod(0o700)


for scenario in ["accepted", "refused"]:
    with tempfile.TemporaryDirectory(prefix="macos-updater-audit-") as tmp:
        d = pathlib.Path(tmp)
        app = d / "ErgoptiPlus.app"
        staged = d / "stage/app/ErgoptiPlus.app"
        previous = d / "ErgoptiPlus.app.previous"
        write(app / "marker", "ORIGINAL")
        write(staged / "marker", "CHOSEN")
        write(
            app / "Contents/MacOS/ErgoptiPlus",
            "#!/bin/sh\nexec python3 -B " + shlex.quote(PORT) + ' "$@"\n',
            True,
        )
        write(d / "stat-port", '#!/bin/sh\nfor path do :; done; exec stat -c %d "$path"\n', True)
        write(
            d / "open-port",
            '#!/bin/sh\nprintf "%s\\n" "$2" >> ' + shlex.quote(str(d / "opened")) + "\n",
            True,
        )
        sleeper = subprocess.Popen(["sleep", "15"])
        lua = subprocess.Popen(
            [LUA, SCRIPT, tmp, str(sleeper.pid), scenario],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        worker = None
        try:
            assert lua.stdout.readline().strip() == "WAITING_FOR_PHYSICAL_ARMING"
            # Retain real file lease and kernel exclusive rename through existing test-only Linux port.
            command = [
                "python3",
                "-B",
                PORT,
                "--release-rename",
                "lock",
                str(app),
                (d / "swap.sh").read_text(),
                str(sleeper.pid),
                str(staged),
                str(previous),
            ]
            with (d / "worker-output").open("w") as out:
                worker = subprocess.Popen(
                    [
                        "/bin/sh",
                        "-c",
                        'exec "$@" 3>' + shlex.quote(str(d / "ack")),
                        "audit",
                        *command,
                    ],
                    stdout=out,
                    stderr=subprocess.STDOUT,
                )
            deadline = time.monotonic() + 5
            while (
                not (d / "ack").exists() or (d / "ack").read_text() != "ARMED\n"
            ) and time.monotonic() < deadline:
                assert worker.poll() is None, (d / "worker-output").read_text()
                time.sleep(0.01)
            assert (d / "ack").read_text() == "ARMED\n"
            lua.stdin.write("ARMED\n")
            lua.stdin.flush()
            remaining = lua.communicate(timeout=5)[0]
            assert lua.returncode == 0, remaining
            assert (app / "marker").read_text() == "ORIGINAL" and worker.poll() is None
            print(scenario, remaining.strip(), sep="\n")
            duplicate = subprocess.run(
                command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=3
            )
            assert duplicate.returncode == 4, duplicate.stdout
            print("concurrent installer: lease refused exit=4; first stage retained")
            sleeper.terminate()
            sleeper.wait(timeout=3)
            worker.wait(timeout=5)
            assert worker.returncode == 0, (d / "worker-output").read_text()
            assert (app / "marker").read_text() == "CHOSEN" and (
                previous / "marker"
            ).read_text() == "ORIGINAL"
            print("after private launcher exit: app=CHOSEN previous=ORIGINAL worker=0")
        finally:
            for p in [lua, worker, sleeper]:
                if p is not None and p.poll() is None:
                    p.kill()
                    p.wait()
