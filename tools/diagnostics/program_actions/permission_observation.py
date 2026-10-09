#!/usr/bin/env python3
# tools/diagnostics/program_actions/permission_observation.py
"""Decode fixed SDK permission metadata through the existing owned query custody.

This library does not admit a helper. Its caller must first verify the existing
signed-helper provenance. The worker's observation cannot qualify osascript's
TCC principal, catalogue discovery, invocation, or the cause of a stalled query.
"""

import json

from run_signed_query_probe import QueryProtocol, Refused, SignedQuery, require, unique

OPERATION = "permission-observation"
KEYS = {
    "version",
    "nonce",
    "operation",
    "observation",
    "target",
    "event_class",
    "event_id",
    "ask_user",
    "osstatus",
}


def valid_nonce(value):
    """Use the native worker's positive, exactly representable nonce domain."""
    return type(value) is int and 0 < value <= 9007199254740991


class PermissionProtocol(QueryProtocol):
    """Keep the original bounded Q1 transport; decode diagnostic metadata only."""

    def decode(self, operation, nonce, identifier=None):
        require(
            operation == OPERATION and valid_nonce(nonce) and identifier is None,
            "invalid_request",
        )
        require(
            self.held
            and self.receipt
            and self.status == 0
            and not self.pending
            and not self.buffer
            and self.payload is not None,
            "query_refused",
        )
        try:
            packet = json.loads(self.payload.decode("utf-8"), object_pairs_hook=unique)
        except (UnicodeError, ValueError):
            raise Refused("invalid_reply") from None
        require(
            type(packet) is dict
            and set(packet) == KEYS
            and type(packet["version"]) is int
            and packet["version"] == 1
            and type(packet["nonce"]) is int
            and packet["nonce"] == nonce
            and packet["operation"] == OPERATION
            and packet["target"] == "shortcuts-events"
            and packet["event_class"] == "core"
            and packet["event_id"] == "getd"
            and packet["ask_user"] is False
            and type(packet["osstatus"]) is int
            and -2147483648 <= packet["osstatus"] <= 2147483647
            and (
                packet["observation"] == "native-returned"
                or packet["observation"] == "address-refused"
                and packet["osstatus"] != 0
            ),
            "invalid_reply",
        )
        return packet


class PermissionQuery(SignedQuery):
    """Reuse the signed supervisor's unchanged acquisition and retirement lifecycle."""

    def _make_protocol(self):
        return PermissionProtocol()

    def query(self, operation, nonce, identifier=None, cancel_held=False):
        require(
            operation == OPERATION and valid_nonce(nonce) and identifier is None,
            "invalid_request",
        )
        return super().query(operation, nonce, cancel_held=cancel_held)

    def observe(self, nonce, cancel_held=False):
        """Return metadata after exact retirement; never return a permission grant."""
        return self.query(OPERATION, nonce, cancel_held=cancel_held)
