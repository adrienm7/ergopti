import os, pathlib, resource, signal, subprocess, tempfile

source = os.environ.get("ERGOPTI_AUDIT_SOURCE_ROOT")
if not source:
    raise SystemExit("ERGOPTI_AUDIT_SOURCE_ROOT required")
powershell = os.environ.get("ERGOPTI_AUDIT_PWSH", "/workspace/scratch/parity-toolchain/ci-bin/pwsh")


def bounded_file_size():
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    resource.setrlimit(resource.RLIMIT_FSIZE, (1024, 1024))


with tempfile.TemporaryDirectory(prefix="ergopti-wdg-crash-private-") as private:
    result = subprocess.run(
        [
            powershell,
            "-NoLogo",
            "-NoProfile",
            "-File",
            str(pathlib.Path(__file__).with_suffix(".ps1")),
            "-SourceRoot",
            source,
            "-PrivateRoot",
            private,
        ],
        capture_output=True,
        text=True,
        preexec_fn=bounded_file_size,
        timeout=45,
    )
    print(
        "LIMIT: actual Linux per-process file-size ceiling 1024 bytes; no business function substituted"
    )
    print(result.stdout, end="")
    print(result.stderr, end="")
    print("EXIT", result.returncode)
    raise SystemExit(result.returncode)
