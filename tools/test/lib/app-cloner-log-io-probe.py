# tools/test/lib/app-cloner-log-io-probe.py

"""Observe actual App Cloner main across diagnostic I/O refusal boundaries."""

import contextlib
import errno
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import types


def run_case(
    launcher,
    name,
    directory,
    stage=None,
    after_ui=False,
    ui_error=False,
    invalid_catalogue=False,
    physical=False,
):
    """Control file/child ports while executing the actual, selected launcher."""
    loader = importlib.machinery.SourceFileLoader("appcloner_log_probe", str(launcher))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    subject = importlib.util.module_from_spec(spec)
    loader.exec_module(subject)
    original = (
        os.open,
        os.fdopen,
        subprocess.run,
        tempfile.mkdtemp,
        tempfile.tempdir,
        dict(os.environ),
        os.umask(0o077),
    )
    original_exists = os.path.exists
    events, raw_fds, streams, errors = [], [], [], []
    state = {"admitted": False, "open_attempts": 0, "file_limit": None}
    warning = io.StringIO()
    caught = None
    limit = old_signal = None
    if physical:
        import resource
        import signal

        limit = resource.getrlimit(resource.RLIMIT_FSIZE)
        old_signal = signal.getsignal(signal.SIGXFSZ)
        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)

    def enabled():
        return not after_ui or state["admitted"]

    class FileFault:
        """Retain a real stream and retire it even when a tested I/O port fails."""

        def __init__(self, actual):
            self.actual = actual

        def write(self, value):
            if stage == "write" and enabled():
                raise OSError(errno.ENOSPC, "injected diagnostic write refusal")
            return self.actual.write(value)

        def flush(self):
            if stage == "flush" and enabled():
                raise OSError(errno.ENOSPC, "injected diagnostic flush refusal")
            return self.actual.flush()

        def close(self):
            try:
                self.flush()
            finally:
                self.actual.close()
            if stage == "close" and enabled():
                raise OSError(errno.EIO, "injected diagnostic close refusal")

        def __enter__(self):
            return self

        def __exit__(self, _kind, _value, _traceback):
            self.close()
            return False

    def opened(path, *args, **kwargs):
        is_log = os.fspath(path).endswith("appcloner.log")
        if is_log:
            state["open_attempts"] += 1
            if stage == "open" and enabled():
                raise OSError(errno.EACCES, "injected diagnostic open refusal")
        fd = original[0](path, *args, **kwargs)
        if is_log:
            raw_fds.append(fd)
        return fd

    def wrapped(fd, *args, **kwargs):
        if fd in raw_fds and stage == "fdopen" and enabled():
            raise OSError(errno.EIO, "injected diagnostic stream refusal")
        actual = original[1](fd, *args, **kwargs)
        if fd not in raw_fds:
            return actual
        streams.append(actual)
        return actual if physical else FileFault(actual)

    def allocated(*args, **kwargs):
        if stage == "allocation" and kwargs.get("prefix") == "ergopti-appcloner-":
            raise OSError(errno.ENOSPC, "injected diagnostic allocation refusal")
        return original[3](*args, **kwargs)

    def resource_exists(path):
        # This one operational-failure port must not depend on an ignored icon
        # left by an earlier native build in the source checkout.
        icon = launcher.parent.parent / "Resources" / "AppIcon.icns"
        if stage == "icon" and os.fspath(path) == str(icon):
            return False
        return original_exists(path)

    def observe(argv, **kwargs):
        env = kwargs.get("env", {})
        event = {"argv": list(argv), "log_path": env.get("ERGOPTI_APPCLONER_LOG", "")}
        normal = argv[0] == "osascript" and argv[1] != "-e"
        if normal:
            path = event["log_path"]
            event["log_content"] = Path(path).read_text(encoding="utf-8") if path else ""
            event["log_mode"] = stat.S_IMODE(Path(path).stat().st_mode) if path else None
            event["directory_mode"] = (
                stat.S_IMODE(Path(path).parent.stat().st_mode) if path else None
            )
            state["admitted"] = True
            if physical and after_ui:
                resource.setrlimit(resource.RLIMIT_FSIZE, (0, limit[1]))
                state["file_limit"] = resource.getrlimit(resource.RLIMIT_FSIZE)[0]
        events.append(event)
        if stage == "icon" and argv[0] == "zsh":
            raise OSError(errno.ENOENT, "injected icon operation refusal")
        return types.SimpleNamespace(
            returncode=1 if normal and ui_error else 0,
            stdout="",
            stderr="Original native startup failure." if normal and ui_error else "",
        )

    try:
        os.environ["ERGOPTI_LOCALE"] = "en"
        os.environ.pop("ERGOPTI_LOCALES_DIR", None)
        if invalid_catalogue:
            os.environ["ERGOPTI_LOCALES_DIR"] = str(directory / "absent-catalogue")
        tempfile.tempdir = str(directory)
        os.open, os.fdopen = opened, wrapped
        subprocess.run, tempfile.mkdtemp = observe, allocated
        os.path.exists = resource_exists
        if physical and not after_ui and stage == "physical":
            resource.setrlimit(resource.RLIMIT_FSIZE, (0, limit[1]))
            state["file_limit"] = resource.getrlimit(resource.RLIMIT_FSIZE)[0]
        with contextlib.redirect_stderr(warning):
            try:
                subject.main()
            except Exception as error:
                caught = {
                    "type": type(error).__name__,
                    "errno": getattr(error, "errno", None),
                    "message": str(error),
                }
    finally:
        if physical:
            resource.setrlimit(resource.RLIMIT_FSIZE, limit)
            signal.signal(signal.SIGXFSZ, old_signal)
        os.open, os.fdopen, subprocess.run, tempfile.mkdtemp, tempfile.tempdir = original[:5]
        os.path.exists = original_exists
        os.environ.clear()
        os.environ.update(original[5])
        os.umask(original[6])
    for fd in raw_fds:
        try:
            os.fstat(fd)
            errors.append("owned descriptor remains open")
        except OSError as error:
            if error.errno != errno.EBADF:
                errors.append("unexpected descriptor refusal: " + str(error))
    remaining = []
    for path in directory.glob("ergopti-appcloner-*/appcloner.log"):
        remaining.append(
            {"content": path.read_text(encoding="utf-8"), "mode": stat.S_IMODE(path.stat().st_mode)}
        )
    return {
        "name": name,
        "events": events,
        "error": caught,
        "warnings": warning.getvalue(),
        "open_attempts": state["open_attempts"],
        "owned_fd_count": len(raw_fds),
        "physical_file_limit_bytes": state["file_limit"],
        "all_streams_closed": all(stream.closed for stream in streams),
        "descriptor_errors": errors,
        "remaining_logs": remaining,
    }


