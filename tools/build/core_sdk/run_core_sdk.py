"""Fixed manual native Core SDK entrypoint; no source/recipe/command arguments."""

import hashlib
import importlib.util
import os
from pathlib import Path
import sys

RECEIVER_SHA = "ce835e9a59a5dd40e1aaba793f432cc87b580b03d99d4c9a2778f323ebb2e9f0"
_path = Path(__file__).resolve().with_name("receive_core_sdk.py")
_before = _path.lstat()
_data = _path.read_bytes()


def _input_identity(info):
    return (
        info.st_dev,
        info.st_ino,
        info.st_uid,
        info.st_mode,
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


if hashlib.sha256(_data).hexdigest() != RECEIVER_SHA or _input_identity(
    _path.lstat()
) != _input_identity(_before):
    raise RuntimeError("Fixed SDK receiving source changed")
_name = "fixed_operational_sdk_receiver"
_spec = importlib.util.spec_from_loader(_name, loader=None)
_receiver = importlib.util.module_from_spec(_spec)
_receiver.__file__ = str(_path)
sys.modules[_name] = _receiver
exec(compile(_data, str(_path), "exec"), _receiver.__dict__)
receive = _receiver.receive


def main():
    if len(sys.argv) != 1:
        raise RuntimeError("SDK entrypoint accepts no arguments")
    repository = Path(__file__).resolve().parents[3]
    raw = os.environ.get("RUNNER_TEMP", "")
    temporary = Path(raw)
    if (
        not raw
        or not temporary.is_absolute()
        or temporary.resolve(strict=True) != temporary
        or not temporary.is_dir()
    ):
        raise RuntimeError("Actual hosted temporary root unavailable")
    owner = temporary / "ergoptiplus-core-sdk-operational"
    owner.mkdir(mode=0o700, exist_ok=False)
    attempt = receive(repository, owner)
    if attempt.receipt is None:
        # A refused original debt must stay retained in this original process;
        # the outer real guardian remains responsible and times out honestly.
        if attempt in sys.modules[receive.__module__]._REFUSED:
            import signal

            while not attempt.settle():
                signal.pause()
        raise RuntimeError("Actual Core SDK receiving refused")
    attempt.module.exclusive_receipt(owner / "RESULT.json", attempt.receipt)
    print(
        "PASS actual installed CLI, Console and Core SDK compilation and six native observer controls; installation/input/image retirement unqualified"
    )
    return 0


if __name__ == "__main__":
    try:
        status = main()
    except BaseException as error:
        print("Core SDK receiving refused: " + type(error).__name__, file=sys.stderr)
        sys.exit(1)
    sys.exit(status)
