# tools/build/karabiner_package_policy.py
"""Keep signed fork bundles immutable during package installation."""

from contextlib import contextmanager
import hashlib
from pathlib import Path

POSTINSTALL_SHA256 = "d09a75a37f8d9b681074ce9b26af0fd6a6e9689fb1d5f4cdba0dd040d1ba53d4"
ICON_CALL = "'/Library/Application Support/org.pqrs/Karabiner-Elements/Karabiner-AppIconSwitcher.app/Contents/MacOS/Karabiner-AppIconSwitcher'"


def postinstall_policy(source):
    """Change only the pinned post-signing custom-icon mutation."""
    if hashlib.sha256(source).hexdigest() != POSTINSTALL_SHA256 or source.count(ICON_CALL.encode()) != 1:
        raise ValueError("Unexpected pinned postinstall source")
    return source.replace(ICON_CALL.encode(), b"# Keep the signed bundle resources immutable.", 1)


@contextmanager
def immutable_installer(path):
    """Apply the same installer policy to fresh builds and restore source ownership."""
    path = Path(path)
    original = path.read_bytes()
    modified = postinstall_policy(original)
    path.write_bytes(modified)
    try:
        yield
    finally:
        path.write_bytes(original)