def main():
    mode, launcher = sys.argv[1], Path(sys.argv[2]).resolve()
    cases = []
    with tempfile.TemporaryDirectory(prefix="ergopti-log-io-") as root:
        root = Path(root)
        if mode == "physical":
            for name in ("healthy", "healthy-ui-error", "initial-refusal", "post-ui-refusal"):
                directory = root / name
                directory.mkdir()
                cases.append(
                    run_case(
                        launcher,
                        name,
                        directory,
                        stage="physical" if name == "initial-refusal" else None,
                        after_ui=name == "post-ui-refusal",
                        ui_error=name in ("healthy-ui-error", "post-ui-refusal"),
                        physical=True,
                    )
                )
        elif mode == "portable":
            specifications = [
                ("healthy", None, False, False, False),
                ("healthy-ui-error", None, False, True, False),
            ]
            for stage in ("open", "fdopen", "write", "flush", "close"):
                specifications += [
                    ("initial-" + stage, stage, False, False, False),
                    ("post-ui-" + stage, stage, True, True, False),
                ]
            specifications += [
                ("allocation", "allocation", False, False, False),
                ("icon-operation", "icon", False, False, False),
                ("invalid-catalogue-write-refusal", "write", False, False, True),
            ]
            for name, stage, after_ui, ui_error, invalid in specifications:
                directory = root / name
                directory.mkdir()
                cases.append(
                    run_case(launcher, name, directory, stage, after_ui, ui_error, invalid)
                )
        else:
            raise ValueError("Unknown App Cloner log probe mode")
    print(
        json.dumps(
            {
                "cases": cases,
                "permission_scope": "posix_mode_bits"
                if os.name == "posix"
                else "content_and_descriptors_only",
            }
        )
    )


if __name__ == "__main__":
    main()
