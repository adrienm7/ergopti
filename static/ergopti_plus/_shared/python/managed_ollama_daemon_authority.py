# _shared/python/managed_ollama_daemon_authority.py
"""Bind a daemon's original alias and native image identity to its private session."""

import importlib.util
import json
from pathlib import Path


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


RUNTIME = load(
    "ergopti_daemon_authority_runtime", Path(__file__).with_name("managed_ollama_runtime.py")
)
ALIASES = load(
    "ergopti_daemon_authority_alias", Path(__file__).with_name("managed_source_alias.py")
)


class AuthorityRefusal(RuntimeError):
    """Closed scalar failures never expose session or native identity bytes."""


def validate(value, session, expected_uid):
    """Receive exact proof fields; filesystem and socket admission remain native."""
    try:
        session = RUNTIME.private_session(session)
        if type(value) is not dict or set(value) != {"source_alias", "listener"}:
            raise AuthorityRefusal("session")
        proof = ALIASES.proof_fields(value["source_alias"])
        listener = value["listener"]
        if (
            type(expected_uid) is not int
            or not 0 <= expected_uid < 2**32
            or type(listener) is not dict
            or set(listener)
            != {"pid", "uid", "start_seconds", "start_microseconds", "device", "inode"}
            or type(listener["pid"]) is not int
            or not 0 < listener["pid"] < 2**31
            or type(listener["uid"]) is not int
            or listener["uid"] != expected_uid
            or proof["binary_sha256"] != session["binary_sha256"]
            or listener["device"] != session["device"]
            or listener["inode"] != session["inode"]
        ):
            raise AuthorityRefusal("session")
        ALIASES.decimal(listener["start_seconds"], 2**64 - 1)
        ALIASES.decimal(listener["start_microseconds"], 999999)
        ALIASES.decimal(listener["device"], 2**32 - 1)
        ALIASES.decimal(listener["inode"], 2**64 - 1, positive=True)
        return {"source_alias": proof, "listener": dict(listener)}
    except (RUNTIME.RuntimeRefusal, ALIASES.AliasRefusal, KeyError, TypeError, ValueError):
        raise AuthorityRefusal("session") from None


def seal(value, session_bytes, policy, expected_uid):
    try:
        session = RUNTIME.private_session(RUNTIME.metadata_bytes(session_bytes))
    except RUNTIME.RuntimeRefusal:
        raise AuthorityRefusal("session") from None
    payload = validate(value, session, expected_uid)
    raw = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return policy.seal(raw, session_bytes, session["token"])


def authenticate(wire, session_bytes, policy, expected_uid):
    """The same canonical private envelope binds exact original session bytes."""
    try:
        session = RUNTIME.private_session(RUNTIME.metadata_bytes(session_bytes))
        raw = policy.authenticate(wire, session_bytes, session["token"])
        value = RUNTIME.metadata_bytes(raw)
    except RUNTIME.RuntimeRefusal:
        raise AuthorityRefusal("session") from None
    return validate(value, session, expected_uid)
