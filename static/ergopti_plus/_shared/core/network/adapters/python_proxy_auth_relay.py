# _shared/core/network/adapters/python_proxy_auth_relay.py
"""Speak the sign-in relay's command line and read its probe line, in Python.

The Python mirror of core/network/engine/proxy_auth_relay_core.lua for the
macOS managed daemon's owner (docs/design/proxy-auth-relay.md, "macOS managed
daemon"). Pure policy over _shared/core/network/data/proxy_auth_relay.json: the
caller runs the processes. Reasons and statuses never carry a URL, host, header
or token; the shared probe vectors pin this reader to the Go relay and the Lua one.
"""

import json
from pathlib import Path
import re

# The caller-side refusal of a relay that ran and did not answer by contract
UNAVAILABLE = "relay_unavailable"
EXECUTABLE_NAME = "ergopti-proxy-relay"
CONTRACT = Path(__file__).absolute().parents[1] / "data/proxy_auth_relay.json"

_HOST = re.compile(r"[A-Za-z0-9.-]{1,253}")
_UPSTREAM = re.compile(r"http://([^/@:\s]+):([0-9]{1,5})/?")
_ORIGIN = re.compile(r"https://([^/?#@:\s]+)")


class RelayPolicyError(ValueError):
    """The contract or a caller argument is invalid; the text names no value."""


def _plain_host(host):
    host = host.lower()
    if _HOST.fullmatch(host) is None or ".." in host:
        return None
    return host


class ProxyAuthRelay:
    """The closed sets of one decoded contract."""

    def __init__(self, contract_path=CONTRACT):
        try:
            contract = json.loads(Path(contract_path).read_text(encoding="utf-8"))
            refusals = contract["refusals"]
            exits = contract["exit_codes"]
            if (
                contract["schema_version"] != 1
                or type(refusals) is not dict
                or UNAVAILABLE not in refusals
                or any(
                    re.fullmatch(r"[a-z][a-z_]*", reason) is None
                    or re.fullmatch(r"network\.relay\.[a-z_]+", key) is None
                    for reason, key in refusals.items()
                )
                or exits["ok"] != 0
                or type(exits["refused"]) is not int
                or type(exits["invalid_arguments"]) is not int
            ):
                raise RelayPolicyError("contract")
            self.refusals = frozenset(refusals)
            self.relay_user = contract["relay_user"]
            # The Kerberos variables a relay owner hands to a relay started
            # without its environment (the macOS managed daemon's guardian).
            self.sign_in_environment = tuple(contract["sign_in_environment"])
            self.max_sign_in_value_bytes = contract["max_sign_in_value_bytes"]
            if (
                not self.sign_in_environment
                or any(
                    type(name) is not str or re.fullmatch(r"[A-Z][A-Z0-9_]*", name) is None
                    for name in self.sign_in_environment
                )
                or type(self.max_sign_in_value_bytes) is not int
                or self.max_sign_in_value_bytes <= 0
            ):
                raise RelayPolicyError("contract")
            if type(self.relay_user) is not str or re.fullmatch(r"[a-z]+", self.relay_user) is None:
                raise RelayPolicyError("contract")
            self.schemes = frozenset(contract["schemes"])
            self.statuses = frozenset(contract["probe_statuses"])
            self.exits = dict(exits)
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise RelayPolicyError("contract") from error

    @staticmethod
    def upstream(proxy):
        """The plain http proxy without credentials the relay may sign in to, or None."""
        match = _UPSTREAM.fullmatch(proxy) if type(proxy) is str else None
        host = _plain_host(match.group(1)) if match else None
        if host is None or not 1 <= int(match.group(2)) <= 65535:
            return None
        return "http://%s:%d" % (host, int(match.group(2)))

    @staticmethod
    def authority(origin):
        """The CONNECT authority of a plain https origin, or None."""
        match = _ORIGIN.fullmatch(origin) if type(origin) is str else None
        host = _plain_host(match.group(1)) if match else None
        return host + ":443" if host else None

    @staticmethod
    def _timings(values, names):
        if any(type(values.get(name)) is not int or values[name] <= 0 for name in names):
            raise RelayPolicyError("timings")

    def probe_args(self, upstream, authority, timings):
        """The probe's arguments, after the executable."""
        if self.upstream(upstream) != upstream or type(authority) is not str:
            raise RelayPolicyError("upstream")
        if re.fullmatch(r"[A-Za-z0-9.-]+:[0-9]+", authority) is None:
            raise RelayPolicyError("authority")
        self._timings(timings, ("dial_ms", "handshake_ms"))
        return [
            "probe",
            "--upstream",
            upstream,
            "--authority",
            authority,
            "--dial-timeout-ms",
            str(timings["dial_ms"]),
            "--handshake-timeout-ms",
            str(timings["handshake_ms"]),
        ]

    def sign_in_values(self, environment):
        """The sign-in variables set in an environment, validated.

        Returns:
            {name: value} for each non-empty variable of sign_in_environment.

        Raises:
            RelayPolicyError: A value with a NUL or a line break, or too long.
        """
        values = {}
        for name in self.sign_in_environment:
            value = environment.get(name)
            if not value:
                continue
            if (
                any(character in value for character in "\0\r\n")
                or len(value.encode("utf-8")) > self.max_sign_in_value_bytes
            ):
                raise RelayPolicyError("sign_in_environment")
            values[name] = value
        return values

    def read_probe(self, exit_code, stdout):
        """Read a finished probe child as the Lua policy does.

        Returns:
            (status, scheme_or_reason): ("not_needed", None), ("required", scheme)
            or ("refused", reason), the reason UNAVAILABLE for anything off contract.
        """
        refused = ("refused", UNAVAILABLE)
        if type(exit_code) is not int or type(stdout) is not str:
            return refused
        match = re.fullmatch(r'(\{"schema":1,"status":"([a-z_]+)"(.*)\})\r?\n?', stdout, re.DOTALL)
        if match is None or match.group(2) not in self.statuses or "\n" in match.group(1):
            return refused
        status, rest = match.group(2), match.group(3)
        if status == "refused":
            reason = re.fullmatch(r',"reason":"([a-z_]+)"', rest)
            if exit_code not in (self.exits["refused"], self.exits["invalid_arguments"]):
                return refused
            if (
                reason is None
                or reason.group(1) not in self.refusals
                or reason.group(1) == UNAVAILABLE
            ):
                return refused
            return "refused", reason.group(1)
        if exit_code != self.exits["ok"]:
            return refused
        if status == "required":
            scheme = re.fullmatch(r',"scheme":"([a-z]+)"', rest)
            if scheme is None or scheme.group(1) not in self.schemes:
                return refused
            return "required", scheme.group(1)
        return ("not_needed", None) if rest == "" else refused
