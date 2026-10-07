# tools/diagnostics/hs274_vhd_broker_fixture.py
"""Closed native prerequisite observation; no new acquisition or root launch.

The current SDK Guardian lacks a proven root-worker retirement producer. This
fixed fixture refuses that prerequisite rather than executing an unowned UID0
socket client. Whole Core graph compilation belongs to the existing calibration.
"""

import json
import os
from pathlib import Path
import re
import stat
import sys
import time


class FixtureRefusal(RuntimeError):
    """A required native qualification constituent is unavailable."""


def observe(owner, deadline):
    if time.monotonic() >= deadline:
        raise FixtureRefusal("official_broker_fixture_deadline")
    path = Path(owner)
    if (
        not path.is_absolute()
        or str(path) != owner
        or path.resolve(strict=True) != path
        or re.fullmatch(r"ErgoptiHS274NativePolicy-[0-9A-Fa-f-]{36}", path.name) is None
    ):
        raise FixtureRefusal("official_broker_fixture_owner_refused")
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(descriptor)
        named = path.lstat()
        if (
            not stat.S_ISDIR(opened.st_mode)
            or opened.st_uid != os.getuid()
            or opened.st_mode & 0o022
            or (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino)
        ):
            raise FixtureRefusal("official_broker_fixture_owner_refused")
        if sys.platform != "darwin":
            raise FixtureRefusal("official_broker_darwin_required")
        if os.geteuid() != 0:
            raise FixtureRefusal("official_broker_root_worker_required")
        # No supported exact root-worker/process/socket retirement producer has
        # been qualified. Neither an arbitrary source path nor a caller receipt
        # may bypass this fence. In particular this is not a sudo command port.
        raise FixtureRefusal("official_broker_root_worker_retirement_unqualified")
    finally:
        os.close(descriptor)


def main(arguments):
    deadline = time.monotonic() + 25
    try:
        if len(arguments) != 1:
            raise FixtureRefusal("official_broker_fixture_arguments")
        observe(arguments[0], deadline)
    except FixtureRefusal as error:
        print(
            json.dumps(
                {
                    "qualification": "UNQUALIFIED",
                    "reason": str(error),
                    "native_broker_executed": 0,
                    "capture_qualified": False,
                },
                sort_keys=True,
            )
        )
        return 66
    except (OSError, ValueError, TypeError):
        print(
            json.dumps(
                {
                    "qualification": "UNQUALIFIED",
                    "reason": "official_broker_fixture_owner_refused",
                    "native_broker_executed": 0,
                    "capture_qualified": False,
                },
                sort_keys=True,
            )
        )
        return 66
    # observe is closed until the separate native owner producer is reviewed.
    raise RuntimeError("closed official broker fixture unexpectedly returned")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
