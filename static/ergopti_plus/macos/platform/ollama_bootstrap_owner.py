# platform/ollama_bootstrap_owner.py
"""Retain private network bytes until the exact native child image is admitted."""

import importlib.util
import os
from pathlib import Path


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


OWNER = load(
    "ergopti_bootstrap_session_owner", Path(__file__).with_name("suspended_image_owner.py")
)
ImageRefusal = OWNER.ImageRefusal
POLICY = load(
    "ergopti_shared_network_bootstrap",
    Path(__file__).absolute().parents[2] / "_shared/python/managed_ollama_bootstrap.py",
)


class BootstrapPolicy:
    """Expose shared policy with this native owner's fixed failure type."""

    def __init__(self, contract_path, proxy_policy, *, expected_contract_sha256=None):
        try:
            self.shared = POLICY.BootstrapPolicy(
                contract_path, proxy_policy, expected_contract_sha256=expected_contract_sha256
            )
        except POLICY.BootstrapRefusal as error:
            raise ImageRefusal(str(error)) from error

    def __getattr__(self, name):
        return getattr(self.shared, name)

    def capture(self, idle_timeout_ms):
        try:
            return NetworkSnapshot(self.shared.capture(idle_timeout_ms))
        except POLICY.BootstrapRefusal as error:
            raise ImageRefusal(str(error)) from error


class NetworkSnapshot:
    """Native error mapping delegates all private policy/envelope bytes to shared."""

    def __init__(self, shared):
        self.shared = shared

    def store_fields(self):
        return self.shared.store_fields()

    def authenticated_bytes(self, session_bytes, token):
        try:
            return self.shared.authenticated_bytes(session_bytes, token)
        except POLICY.BootstrapRefusal as error:
            raise ImageRefusal(str(error)) from error


class EmptyNetworkBootstrap(OWNER.EmptySession):
    """Borrow the admitted session directory; retain a distinct exclusive file."""

    @classmethod
    def acquire(cls, session, snapshot, *, register):
        value = cls.acquire_sibling(session, "network", register=register)
        value.snapshot = snapshot
        return value

    def fields(self):
        self.validate()
        return {
            "bootstrap_path": str(self.path),
            "bootstrap_device": str(self._file_identity.st_dev),
            "bootstrap_inode": str(self._file_identity.st_ino),
            **self.snapshot.store_fields(),
        }

    def release_key(self, operation):
        if (
            operation is not self._operation
            or operation.image_ready is not True
            or operation.physically_retired is True
            or self._written
            or self.session._operation is not operation
            or not self.session._written
        ):
            raise ImageRefusal("state")
        self.validate()
        self.session.validate()
        operation.recheck_source()
        payload = self.snapshot.authenticated_bytes(
            self.session._written, self.session.data["token"]
        )
        while len(self._written) < len(payload):
            operation.progress()
            count = os.write(self._file_fd, payload[len(self._written) :])
            if count <= 0:
                raise ImageRefusal("session")
            self._written += payload[len(self._written) : len(self._written) + count]
        os.fsync(self._file_fd)
        self.validate()
        self.session.validate()
        operation.recheck_source()
