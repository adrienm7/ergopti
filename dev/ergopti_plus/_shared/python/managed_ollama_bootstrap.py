# _shared/python/managed_ollama_bootstrap.py
"""Canonical private envelope and original network/store policy; no native effects."""

import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import re


class BootstrapRefusal(RuntimeError):
    """Closed lexical protocol/policy errors never expose private captured bytes."""


def metadata(raw):
    def pairs(values):
        result = {}
        for name, value in values:
            if name in result:
                raise BootstrapRefusal("policy")
            result[name] = value
        return result

    try:
        return json.loads(raw, object_pairs_hook=pairs)
    except (ValueError, TypeError, UnicodeError):
        raise BootstrapRefusal("policy") from None


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode(
        "utf-8"
    )


class BootstrapPolicy:
    """Consume the canonical limits and environment names without route lookup."""

    def __init__(self, contract_path, proxy_policy, *, expected_contract_sha256=None):
        try:
            raw = Path(contract_path).read_bytes()
            data = metadata(raw)
            if expected_contract_sha256 is not None and (
                type(expected_contract_sha256) is not str
                or re.fullmatch(r"[0-9a-f]{64}", expected_contract_sha256) is None
                or not hmac.compare_digest(
                    hashlib.sha256(raw).hexdigest(), expected_contract_sha256
                )
            ):
                raise BootstrapRefusal("policy")
            if (
                set(data)
                != {
                    "schema_version",
                    "maximum_metadata_bytes",
                    "hmac_domain",
                    "trust_environment",
                    "maximum_certificate_bytes",
                    "maximum_certificate_files",
                }
                or type(data["schema_version"]) is not int
                or data["schema_version"] != 1
            ):
                raise BootstrapRefusal("policy")
            for key in (
                "maximum_metadata_bytes",
                "maximum_certificate_bytes",
                "maximum_certificate_files",
            ):
                if type(data[key]) is not int or data[key] <= 0:
                    raise BootstrapRefusal("policy")
            trust = data["trust_environment"]
            if (
                type(trust) is not list
                or not trust
                or len(set(trust)) != len(trust)
                or any(type(name) is not str or not name or "\x00" in name for name in trust)
            ):
                raise BootstrapRefusal("policy")
            if type(data["hmac_domain"]) is not str or not data["hmac_domain"]:
                raise BootstrapRefusal("policy")
            self.domain = data["hmac_domain"].encode("ascii")
            self.maximum_bytes = data["maximum_metadata_bytes"]
            self.maximum_value_bytes = proxy_policy.maximum_bytes
            self.names = tuple(
                dict.fromkeys(
                    (
                        *proxy_policy.system_lookup_environment_exclusions,
                        *proxy_policy.bypass_order,
                        *trust,
                    )
                )
            )
            self.sha256 = hashlib.sha256(raw).hexdigest()
        except (OSError, ValueError, TypeError, KeyError, UnicodeError):
            raise BootstrapRefusal("policy") from None

    def seal(self, payload, session_bytes, token):
        if (
            type(token) is not str
            or re.fullmatch(r"[0-9a-f]{64}", token) is None
            or type(payload) is not bytes
            or not 0 < len(payload) <= self.maximum_bytes
            or type(session_bytes) is not bytes
            or not session_bytes
        ):
            raise BootstrapRefusal("session")
        digest = hashlib.sha256(session_bytes).hexdigest()
        message = self.domain + digest.encode("ascii") + b"\n" + payload
        value = {
            "version": 1,
            "session_sha256": digest,
            "payload": base64.b64encode(payload).decode("ascii"),
            "mac": hmac.new(bytes.fromhex(token), message, hashlib.sha256).hexdigest(),
        }
        wire = encode(value) + b"\n"
        if len(wire) > self.maximum_bytes:
            raise BootstrapRefusal("policy")
        return wire

    def authenticate(self, wire, session_bytes, token):
        if type(wire) is not bytes or not 0 < len(wire) <= self.maximum_bytes:
            raise BootstrapRefusal("session")
        try:
            value = metadata(wire)
            if (
                type(value) is not dict
                or set(value) != {"version", "session_sha256", "payload", "mac"}
                or type(value["version"]) is not int
                or value["version"] != 1
                or any(type(value[key]) is not str for key in ("session_sha256", "payload", "mac"))
                or re.fullmatch(r"[0-9a-f]{64}", value["session_sha256"]) is None
                or re.fullmatch(r"[0-9a-f]{64}", value["mac"]) is None
            ):
                raise BootstrapRefusal("session")
            payload = base64.b64decode(value["payload"], validate=True)
            if base64.b64encode(payload).decode("ascii") != value["payload"]:
                raise BootstrapRefusal("session")
            expected = metadata(self.seal(payload, session_bytes, token))
            if not hmac.compare_digest(
                value["session_sha256"], expected["session_sha256"]
            ) or not hmac.compare_digest(value["mac"], expected["mac"]):
                raise BootstrapRefusal("session")
            return payload
        except (TypeError, ValueError, UnicodeError):
            raise BootstrapRefusal("session") from None

    def capture(self, idle_timeout_ms):
        """Capture original process settings; preserve case, empty values and raw store."""
        if type(idle_timeout_ms) is not int or not 1 <= idle_timeout_ms <= 2**31 - 1:
            raise BootstrapRefusal("policy")
        try:
            environment = [[name, os.environ[name]] for name in self.names if name in os.environ]
            value = os.environ.get("OLLAMA_MODELS", "")
            if (
                any(len(item.encode("utf-8")) > self.maximum_value_bytes for _, item in environment)
                or len(value.encode("utf-8")) > self.maximum_value_bytes
            ):
                raise BootstrapRefusal("policy")
            cwd = os.getcwd()
            if (
                not os.path.isabs(cwd)
                or "\x00" in cwd
                or any("\x00" in item for _, item in environment)
            ):
                raise BootstrapRefusal("policy")
            payload = {
                "environment": environment,
                "store": {
                    "mode": "environment" if value else "default",
                    "value": value,
                    "cwd": cwd,
                },
                "idle_timeout_ms": idle_timeout_ms,
            }
            if "\x00" in value:
                raise BootstrapRefusal("policy")
            wire = encode(payload)
            if not 0 < len(wire) <= self.maximum_bytes:
                raise BootstrapRefusal("policy")
            return NetworkSnapshot(self, wire, payload["store"])
        except (OSError, UnicodeError, ValueError):
            raise BootstrapRefusal("policy") from None


class NetworkSnapshot:
    """Private immutable capture; no child environment or log serialization."""

    def __init__(self, policy, payload, store):
        self.policy = policy
        self._payload = bytes(payload)
        self._store = dict(store)

    def store_fields(self):
        return {
            "store_mode": self._store["mode"],
            "store_cwd": self._store["cwd"],
            "models_path": self._store["value"],
            "proxy_url": "",
        }

    def authenticated_bytes(self, session_bytes, token):
        return self.policy.seal(self._payload, session_bytes, token)
