# tools/diagnostics/hs_delayed_timer_probe.py
"""Observe real packaged timers through the launch gate's existing native process."""

import base64
import json
import math
import os
from pathlib import Path
import plistlib
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import threading
import time

CONTRACT = json.loads(Path(__file__).with_name("hs_delayed_timer_contract.json").read_text())
APPLE_SCRIPT_KEY = "HSAppleScriptEnabledKey"
SCRIPTING_TIMEOUT_SECONDS = 10
# Leave the existing deadline margin for JXA construction and status receipt delivery.
NO_PROMPT_NATIVE_TIMEOUT_SECONDS = 8
SCRIPT_SAMPLE_SECONDS = 1
SCRIPT_CLEANUP_TIMEOUT_SECONDS = 2
SCRIPT_SAMPLE_READ_LIMIT = 65536
SCRIPT_SAMPLE_FRAME_LIMIT = 6
SCRIPT_SAMPLE_CONTEXT_THREAD_LIMIT = 3
SCRIPT_SAMPLE_CONTEXT_FRAME_LIMIT = 24
SCRIPT_SAMPLE_CONTEXT_CHARACTER_LIMIT = 4096
SCRIPT_DIAGNOSTIC_CHARACTER_LIMIT = 8192
SCRIPT_DIAGNOSTIC_LINE_LIMIT = 128
SCRIPTING_PHASES = (
    "control",
    "constructor",
    "pid_control",
    "pid_no_prompt",
    "observation",
    "cleanup",
)
SCRIPT_DIAGNOSTIC_RECEIPT_LIMIT = len(SCRIPTING_PHASES)
CONTROL_CONTRACT = "hs.applescript.control"
PID_CONTROL_CONTRACT = "hs.applescript.pid-control"
CONSTRUCTOR_CONTRACT = "hs.applescript.constructor"
NO_PROMPT_CONTRACT = "hs.applescript.pid-no-prompt"
NO_PROMPT_SEND_OPTIONS = 3 | 0x00020000
CHECK_COUNT = (
    len(CONTRACT["boolean_observations"])
    + len(CONTRACT["remaining_limits"])
    + len(CONTRACT["deliveries"])
)


def unique_object(pairs):
    """Reject duplicate receipt fields instead of accepting the final value."""
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate native receipt field: {key}")
        result[key] = value
    return result


def validate_control_summary(summary, feature=None):
    """Require exact owned control identity without treating it as feature proof."""
    _validate_owned_control(summary, CONTROL_CONTRACT, "control", feature)


def validate_pid_control_summary(summary, feature=None):
    """Qualify only the separate PID diagnostic, never a path or feature proof."""
    _validate_owned_control(summary, PID_CONTROL_CONTRACT, "pid_control", feature)


def _validate_owned_control(summary, contract, phase, feature):
    """Check one explicitly named control's acknowledgement and native identity."""
    fields = {"schema_version", "contract", "phase", "acknowledged", "nonce", "pid", "executable"}
    if not isinstance(summary, dict) or set(summary) != fields:
        raise ValueError("The native AppleEvent control receipt is incomplete")
    for key, expected in {
        "schema_version": 1,
        "contract": contract,
        "phase": phase,
        "acknowledged": True,
    }.items():
        if type(summary[key]) is not type(expected) or summary[key] != expected:
            raise ValueError(f"Native AppleEvent control acknowledgement differs: {key}")
    if (
        type(summary["pid"]) is not int
        or summary["pid"] <= 0
        or not isinstance(summary["nonce"], str)
        or re.fullmatch(r"[0-9a-f]{32}", summary["nonce"]) is None
        or not isinstance(summary["executable"], str)
        or not summary["executable"].startswith("/")
    ):
        raise ValueError("Native AppleEvent control identity is invalid")
    if isinstance(feature, dict):
        for key in ("nonce", "pid", "executable"):
            if type(feature.get(key)) is not type(summary[key]) or feature.get(key) != summary[key]:
                raise ValueError(f"Native AppleEvent control and feature owners differ: {key}")


def validate_no_prompt_receipt(raw, nonce, pid):
    """Observe exact native admission results without granting any other proof."""
    if (
        not isinstance(raw, str)
        or len(raw) > SCRIPT_DIAGNOSTIC_CHARACTER_LIMIT
        or not raw.startswith("{")
        or not raw.endswith("}\n")
        or "\n" in raw[:-1]
    ):
        raise ValueError("The no-prompt receipt is not one bounded JSON line")
    result = json.loads(raw, object_pairs_hook=unique_object)
    expected = {
        "schema_version": 1,
        "contract": NO_PROMPT_CONTRACT,
        "phase": "pid_no_prompt",
        "nonce": nonce,
        "pid": pid,
        "send_options": NO_PROMPT_SEND_OPTIONS,
    }
    if not isinstance(result, dict) or set(result) != set(expected) | {
        "status",
        "result",
        "error_origin",
        "error_domain",
    }:
        raise ValueError("The no-prompt receipt has incomplete event fields")
    for key, value in expected.items():
        if type(result[key]) is not type(value) or result[key] != value:
            raise ValueError(f"The no-prompt event identity differs: {key}")
    status, reply, origin = result["status"], result["result"], result["error_origin"]
    domain = result["error_domain"]
    if (
        origin == "send"
        and (type(domain) is not str or not domain or len(domain) > 128)
        or origin != "send"
        and domain is not None
    ):
        raise ValueError("The no-prompt error domain is not an actual native error field")
    if type(status) is not int or not -(2**31) <= status < 2**31:
        raise ValueError("The no-prompt event status is not an actual OSStatus")
    if status == 0:
        if type(reply) is not str or reply != nonce or origin != "none":
            raise ValueError("The no-prompt reply did not acknowledge its exact nonce")
        outcome = "acknowledged"
    else:
        if reply is not None or origin not in ("send", "handler"):
            raise ValueError("The no-prompt native refusal has ambiguous reply fields")
        if status in (-1744, -1743) and origin != "send":
            raise ValueError("An event-handler error cannot establish transport admission")
        outcome = (
            {-1744: "consent_required", -1743: "denied"}.get(status, "refused")
            if domain == "NSOSStatusErrorDomain"
            else "refused"
        )
    return dict(result, outcome=outcome)


def validate_constructor_receipt(raw, nonce, pid, direct_text):
    """Require measured descriptor bytes and Unicode without admitting delivery."""
    if (
        not isinstance(raw, str)
        or len(raw) > SCRIPT_DIAGNOSTIC_CHARACTER_LIMIT
        or not raw.startswith("{")
        or not raw.endswith("}\n")
        or "\n" in raw[:-1]
    ):
        raise ValueError("The native constructor receipt is not one bounded JSON line")
    result = json.loads(raw, object_pairs_hook=unique_object)
    expected = {
        "schema_version": 1,
        "contract": CONSTRUCTOR_CONTRACT,
        "phase": "constructor",
        "constructed": True,
        "nonce": nonce,
        "pid": pid,
        "address_type": 0x6B706964,
        "event_class": 0x486D5370,
        "event_id": 0x45584543,
        "direct_type": 0x75747874,
        "direct_text": direct_text,
    }
    if not isinstance(result, dict) or set(result) != set(expected) | {"address_bytes_base64"}:
        raise ValueError("The native constructor receipt has incomplete descriptor fields")
    for key, value in expected.items():
        if type(result[key]) is not type(value) or result[key] != value:
            raise ValueError(f"The native constructor descriptor differs: {key}")
    encoded = result["address_bytes_base64"]
    if not isinstance(encoded, str) or len(encoded) != 8:
        raise ValueError("The native constructor address bytes are not a pid_t")
    try:
        address = base64.b64decode(encoded, validate=True)
    except ValueError as error:
        raise ValueError("The native constructor address bytes are invalid") from error
    if (
        len(address) != 4
        or base64.b64encode(address).decode("ascii") != encoded
        or int.from_bytes(address, sys.byteorder, signed=True) != pid
    ):
        raise ValueError("The native constructor address bytes differ from the exact owned PID")
    return result


def validate_receipt(result, nonce, pid, executable, bundle_id):
    """Judge measured native observations without trusting callback assertions."""
    fields = {
        "schema_version",
        "contract",
        "nonce",
        "pid",
        "executable",
        "bundle_id",
        "version",
        "complete",
        "observations",
        "deliveries",
        "errors",
    }
    if not isinstance(result, dict) or set(result) != fields:
        raise ValueError("The native delayed-timer receipt is incomplete or has unknown fields")
    identity = {
        "schema_version": 1,
        "contract": CONTRACT["contract"],
        "nonce": nonce,
        "pid": pid,
        "executable": str(executable),
        "bundle_id": bundle_id,
        "version": CONTRACT["runtime_version"],
        "complete": True,
    }
    for key, expected in identity.items():
        if type(result[key]) is not type(expected) or result[key] != expected:
            raise ValueError(f"Native delayed-timer identity or completion differs: {key}")
    if result["errors"] != []:
        raise ValueError(f"Native delayed-timer callbacks failed: {result['errors']!r}")
    observed = result["observations"]
    names = set(CONTRACT["boolean_observations"]) | set(CONTRACT["remaining_limits"])
    if not isinstance(observed, dict) or set(observed) != names:
        raise ValueError("The native delayed-timer observation inventory is incomplete")
    for name, expected in CONTRACT["boolean_observations"].items():
        if observed[name] is not expected:
            raise ValueError(f"Native delayed-timer observation differs: {name}")
    for name, maximum in CONTRACT["remaining_limits"].items():
        value = observed[name]
        if type(value) not in (int, float) or not math.isfinite(value) or not 0 < value <= maximum:
            raise ValueError(f"Native delayed-timer countdown differs: {name}")
    for greater, smaller in CONTRACT["greater_than"]:
        if observed[greater] <= observed[smaller]:
            raise ValueError(f"The configured countdown did not replace its override: {greater}")
    delivered = result["deliveries"]
    if not isinstance(delivered, dict) or set(delivered) != set(CONTRACT["deliveries"]):
        raise ValueError("The native delayed-timer delivery inventory is incomplete")
    for name, expected in CONTRACT["deliveries"].items():
        if type(delivered[name]) is not int or delivered[name] != expected:
            raise ValueError(f"Native delayed-timer delivery count differs: {name}")
    return {
        "schema_version": 1,
        "contract": CONTRACT["contract"],
        "runtime": "native Hammerspoon",
        "version": CONTRACT["runtime_version"],
        "complete": True,
        "checks": CHECK_COUNT,
        "nonce": nonce,
        "pid": pid,
        "executable": str(executable),
        "preference_restored": False,
    }


def validate_summary(summary):
    """Require a complete native receipt and the preference owner's restoration."""
    if not isinstance(summary, dict) or set(summary) != {
        "schema_version",
        "contract",
        "runtime",
        "version",
        "complete",
        "checks",
        "nonce",
        "pid",
        "executable",
        "preference_restored",
    }:
        raise ValueError("Missing or malformed native delayed-timer summary")
    for key, expected in {
        "schema_version": 1,
        "contract": CONTRACT["contract"],
        "runtime": "native Hammerspoon",
        "version": CONTRACT["runtime_version"],
        "complete": True,
        "checks": CHECK_COUNT,
        "preference_restored": True,
    }.items():
        if type(summary[key]) is not type(expected) or summary[key] != expected:
            raise ValueError(f"Incomplete native delayed-timer summary: {key}")
    if not isinstance(summary["nonce"], str) or len(summary["nonce"]) != 32:
        raise ValueError("Invalid native delayed-timer nonce")
    if any(char not in "0123456789abcdef" for char in summary["nonce"]):
        raise ValueError("Invalid native delayed-timer nonce")
    if type(summary["pid"]) is not int or summary["pid"] <= 0:
        raise ValueError("Invalid native delayed-timer process identity")
    if summary["executable"] != str(
        NativeDelayedTimerProbe.executable_path(Path("/Applications/ErgoptiPlus.app"))
    ):
        raise ValueError("The delayed-timer probe observed a different installed executable")


class AppleScriptPreference:
    """Snapshot and restore the physical scripting key in the owned native domain."""

    def __init__(self, domain, runner=subprocess.run):
        self.domain = domain
        self.runner = runner
        self.snapshot = None
        self.mutation_attempted = False

    def read_domain(self):
        """Read native persisted preferences; recognize only a named absent domain."""
        result = self.runner(
            ["/usr/bin/defaults", "export", self.domain, "-"], capture_output=True, timeout=10
        )
        if result.returncode:
            absent = f"Domain {self.domain} does not exist"
            if absent in [line.strip() for line in result.stderr.decode("utf-8").splitlines()]:
                return {}
            raise RuntimeError("The native scripting preference domain could not be read")
        domain = plistlib.loads(result.stdout)
        if not isinstance(domain, dict):
            raise ValueError("The native scripting preference export is not a dictionary")
        return domain

    def enable(self):
        """Enable scripting only after retaining the original physical value."""
        self.snapshot = self.read_domain()
        self.mutation_attempted = True
        result = self.runner(
            ["/usr/bin/defaults", "write", self.domain, APPLE_SCRIPT_KEY, "-bool", "true"],
            capture_output=True,
            timeout=10,
        )
        if result.returncode or self.read_domain().get(APPLE_SCRIPT_KEY) is not True:
            raise RuntimeError("The native scripting preference did not acknowledge enable")

    def restore(self):
        """Restore only the owned key after the gate has stopped its native writer."""
        if not self.mutation_attempted:
            return
        current = self.read_domain()
        if APPLE_SCRIPT_KEY in self.snapshot:
            current[APPLE_SCRIPT_KEY] = self.snapshot[APPLE_SCRIPT_KEY]
        else:
            current.pop(APPLE_SCRIPT_KEY, None)
        result = self.runner(
            ["/usr/bin/defaults", "import", self.domain, "-"],
            input=plistlib.dumps(current),
            capture_output=True,
            timeout=10,
        )
        restored = self.read_domain()
        deleted = None
        if APPLE_SCRIPT_KEY not in self.snapshot and APPLE_SCRIPT_KEY in restored:
            # An imported dictionary can merge into the domain. Omission does
            # not acknowledge removal of the key this probe temporarily owned.
            deleted = self.runner(
                ["/usr/bin/defaults", "delete", self.domain, APPLE_SCRIPT_KEY],
                capture_output=True,
                timeout=10,
            )
            restored = self.read_domain()
        if (
            result.returncode
            or (deleted is not None and deleted.returncode)
            or plistlib.dumps(restored) != plistlib.dumps(current)
        ):
            raise RuntimeError("The native scripting preference did not acknowledge restoration")


SUPPLEMENTAL_RECEIPT_LIMIT = 2048
SUPPLEMENTAL_SENDER_STAGES = (
    "constructed",
    "send_entered",
    "send_returned",
    "error_decode_entered",
    "error_decode_complete",
    "reply_decode_complete",
)


SUPPLEMENTAL_SCALAR_STAGES = (
    "nserror_construct_entered",
    "nserror_construct_returned",
    "nserror_code_entered",
    "nserror_code_returned",
    "nserror_domain_entered",
    "nserror_domain_returned",
    "descriptor_construct_entered",
    "descriptor_construct_returned",
    "descriptor_int32_entered",
    "descriptor_int32_returned",
    "nil_ref_entered",
    "nil_ref_returned",
    "absent_errn_entered",
    "absent_errn_returned",
)
SUPPLEMENTAL_DECODER_STAGES = {
    "send": (
        "reference_entered",
        "reference_returned",
        "code_entered",
        "code_returned",
        "domain_entered",
        "domain_returned",
    ),
    "handler": ("errn_entered", "errn_returned", "int32_entered", "int32_returned"),
}
SUPPLEMENTAL_PRIMITIVE_TYPES = {
    "undefined",
    "object",
    "boolean",
    "number",
    "string",
    "function",
    "symbol",
    "bigint",
}


SUPPLEMENTAL_CALIBRATION_STAGES = (
    "data_entered",
    "data_returned",
    "ref_call_entered",
    "ref_call_returned",
    "ref_read_entered",
    "ref_read_returned",
    "object_call_entered",
    "object_call_returned",
    "object_read_entered",
    "object_read_returned",
    "nullable_entered",
    "nullable_returned",
)


class NoPromptDiagnosticScope:
    """Own fresh server witnesses and sender stages without admitting a control."""

    def __init__(self, output, nonce, pid, executable, bundle_id):
        self.path = Path(tempfile.mkdtemp(prefix="no-prompt-", dir=output))
        self.identity = {
            "nonce": nonce,
            "pid": pid,
            "executable": str(executable),
            "bundle_id": bundle_id,
        }
        self.sender_pid = None
        self.allowed_names = {
            "entry.json",
            "completion.json",
            "sender.json",
            "scalar.json",
            "decoder.json",
            "calibration.json",
            "getter.json",
        }
        self.allowed_names |= {name + ".pending" for name in self.allowed_names}
        self.directory_identity = (self.path.stat().st_dev, self.path.stat().st_ino)

    def bind_sender(self, pid):
        """Bind the stage writer to the actual owned Popen child, not its target."""
        if type(pid) is not int or pid <= 0 or self.sender_pid is not None:
            raise RuntimeError("Supplemental sender identity is invalid or already bound")
        self.sender_pid = pid

    def _check_directory(self):
        """Refuse a replaced scope before reading or removing any named receipt."""
        info = self.path.lstat()
        if not stat.S_ISDIR(info.st_mode) or (info.st_dev, info.st_ino) != self.directory_identity:
            raise RuntimeError("The supplemental receipt scope changed identity")

    def read(self, name):
        """Read one bounded regular owned inode; an absent witness is an observation."""
        self._check_directory()
        path = self.path / name
        try:
            named = path.lstat()
        except FileNotFoundError:
            return None
        if not stat.S_ISREG(named.st_mode) or named.st_size > SUPPLEMENTAL_RECEIPT_LIMIT:
            raise ValueError("A supplemental receipt is nonregular or exceeds its bound")
        descriptor = os.open(
            path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
        )
        with os.fdopen(descriptor, "rb") as handle:
            opened = os.fstat(handle.fileno())
            if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (
                named.st_dev,
                named.st_ino,
            ):
                raise ValueError("A supplemental receipt changed inode")
            raw = handle.read(SUPPLEMENTAL_RECEIPT_LIMIT + 1)
            current = path.lstat()
            if not stat.S_ISREG(current.st_mode) or (current.st_dev, current.st_ino) != (
                opened.st_dev,
                opened.st_ino,
            ):
                raise ValueError("A supplemental receipt changed before admission")
        if len(raw) > SUPPLEMENTAL_RECEIPT_LIMIT or not raw.endswith(b"\n") or b"\n" in raw[:-1]:
            raise ValueError("A supplemental receipt is not one bounded JSON line")
        try:
            result = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
        except (UnicodeError, ValueError):
            # Supplemental receipts are private files, including malformed key text.
            raise ValueError("A supplemental receipt failed closed JSON decoding") from None
        if not isinstance(result, dict):
            raise ValueError("A supplemental receipt is not an object")
        return result

    def _owned_packet(self, name, contract, extra):
        packet = self.read(name)
        if packet is None:
            return None
        if type(self.sender_pid) is not int or self.sender_pid <= 0:
            raise ValueError("A present supplemental packet has no actual bound sender")
        expected = {
            "schema_version": 1,
            "contract": contract,
            "nonce": self.identity["nonce"],
            "target_pid": self.identity["pid"],
            "sender_pid": self.sender_pid,
        }
        if set(packet) != set(expected) | set(extra) or any(
            type(packet[key]) is not type(value) or packet[key] != value
            for key, value in expected.items()
        ):
            raise ValueError("A supplemental scalar packet differs from its actual owner")
        return packet

    @staticmethod
    def _fact(fact, field):
        if (
            not isinstance(fact, dict)
            or set(fact) != {"type", field}
            or not isinstance(fact["type"], str)
            or fact["type"] not in SUPPLEMENTAL_PRIMITIVE_TYPES
        ):
            raise ValueError("A supplemental scalar fact is not a closed primitive")
        value = fact[field]
        if field == "integer":
            if fact["type"] != "number" or (value is not None and type(value) is not int):
                raise ValueError("A supplemental scalar integer has the wrong type")
        elif type(value) is not bool:
            raise ValueError("A supplemental scalar flag has the wrong type")

    @staticmethod
    def _descriptor_fact(fact):
        """Admit only a native nullable projection, retaining its raw bridge type."""
        if (
            not isinstance(fact, dict)
            or set(fact) != {"raw_type", "type", "native_absent", "absent"}
            or type(fact["raw_type"]) is not str
            or fact["raw_type"] not in {"object", "function"}
            or type(fact["native_absent"]) is not bool
            or type(fact["absent"]) is not bool
            or fact["native_absent"] != fact["absent"]
            or fact["type"] != ("object" if fact["absent"] else fact["raw_type"])
        ):
            raise ValueError("A supplemental descriptor projection is not a closed native fact")

    @staticmethod
    def _fact_summary(facts, constructors=False):
        """Retain only closed getter facts, never raw domains or unexpected integers."""
        observations = []
        for key in ("code", "domain", "int32", "nil_ref", "absent_errn", "errn"):
            if key not in facts:
                continue
            fact = facts[key]
            if key in {"code", "int32"}:
                value = fact["integer"]
                if value is None:
                    summary = "unavailable"
                elif not constructors:
                    summary = "present"
                elif value == (-1712 if key == "code" else -50):
                    summary = "-1712" if key == "code" else "-50"
                else:
                    summary = "unexpected_integer"
                field = "integer"
            else:
                field = (
                    ("matches" if constructors else "recognized") if key == "domain" else "absent"
                )
                summary = "true" if fact[field] else "false"
            observations.append(f"{key}(type={fact['type']},{field}={summary})")
            if "raw_type" in fact:
                observations.append(
                    f"{key}_bridge(raw_type={fact['raw_type']},native_absent={str(fact['native_absent']).lower()})"
                )
        return "; ".join(observations) if observations else "not_observed"

    def getter_evidence(self):
        """Observe native integer getter provenance without admitting converted statuses."""
        packet = self._owned_packet("getter.json", "hs.applescript.integer-getter", {"facts"})
        if packet is None:
            return "not_observed"
        facts = packet["facts"]
        if (
            not isinstance(facts, dict)
            or not facts
            or not set(facts) <= {"calibration", "constructor", "send"}
        ):
            raise ValueError("Supplemental integer getter names are not closed")
        fields = {
            "raw_type",
            "owner_native",
            "converted_integer",
            "box_native",
            "box_raw_type",
            "box_integer",
            "box_matches",
            "control_matches",
        }
        summaries = []
        for name in ("calibration", "constructor", "send"):
            if name not in facts:
                continue
            fact = facts[name]
            if not isinstance(fact, dict) or set(fact) != fields:
                raise ValueError("Supplemental integer getter facts are not closed")
            for key in ("raw_type", "box_raw_type"):
                if type(fact[key]) is not str or fact[key] not in SUPPLEMENTAL_PRIMITIVE_TYPES:
                    raise ValueError("Supplemental integer getter type is not closed")
            for key in fields - {"raw_type", "box_raw_type", "control_matches"}:
                if type(fact[key]) is not bool:
                    raise ValueError("Supplemental integer getter flag is not Boolean")
            if (name == "send" and fact["control_matches"] is not None) or (
                name != "send" and type(fact["control_matches"]) is not bool
            ):
                raise ValueError("Supplemental integer getter control is not closed")
            if fact["box_matches"] and not (
                fact["box_native"] and fact["box_integer"] and fact["converted_integer"]
            ):
                raise ValueError("Supplemental integer getter match has no typed provenance")
            summaries.append(
                name
                + "("
                + ",".join(
                    key
                    + "="
                    + (
                        "not_applicable"
                        if fact[key] is None
                        else str(fact[key]).lower()
                        if type(fact[key]) is bool
                        else fact[key]
                    )
                    for key in (
                        "raw_type",
                        "owner_native",
                        "converted_integer",
                        "box_native",
                        "box_raw_type",
                        "box_integer",
                        "box_matches",
                        "control_matches",
                    )
                )
                + ")"
            )
        return "; ".join(summaries)

    def calibration_evidence(self):
        """Qualify a separate Cocoa out-slot without authorizing any AppleEvent."""
        packet = self._owned_packet(
            "calibration.json", "hs.applescript.nserror-calibration", {"stages", "facts", "outcome"}
        )
        if packet is None:
            return "not_observed"
        stages, facts, outcome = packet["stages"], packet["facts"], packet["outcome"]
        if (
            not isinstance(stages, list)
            or not stages
            or stages != list(SUPPLEMENTAL_CALIBRATION_STAGES[: len(stages)])
            or not isinstance(facts, dict)
            or type(outcome) is not str
            or outcome not in {"pending", "completed", "refused"}
            or (outcome == "completed" and len(stages) != len(SUPPLEMENTAL_CALIBRATION_STAGES))
        ):
            raise ValueError("Supplemental NSError calibration is outside its closed protocol")
        expected = {
            name
            for name, stage in (
                ("ref", "ref_read_returned"),
                ("object", "object_read_returned"),
                ("nullable", "nullable_returned"),
            )
            if stage in stages
        }
        if set(facts) != expected:
            raise ValueError("Supplemental NSError facts differ from completed reads")
        summaries = []
        admitted = {}
        for name in ("ref", "object"):
            if name not in facts:
                continue
            fact = facts[name]
            if (
                not isinstance(fact, dict)
                or set(fact) != {"nil_result", "nserror", "code", "domain"}
                or type(fact["nil_result"]) is not bool
                or type(fact["nserror"]) is not bool
            ):
                raise ValueError("Supplemental NSError identity facts are not closed")
            self._fact(fact["code"], "integer")
            self._fact(fact["domain"], "matches")
            admitted[name] = (
                fact["nil_result"]
                and fact["nserror"]
                and fact["code"] == {"type": "number", "integer": 3840}
                and fact["domain"] == {"type": "string", "matches": True}
            )
            value = fact["code"]["integer"]
            code = (
                "3840"
                if value == 3840
                else "unavailable"
                if value is None
                else "unexpected_integer"
            )
            summaries.append(
                f"{name}(nil={str(fact['nil_result']).lower()},nserror={str(fact['nserror']).lower()},"
                f"code_type={fact['code']['type']},code={code},domain_type={fact['domain']['type']},"
                f"matches={str(fact['domain']['matches']).lower()})"
            )
        nullable_ok = False
        if "nullable" in facts:
            fact = facts["nullable"]
            if (
                not isinstance(fact, dict)
                or set(fact) != {"raw_type", "type", "native_absent", "absent"}
                or type(fact["raw_type"]) is not str
                or fact["raw_type"] not in SUPPLEMENTAL_PRIMITIVE_TYPES
                or type(fact["type"]) is not str
                or fact["type"] not in SUPPLEMENTAL_PRIMITIVE_TYPES
                or type(fact["native_absent"]) is not bool
                or type(fact["absent"]) is not bool
            ):
                raise ValueError("Supplemental nullable descriptor facts are not closed")
            nullable_ok = (
                fact["raw_type"] in {"object", "function"}
                and fact["type"] == "object"
                and fact["native_absent"]
                and fact["absent"]
            )
            summaries.append(
                f"nullable(raw_type={fact['raw_type']},type={fact['type']},"
                f"native_absent={str(fact['native_absent']).lower()},absent={str(fact['absent']).lower()})"
            )
        qualified = outcome == "completed" and admitted.get("object", False) and nullable_ok
        return f"stage={stages[-1]}; outcome={outcome}; qualified={str(qualified).lower()}; " + (
            "; ".join(summaries) if summaries else "not_observed"
        )

    def calibration_javascript(self):
        """Exercise native NSError** holders using inert malformed UTF-8 JSON."""
        return (
            r"""
function calibrateOwnedNSError(event) {
    var stages = [], facts = {};
    function publish(outcome) {
        var data = {schema_version:1,contract:'hs.applescript.nserror-calibration',
            nonce:__NONCE__,target_pid:__PID__,
            sender_pid:Number($.NSProcessInfo.processInfo.processIdentifier),
            stages:stages,facts:facts,outcome:outcome};
        var encoded = $.NSString.stringWithString(JSON.stringify(data) + '\n').dataUsingEncoding($.NSUTF8StringEncoding);
        if (!encoded || encoded.isNil()) throw new Error('Supplemental calibration encoding refused');
        var size = Number(encoded.length);
        if (!Number.isInteger(size) || size <= 0 || size > 2048 || !encoded.writeToFileAtomically(__PATH__, true))
            throw new Error('Supplemental calibration write refused');
    }
    function stage(name, key, fact) {
        var expected = __STAGES__;
        if (name !== expected[stages.length]) throw new Error('Supplemental calibration stage refused');
        stages.push(name);
        if (key !== undefined) facts[key] = fact;
        publish('pending');
    }
    function inspect(result, error, observationName) {
        var absent = result.isNil() === true;
        var identified = error !== undefined && error !== null
            && typeof error.isNil === 'function' && error.isNil() === false
            && typeof error.isKindOfClass === 'function' && error.isKindOfClass($.NSError) === true;
        var raw = identified ? error.code : undefined;
        var code = identified ? Number(raw) : NaN;
        if (observationName !== undefined) observeOwnedIntegerGetter(observationName, error, raw, 3840);
        var domain = identified ? ObjC.unwrap(error.domain) : undefined;
        return {nil_result:absent,nserror:identified,code:integerFact(code),
            domain:{type:typeof domain,matches:domain === 'NSCocoaErrorDomain'}};
    }
    function projectNullable(descriptor) {
        // The bridge validates provenance; a JavaScript function with isNil is not an ObjC object.
        ObjC.castObjectToRef(descriptor);
        if (descriptor.isNil() !== true) throw new Error('Supplemental native nil descriptor refused');
        return null;
    }
    try {
        stage('data_entered');
        var data = $.NSString.stringWithString('[').dataUsingEncoding($.NSUTF8StringEncoding);
        if (data.isNil()) throw new Error('Supplemental inert JSON data refused');
        stage('data_returned');
        var raw = Ref();
        stage('ref_call_entered');
        var refResult = $.NSJSONSerialization.JSONObjectWithDataOptionsError(data, 0, raw);
        stage('ref_call_returned');
        stage('ref_read_entered');
        var refFact = inspect(refResult, raw[0]);
        stage('ref_read_returned', 'ref', refFact);
        var object = $();
        stage('object_call_entered');
        var objectResult = $.NSJSONSerialization.JSONObjectWithDataOptionsError(data, 0, object);
        stage('object_call_returned');
        stage('object_read_entered');
        var objectFact = inspect(objectResult, object, 'calibration');
        stage('object_read_returned', 'object', objectFact);
        stage('nullable_entered');
        var descriptor = event.paramDescriptorForKeyword(0x6572726e);
        var normalized = projectNullable(descriptor);
        stage('nullable_returned', 'nullable', {raw_type:typeof descriptor,type:typeof normalized,
            native_absent:descriptor.isNil() === true,absent:normalized === null});
        publish('completed');
    } catch (error) {
        // A calibration refusal remains separate; the original AppleEvent still runs.
        try { publish('refused'); } catch (writeError) { /* No acknowledged calibration is available. */ }
    }
}
""".replace("__NONCE__", json.dumps(self.identity["nonce"]))
            .replace("__PID__", str(self.identity["pid"]))
            .replace("__PATH__", json.dumps(str(self.path / "calibration.json")))
            .replace("__STAGES__", json.dumps(list(SUPPLEMENTAL_CALIBRATION_STAGES)))
        )

    def scalar_evidence(self, terminal=False, native=None):
        """Retain decoder boundaries independently of the original native status verdict."""
        scalar = self._owned_packet(
            "scalar.json", "hs.applescript.scalar-controls", {"stages", "facts"}
        )
        scalar_stage = "not_observed"
        scalar_qualified = False
        scalar_facts, decoder_facts = "not_observed", "not_observed"
        if scalar is not None:
            stages, facts = scalar["stages"], scalar["facts"]
            if (
                not isinstance(stages, list)
                or not stages
                or stages != list(SUPPLEMENTAL_SCALAR_STAGES[: len(stages)])
                or not isinstance(facts, dict)
            ):
                raise ValueError("Supplemental scalar stages are not a closed prefix")
            specifications = {
                "code": ("nserror_code_returned", "integer", -1712),
                "domain": ("nserror_domain_returned", "matches", True),
                "int32": ("descriptor_int32_returned", "integer", -50),
                "nil_ref": ("nil_ref_returned", "absent", True),
                "absent_errn": ("absent_errn_returned", "absent", True),
            }
            keys = {key for key, (stage, _, _) in specifications.items() if stage in stages}
            if set(facts) != keys:
                raise ValueError("Supplemental scalar facts differ from completed reads")
            for key in keys:
                if key == "absent_errn":
                    self._descriptor_fact(facts[key])
                else:
                    self._fact(facts[key], specifications[key][1])
            scalar_facts = self._fact_summary(facts, constructors=True)
            scalar_stage = stages[-1]
            scalar_qualified = (
                len(stages) == len(SUPPLEMENTAL_SCALAR_STAGES)
                and all(
                    type(facts[key][field]) is type(value) and facts[key][field] == value
                    for key, (_, field, value) in specifications.items()
                )
                and facts["domain"]["type"] == "string"
                and all(
                    facts[key]["type"] in {"object", "undefined"}
                    for key in ("nil_ref", "absent_errn")
                )
            )
        decoder = self._owned_packet(
            "decoder.json", "hs.applescript.decoder-boundaries", {"branch", "stages", "facts"}
        )
        branch, boundary = "not_observed", "not_observed"
        if decoder is not None:
            branch, stages, facts = decoder["branch"], decoder["stages"], decoder["facts"]
            if (
                not isinstance(branch, str)
                or branch not in SUPPLEMENTAL_DECODER_STAGES
                or not isinstance(stages, list)
                or not stages
                or not isinstance(facts, dict)
            ):
                raise ValueError("A supplemental decoder branch is outside its closed protocol")
            absent_route = ["errn_entered", "errn_returned", "absent_errn"]
            route = SUPPLEMENTAL_DECODER_STAGES[branch]
            if stages != list(route[: len(stages)]) and not (
                branch == "handler" and stages == absent_route
            ):
                raise ValueError("Supplemental decoder boundaries are not a closed prefix")
            specifications = (
                {
                    "code": ("code_returned", "integer"),
                    "domain": ("domain_returned", "recognized"),
                }
                if branch == "send"
                else {
                    "errn": ("errn_returned", "absent"),
                    "int32": ("int32_returned", "integer"),
                }
            )
            keys = {key for key, (stage, _) in specifications.items() if stage in stages}
            if set(facts) != keys:
                raise ValueError("Supplemental decoder facts differ from completed reads")
            for key in keys:
                if key == "errn":
                    self._descriptor_fact(facts[key])
                else:
                    self._fact(facts[key], specifications[key][1])
            decoder_facts = self._fact_summary(facts)
            boundary = stages[-1]
            if terminal:
                expected_branch = "send" if native["error_origin"] == "send" else "handler"
                if (
                    branch != expected_branch
                    or (branch == "send" and stages != list(route))
                    or (branch == "handler" and stages not in (list(route), absent_route))
                ):
                    raise ValueError("The terminal native decoder branch did not complete")
                key = "code" if branch == "send" else "int32"
                if key in facts:
                    if (
                        type(facts[key]["integer"]) is not int
                        or facts[key]["integer"] != native["status"]
                    ):
                        raise ValueError(
                            "Supplemental scalar status differs from the native receipt"
                        )
                elif native["status"] != 0 or not facts["errn"]["absent"]:
                    raise ValueError("An absent handler status differs from the native receipt")
                if branch == "send" and (
                    facts["domain"]["type"]
                    != ("string" if isinstance(native["error_domain"], str) else "object")
                    or facts["domain"]["recognized"]
                    != (native["error_domain"] == "NSOSStatusErrorDomain")
                ):
                    raise ValueError("The supplemental native domain differs from its receipt")
                if branch == "handler" and facts["errn"]["absent"] != (stages == absent_route):
                    raise ValueError("The handler descriptor presence differs from its read route")
        if terminal and (not scalar_qualified or decoder is None):
            raise ValueError("The supplemental native scalar controls did not qualify")
        return {
            "scalar_stage": scalar_stage,
            "scalar_qualified": scalar_qualified,
            "decoder_branch": branch,
            "decoder_boundary": boundary,
            "scalar_facts": scalar_facts,
            "decoder_facts": decoder_facts,
        }

    def sender_stages(self):
        """Read the same exact child-owned monotonic stage prefix during sampling."""
        sender = self.read("sender.json")
        stages = []
        if sender is not None:
            expected = {
                "schema_version": 1,
                "contract": "hs.applescript.sender-stages",
                "nonce": self.identity["nonce"],
                "target_pid": self.identity["pid"],
                "sender_pid": self.sender_pid,
            }
            if set(sender) != set(expected) | {"stages"} or any(
                type(sender[key]) is not type(value) or sender[key] != value
                for key, value in expected.items()
            ):
                raise ValueError("Supplemental sender stages differ from the actual owned child")
            stages = sender["stages"]
            if (
                not isinstance(stages, list)
                or not stages
                or stages != list(SUPPLEMENTAL_SENDER_STAGES[: len(stages)])
            ):
                raise ValueError("Supplemental sender stages are not a monotonic closed prefix")
        return stages

    def observe(self, require_completion=False, terminal=False, native=None):
        """Keep execution and sender evidence separate from the native send status."""
        present = []
        for name, phase in (("entry.json", "entry"), ("completion.json", "completion")):
            receipt = self.read(name)
            if receipt is None:
                continue
            expected = dict(
                self.identity,
                schema_version=1,
                contract="hs.applescript.server-witness",
                phase=phase,
            )
            if set(receipt) != set(expected) or any(
                type(receipt[key]) is not type(value) or receipt[key] != value
                for key, value in expected.items()
            ):
                raise ValueError("A supplemental server witness differs from its exact owner")
            present.append(phase)
        if present == ["completion"]:
            raise ValueError("A completion witness has no preceding owned entry")
        if require_completion and present != ["entry", "completion"]:
            raise ValueError("The no-prompt nonce reply has incomplete server witnesses")
        stages = self.sender_stages()
        required_stages = list(
            SUPPLEMENTAL_SENDER_STAGES if require_completion else SUPPLEMENTAL_SENDER_STAGES[:-1]
        )
        if (terminal or require_completion) and stages != required_stages:
            raise ValueError("The no-prompt native receipt lacks terminal sender stages")
        return {
            **self.scalar_evidence(terminal=terminal, native=native),
            "nserror_calibration": self.calibration_evidence(),
            "integer_getter": self.getter_evidence(),
            "server": "completed"
            if len(present) == 2
            else "entered"
            if present
            else "not_observed",
            "sender_stage": stages[-1] if stages else "not_observed",
        }

    def early_lua_journal_stage(self):
        """Observe an attempted journal write before later payload prerequisites."""
        return (
            "pcall(function() local info=type(hs)=='table' and hs.processInfo or nil; "
            "local pid=type(info)=='table' and info.processID or nil; "
            "if type(pid)~='number' or pid<=0 or pid>=2^53 or pid~=math.floor(pid) "
            "or pid~={pid} then return end; "
            "local loaded=type(package)=='table' and package.loaded or nil; "
            "local journal=type(loaded)=='table' and loaded['adapters.boot_journal'] or nil; "
            "if type(journal)~='table' or type(journal.append)~='function' then return end; "
            "journal.append('INFO',string.format('Native scripting Lua body stage: "
            "phase=received_lua_body; pid=%.0f; nonce=%s.',pid,{nonce})); end); "
        ).format(pid=self.identity["pid"], nonce=json.dumps(self.identity["nonce"]))

    def lua_parts(self):
        """Use only actual processInfo fields already qualified by the native timer."""
        identity = self.identity
        entry = json.dumps(str(self.path / "entry.json"))
        completion = json.dumps(str(self.path / "completion.json"))
        prefix = (
            "return (function() " + self.early_lua_journal_stage() + "local i=hs.processInfo; "
        ) + (
            "assert(i.processID=={pid} and i.executablePath=={exe} and i.bundleID=={bundle}, "
            "'Supplemental native owner differs'); local function publish(path,phase) "
            "local text=hs.json.encode({{schema_version=1,contract='hs.applescript.server-witness',"
            "nonce={nonce},pid=i.processID,executable=i.executablePath,bundle_id=i.bundleID,phase=phase}}); "
            "assert(type(text)=='string' and #text<2048,'Supplemental witness encoding refused'); "
            "local f=io.open(path..'.pending','wb'); assert(f,'Supplemental witness open refused'); "
            "local wrote=f:write(text..'\\n'); local closed=f:close(); "
            "assert(wrote and closed,'Supplemental witness write refused'); "
            "assert(os.rename(path..'.pending',path),'Supplemental witness commit refused'); end; "
            "publish({entry},'entry'); local function body() "
        ).format(
            pid=identity["pid"],
            exe=json.dumps(identity["executable"]),
            bundle=json.dumps(identity["bundle_id"]),
            nonce=json.dumps(identity["nonce"]),
            entry=entry,
        )
        suffix = (
            "\nend; local result=body(); assert(result=="
            + json.dumps(identity["nonce"])
            + (
                ",'Supplemental body nonce differs'); publish("
                + completion
                + ",'completion'); return result end)()"
            )
        )
        return prefix, suffix

    def javascript_prelude(self):
        """Check each atomic stage write before any subsequent native bridge call."""
        prefix, suffix = self.lua_parts()
        return (
            """
var ownedStages = [];
function recordOwnedStage(stage) {
    var expected = __STAGES__;
    if (stage !== expected[ownedStages.length]) throw new Error('Supplemental stage order refused');
    ownedStages.push(stage);
    var data = {schema_version:1,contract:'hs.applescript.sender-stages',nonce:__NONCE__,
        target_pid:__PID__,sender_pid:Number($.NSProcessInfo.processInfo.processIdentifier),stages:ownedStages};
    var encoded = $.NSString.stringWithString(JSON.stringify(data) + '\\n').dataUsingEncoding($.NSUTF8StringEncoding);
    if (!encoded || encoded.isNil()) throw new Error('Supplemental stage encoding refused');
    var size = Number(encoded.length);
    if (!Number.isInteger(size) || size <= 0 || size > 2048 || !encoded.writeToFileAtomically(__PATH__, true))
        throw new Error('Supplemental stage write refused');
}

var scalarStages = [], scalarFacts = {}, decoderStages = [], decoderFacts = {}, decoderBranch = null;
function publishOwnedPacket(name, contract, stages, facts, branch) {
    var data = {schema_version:1,contract:contract,nonce:__NONCE__,target_pid:__PID__,
        sender_pid:Number($.NSProcessInfo.processInfo.processIdentifier),stages:stages,facts:facts};
    if (branch !== undefined) data.branch = branch;
    var encoded = $.NSString.stringWithString(JSON.stringify(data) + '\\n').dataUsingEncoding($.NSUTF8StringEncoding);
    if (!encoded || encoded.isNil()) throw new Error('Supplemental packet encoding refused');
    var size = Number(encoded.length);
    if (!Number.isInteger(size) || size <= 0 || size > 2048 || !encoded.writeToFileAtomically(__ROOT__ + '/' + name, true))
        throw new Error('Supplemental packet write refused');
}
var getterFacts = {};
function observeOwnedIntegerGetter(name, owner, raw, expected) {
    // This diagnostic never authorizes a converted status or invokes a callable getter.
    var fact = {raw_type:typeof raw,owner_native:false,converted_integer:false,
        box_native:false,box_raw_type:'undefined',box_integer:false,box_matches:false,
        control_matches:expected === null ? null : false};
    var converted, boxed;
    try {
        ObjC.castObjectToRef(owner);
        fact.owner_native = owner.isNil() === false && owner.isKindOfClass($.NSError) === true;
        converted = Number(raw);
        fact.converted_integer = Number.isInteger(converted);
        if (expected !== null) fact.control_matches = fact.converted_integer && converted === expected;
        var box = $.NSNumber.numberWithInteger(raw);
        ObjC.castObjectToRef(box);
        fact.box_native = box.isNil() === false && box.isKindOfClass($.NSNumber) === true;
        if (fact.box_native) {
            var boxRaw = box.integerValue;
            fact.box_raw_type = typeof boxRaw;
            boxed = Number(boxRaw);
            fact.box_integer = Number.isInteger(boxed);
            fact.box_matches = fact.converted_integer && fact.box_integer && boxed === converted;
        }
    } catch (error) { /* Preserve a closed failed projection; do not admit the original status. */ }
    getterFacts[name] = fact;
    try {
        var data = {schema_version:1,contract:'hs.applescript.integer-getter',nonce:__NONCE__,
            target_pid:__PID__,sender_pid:Number($.NSProcessInfo.processInfo.processIdentifier),facts:getterFacts};
        var encoded = $.NSString.stringWithString(JSON.stringify(data) + '\\n').dataUsingEncoding($.NSUTF8StringEncoding);
        if (!encoded || encoded.isNil()) throw new Error('Supplemental getter encoding refused');
        var size = Number(encoded.length);
        if (!Number.isInteger(size) || size <= 0 || size > 2048 || !encoded.writeToFileAtomically(__ROOT__ + '/getter.json', true))
            throw new Error('Supplemental getter write refused');
    } catch (writeError) { /* An absent observation cannot authorize the AppleEvent. */ }
}
function projectOwnedNSErrorInteger(owner, rawCode) {
    ObjC.castObjectToRef(owner);
    if (owner.isNil() !== false || owner.isKindOfClass($.NSError) !== true || owner.code !== rawCode)
        throw new Error('Native NSError integer owner refused');
    if (typeof rawCode !== 'number' || !Number.isInteger(rawCode)) {
        if (typeof rawCode !== 'string' || !/^-?(?:0|[1-9][0-9]*)$/.test(rawCode))
            throw new Error('Native NSError integer representation refused');
        var converted = Number(rawCode);
        if (!Number.isSafeInteger(converted)) throw new Error('Native NSError integer precision refused');
        var box = $.NSNumber.numberWithInteger(rawCode);
        ObjC.castObjectToRef(box);
        if (box.isNil() !== false || box.isKindOfClass($.NSNumber) !== true)
            throw new Error('Native NSNumber integer owner refused');
        var rawBox = box.integerValue;
        if ((typeof rawBox !== 'number' && typeof rawBox !== 'string')
            || (typeof rawBox === 'string' && !/^-?(?:0|[1-9][0-9]*)$/.test(rawBox)))
            throw new Error('Native NSNumber integer representation refused');
        var boxed = Number(rawBox);
        if (!Number.isSafeInteger(boxed) || boxed !== converted || owner.code !== rawCode)
            throw new Error('Native NSNumber integer match refused');
        return boxed;
    }
    if (!Number.isSafeInteger(rawCode)) throw new Error('Native NSError integer precision refused');
    return rawCode;
}
function integerFact(value) { return {type:typeof value,integer:Number.isInteger(value) ? value : null}; }
function projectOwnedDescriptor(descriptor) {
    ObjC.castObjectToRef(descriptor);
    var absent = descriptor.isNil();
    if (absent === true) return null;
    if (absent !== false || descriptor.isKindOfClass($.NSAppleEventDescriptor) !== true)
        throw new Error('Supplemental native descriptor identity refused');
    return descriptor;
}
function descriptorFact(raw, projected) {
    return {raw_type:typeof raw,type:typeof projected,native_absent:raw.isNil() === true,absent:projected === null};
}
function recordScalar(stage, key, fact) {
    var expected = __SCALAR_STAGES__;
    if (stage !== expected[scalarStages.length]) throw new Error('Supplemental scalar order refused');
    scalarStages.push(stage);
    if (key !== undefined) scalarFacts[key] = fact;
    publishOwnedPacket('scalar.json','hs.applescript.scalar-controls',scalarStages,scalarFacts);
}
function qualifyOwnedScalars(reply) {
    recordScalar('nserror_construct_entered');
    var nativeError = $.NSError.errorWithDomainCodeUserInfo('NSOSStatusErrorDomain', -1712, $());
    recordScalar('nserror_construct_returned');
    recordScalar('nserror_code_entered');
    var constructorRawCode = nativeError.code;
    var code = Number(constructorRawCode);
    recordScalar('nserror_code_returned','code',integerFact(code));
    observeOwnedIntegerGetter('constructor', nativeError, constructorRawCode, -1712);
    recordScalar('nserror_domain_entered');
    var domain = ObjC.unwrap(nativeError.domain);
    recordScalar('nserror_domain_returned','domain',{type:typeof domain,matches:domain === 'NSOSStatusErrorDomain'});
    recordScalar('descriptor_construct_entered');
    var errorNumber = $.NSAppleEventDescriptor.descriptorWithInt32(-50);
    recordScalar('descriptor_construct_returned');
    recordScalar('descriptor_int32_entered');
    var number = Number(errorNumber.int32Value);
    recordScalar('descriptor_int32_returned','int32',integerFact(number));
    recordScalar('nil_ref_entered');
    var reference = Ref(), missing = reference[0];
    recordScalar('nil_ref_returned','nil_ref',{type:typeof missing,absent:!missing || missing.isNil()});
    recordScalar('absent_errn_entered');
    var absent = reply.paramDescriptorForKeyword(0x6572726e);
    var projected = projectOwnedDescriptor(absent);
    recordScalar('absent_errn_returned','absent_errn',descriptorFact(absent, projected));
}
function recordDecoderBoundary(branch, stage, key, fact) {
    var routes = __DECODER_STAGES__;
    if (decoderBranch !== null && decoderBranch !== branch) throw new Error('Supplemental decoder branch changed');
    decoderBranch = branch;
    var expected = routes[branch];
    if (!expected || (stage !== expected[decoderStages.length] && !(branch === 'handler' && stage === 'absent_errn' && decoderStages.length === 2 && decoderFacts.errn.absent)))
        throw new Error('Supplemental decoder order refused');
    decoderStages.push(stage);
    if (key !== undefined) decoderFacts[key] = fact;
    publishOwnedPacket('decoder.json','hs.applescript.decoder-boundaries',decoderStages,decoderFacts,branch);
}
function ownedWitnessSource(source, pid, nonce) {
    if (pid !== __PID__ || nonce !== __NONCE__) throw new Error('Supplemental source owner refused');
    return __PREFIX__ + source + __SUFFIX__;
}
""".replace("__STAGES__", json.dumps(list(SUPPLEMENTAL_SENDER_STAGES)))
            .replace("__SCALAR_STAGES__", json.dumps(list(SUPPLEMENTAL_SCALAR_STAGES)))
            .replace("__DECODER_STAGES__", json.dumps(SUPPLEMENTAL_DECODER_STAGES))
            .replace("__ROOT__", json.dumps(str(self.path)))
            .replace("__NONCE__", json.dumps(self.identity["nonce"]))
            .replace("__PID__", str(self.identity["pid"]))
            .replace("__PATH__", json.dumps(str(self.path / "sender.json")))
            .replace("__PREFIX__", json.dumps(prefix))
            .replace("__SUFFIX__", json.dumps(suffix))
        )

    def cleanup(self):
        """Acknowledge removal only inside the still-owned fresh receipt directory."""
        self._check_directory()
        names = {entry.name for entry in self.path.iterdir()}
        if not names <= self.allowed_names:
            raise RuntimeError("Supplemental scope cleanup has an unknown neighbour")
        for name in names:
            path = self.path / name
            info = path.lstat()
            if stat.S_ISDIR(info.st_mode):
                raise RuntimeError("Supplemental scope cleanup has a foreign directory")
            path.unlink()
            if path.exists() or path.is_symlink():
                raise RuntimeError("Supplemental receipt removal was not acknowledged")
        self.path.rmdir()
        if self.path.exists() or self.path.is_symlink():
            raise RuntimeError("Supplemental scope removal was not acknowledged")


class NoPromptServerSample:
    """Own one sampler thread/process; never detach it or admit a late sample."""

    def __init__(self, scope, pid, sample):
        self.scope = scope
        self.pid = pid
        self.sample = sample
        self.stop = threading.Event()
        self.thread = threading.Thread(
            target=self._run, name="owned-no-prompt-sample", daemon=False
        )
        self.started = False
        self.process = None
        self.interval_qualified = False
        self.reason = "send_not_observed"

    def start(self):
        self.thread.start()
        self.started = True

    def _run(self):
        try:
            deadline = time.monotonic() + SCRIPTING_TIMEOUT_SECONDS
            while not self.stop.is_set() and time.monotonic() < deadline:
                stages = self.scope.sender_stages()
                if stages == list(SUPPLEMENTAL_SENDER_STAGES[:2]):
                    if self.sample.exists() or self.sample.is_symlink():
                        self.reason = "sample_path_not_fresh"
                        return
                    # The stage packet is bound to the actual sender PID and scope.
                    # Sampling has no pipes that could block its retirement.
                    self.process = subprocess.Popen(
                        [
                            "/usr/bin/sample",
                            str(self.pid),
                            str(SCRIPT_SAMPLE_SECONDS),
                            "-file",
                            str(self.sample),
                        ],
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                    starting_stages = self.scope.sender_stages()
                    deadline = time.monotonic() + SCRIPT_CLEANUP_TIMEOUT_SECONDS
                    while not self.stop.is_set() and time.monotonic() < deadline:
                        try:
                            self.process.wait(timeout=0.02)
                            break
                        except subprocess.TimeoutExpired:
                            continue
                    if self.process.returncode is None:
                        self.reason = "sampler_cancelled_or_timed_out"
                        return
                    ending_stages = self.scope.sender_stages()
                    self.interval_qualified = (
                        not self.stop.is_set()
                        and type(self.process.returncode) is int
                        and self.process.returncode == 0
                        and starting_stages == stages
                        and ending_stages == stages
                    )
                    self.reason = (
                        "inflight_interval"
                        if self.interval_qualified
                        else "sampler_refused_or_send_interval_changed"
                    )
                    return
                if len(stages) > 2:
                    self.reason = "send_already_returned"
                    return
                self.stop.wait(0.02)
        except Exception:
            # Never project arbitrary worker exceptions, receipt text or arguments.
            self.reason = "sampler_observation_refused"
        finally:
            if self.process is not None and self.process.returncode is None:
                try:
                    self.process.kill()
                    self.process.wait(timeout=SCRIPT_CLEANUP_TIMEOUT_SECONDS)
                    if self.process.returncode is None:
                        raise RuntimeError("Owned sampler exit was not acknowledged")
                except Exception:
                    self.reason = "owned_sampler_retirement_unacknowledged"

    def finish(self):
        """Refuse progress while this exact sampler or worker retains physical debt."""
        self.stop.set()
        if self.started:
            self.thread.join(timeout=SCRIPT_CLEANUP_TIMEOUT_SECONDS)
            if self.thread.is_alive():
                raise RuntimeError("Owned no-prompt sampler worker has not retired")
        if self.process is not None and self.process.returncode is None:
            # A previous bounded retirement failure may be retried by restore().
            self.process.kill()
            self.process.wait(timeout=SCRIPT_CLEANUP_TIMEOUT_SECONDS)
            if self.process.returncode is None:
                raise RuntimeError("Owned no-prompt sampler process has not retired")
        return self.interval_qualified


class ManagedLaunchObservation:
    """Own one concurrent AppKit read; its result never admits AppleEvents."""

    CONTRACT = "hs.managed.public-launch-state"

    def __init__(self, pid, executable, domain, nonce, processes):
        self.pid, self.executable, self.domain = pid, executable, domain
        self.nonce, self.processes = nonce, processes
        self.process = None
        self.thread = None
        self.packet = None
        self.failure = "unobserved"
        self.created = time.monotonic()
        self.query_begin = self.query_end = None
        self.control_begin = self.control_end = None
        self.stop = threading.Event()

    @staticmethod
    def script():
        # Native getters are deliberately not coerced: native calibration owns their ABI.
        return """ObjC.import('AppKit');
ObjC.import('Foundation');
function run(argv) {
    try {
        var pid = Number(argv[0]);
        if (!Number.isSafeInteger(pid) || pid <= 0) throw Error('identity');
        var app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(pid);
        ObjC.castObjectToRef(app);
        if (app.isNil() !== false || app.isKindOfClass($.NSRunningApplication) !== true)
            throw Error('class');
        var observedPid = app.processIdentifier;
        var terminated = app.isTerminated;
        var finished = app.isFinishedLaunching;
        var path = ObjC.unwrap(app.executableURL.path);
        var bundle = ObjC.unwrap(app.bundleIdentifier);
        if (typeof observedPid !== 'number' || observedPid !== pid
            || typeof terminated !== 'boolean' || terminated !== false
            || typeof finished !== 'boolean' || typeof path !== 'string'
            || typeof bundle !== 'string' || path !== argv[1] || bundle !== argv[2])
            throw Error('identity');
        return JSON.stringify({schema_version:1,contract:'hs.managed.public-launch-state',
            nonce:argv[3],pid:observedPid,
            sender_pid:Number($.NSProcessInfo.processInfo.processIdentifier),
            executable:path,bundle_id:bundle,native_class:true,terminated:terminated,
            raw_type:typeof finished,finished_launching:finished});
    } catch (_) { throw Error('Managed public AppKit observation refused'); }
}
"""

    def start(self):
        if self.thread is not None:
            raise RuntimeError("Managed public observer already started")
        self.thread = threading.Thread(target=self._observe, daemon=True)
        self.thread.start()
        return self

    def _observe(self):
        try:
            if self.processes(self.executable) != [self.pid] or self.stop.is_set():
                self.failure = "identity-refused"
                return
            self.query_begin = time.monotonic()
            self.process = subprocess.Popen(
                [
                    "/usr/bin/osascript",
                    "-l",
                    "JavaScript",
                    "-e",
                    self.script(),
                    str(self.pid),
                    str(self.executable),
                    self.domain,
                    self.nonce,
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            if self.stop.is_set():
                self.process.kill()
            stdout, _ = self.process.communicate(timeout=SCRIPTING_TIMEOUT_SECONDS)
            if self.process.returncode != 0 or len(stdout) > 16384:
                self.failure = "query-refused"
                return
            packet = json.loads(stdout, object_pairs_hook=unique_object)
            if not self.valid_packet(packet) or self.processes(self.executable) != [self.pid]:
                self.failure = "identity-refused"
                return
            self.packet = packet
            self.query_end = time.monotonic()
            self.failure = None
        except subprocess.TimeoutExpired:
            self.failure = "query-timeout"
        except Exception:
            # Arbitrary Cocoa errors, stderr, source and private paths are never diagnostic text.
            self.failure = "query-refused"
        finally:
            if self.process is not None and self.process.returncode is None:
                try:
                    self.process.kill()
                    self.process.communicate(timeout=SCRIPT_CLEANUP_TIMEOUT_SECONDS)
                except Exception:
                    self.failure = "cleanup-unsettled"

    def valid_packet(self, packet):
        return (
            type(packet) is dict
            and set(packet)
            == {
                "schema_version",
                "contract",
                "nonce",
                "pid",
                "sender_pid",
                "executable",
                "bundle_id",
                "native_class",
                "terminated",
                "raw_type",
                "finished_launching",
            }
            and type(packet["schema_version"]) is int
            and packet["schema_version"] == 1
            and packet["contract"] == self.CONTRACT
            and packet["nonce"] == self.nonce
            and type(packet["pid"]) is int
            and packet["pid"] == self.pid
            and self.process is not None
            and type(packet["sender_pid"]) is int
            and packet["sender_pid"] == self.process.pid
            and packet["executable"] == str(self.executable)
            and packet["bundle_id"] == self.domain
            and packet["native_class"] is True
            and packet["terminated"] is False
            and packet["raw_type"] == "boolean"
            and type(packet["finished_launching"]) is bool
        )

    def mark_control_entry(self):
        self.control_begin = time.monotonic()

    def mark_control_exit(self):
        self.control_end = time.monotonic()

    def finish(self):
        try:
            if self.thread is not None:
                remaining = max(0, self.created + SCRIPTING_TIMEOUT_SECONDS - time.monotonic())
                self.thread.join(timeout=remaining)
                if self.thread.is_alive() or (
                    self.process is not None and self.process.returncode is None
                ):
                    self.stop.set()
                    if self.process is not None and self.process.returncode is None:
                        self.process.kill()
                    self.thread.join(timeout=SCRIPT_CLEANUP_TIMEOUT_SECONDS)
                if (
                    not self.thread.is_alive()
                    and self.process is not None
                    and self.process.returncode is None
                ):
                    self.process.communicate(timeout=SCRIPT_CLEANUP_TIMEOUT_SECONDS)
                if self.thread.is_alive() or (
                    self.process is not None and self.process.returncode is None
                ):
                    raise RuntimeError("Managed public observer cleanup has not settled")
        except Exception:
            # Keep owned debt and close exception text: TimeoutExpired embeds argv and nonce.
            raise RuntimeError("Managed public observer cleanup has not settled") from None
        timing = "unknown"
        if (
            self.packet is not None
            and self.query_begin is not None
            and self.query_end is not None
            and self.control_begin is not None
            and self.control_end is not None
        ):
            if self.query_end <= self.control_begin:
                timing = "before_path"
            elif self.query_begin >= self.control_end:
                timing = "after_path"
            else:
                timing = "overlaps_path"
        return {
            "contract": self.CONTRACT,
            "observation": "observed" if self.packet else "unobserved",
            "finished_launching": self.packet["finished_launching"] if self.packet else None,
            "timing": timing,
            "query_begin": self.query_begin,
            "query_end": self.query_end,
            "control_begin": self.control_begin,
            "control_end": self.control_end,
            "failure": self.failure,
            "qualified": False,
            "readiness": "unobserved",
        }


class NativeDelayedTimerProbe:
    """Use the launch gate's signed embedded runtime without starting another process."""

    def __init__(self, app, output, domain):
        self.app = app / "Contents/Frameworks/Hammerspoon.app"
        self.output = output
        self.executable = self.executable_path(app)
        self.domain = domain
        self.preference = AppleScriptPreference(domain)
        self.nonce = secrets.token_hex(16)
        self.started = False
        self.scripting_commands = []
        self.scripting_command_number = 0
        self.diagnostic_receipts = []
        self.runtime_owner = None
        self.no_prompt_scope = None
        self.server_sample_workers = []
        self.no_prompt_sample_diagnostics = []
        self.managed_launch_observation = None

    def start_managed_launch_observation(self, pid, processes):
        if self.managed_launch_observation is not None:
            raise RuntimeError("Managed public observer already has an owner")
        self.managed_launch_observation = ManagedLaunchObservation(
            pid, self.executable, self.domain, self.nonce, processes
        ).start()
        return self.managed_launch_observation

    @staticmethod
    def executable_path(app):
        """Return the exact installed native executable the launcher owns."""
        return app / "Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon"

    def enable(self):
        """Verify installed identity before enabling the owned scripting channel."""
        subprocess.run(
            ["/usr/bin/codesign", "--verify", "--strict", "--deep", str(self.app)],
            check=True,
            capture_output=True,
            timeout=30,
        )
        with (self.app / "Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        if (
            info["CFBundleIdentifier"] != self.domain
            or info["CFBundleShortVersionString"] != CONTRACT["runtime_version"]
        ):
            raise ValueError(
                "The packaged native timer runtime differs from its qualified identity"
            )
        self.preference.enable()

    def execute(self, source, phase="observation", _target_pid=None):
        """Require the owned reply; PID addressing is exclusive to its diagnostic."""
        if phase not in SCRIPTING_PHASES:
            raise ValueError("The native scripting phase is unknown")
        if self.scripting_commands or self.server_sample_workers:
            raise RuntimeError("The prior native scripting command has not settled")
        script = (
            "on run argv\n"
            f"tell application {json.dumps(str(self.app))}\n"
            "return execute lua code (item 1 of argv)\nend tell\nend run"
        )
        arguments = ["/usr/bin/osascript", "-e", script, source]
        if phase in ("pid_control", "constructor", "pid_no_prompt"):
            if self.runtime_owner is None:
                raise RuntimeError("The PID control has no bound native runtime")
            pid, processes = self.runtime_owner
            if (
                type(_target_pid) is not int
                or _target_pid != pid
                or processes(self.executable) != [pid]
            ):
                raise RuntimeError("The PID control target differs from its exact live owner")
            # The sender remains osascript. Only the address changes: a raw kernel
            # PID bypasses application-path resolution while HmSp/EXEC still
            # reaches the pinned NSScriptCommand and its enabled preference.
            script = {
                "constructor": self.constructor_script,
                "pid_control": self.pid_control_script,
                "pid_no_prompt": self.no_prompt_script,
            }[phase]()
            if phase == "pid_no_prompt" and self.no_prompt_scope is not None:
                script = self.no_prompt_script(self.no_prompt_scope)
            arguments = ["/usr/bin/osascript", "-l", "JavaScript", "-e", script, str(pid), source]
            if phase in ("constructor", "pid_no_prompt"):
                arguments.append(self.nonce)
        elif _target_pid is not None:
            raise ValueError("A PID address is reserved for its distinct diagnostic")
        command = subprocess.Popen(
            arguments,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.scripting_commands.append(command)
        self.scripting_command_number += 1
        worker = None
        primary_error = None
        try:
            if phase == "pid_no_prompt" and self.no_prompt_scope is not None:
                self.no_prompt_scope.bind_sender(command.pid)
                self.no_prompt_sample_diagnostics = []
                worker = NoPromptServerSample(
                    self.no_prompt_scope,
                    pid,
                    self.output
                    / f"sample-hammerspoon-no-prompt-{self.scripting_command_number}.txt",
                )
                self.server_sample_workers.append(worker)
                worker.start()
            stdout, stderr = command.communicate(timeout=SCRIPTING_TIMEOUT_SECONDS)
        except Exception as primary:
            primary_error = primary
            if worker is not None:
                worker.stop.set()
            diagnostics = []
            if isinstance(primary, subprocess.TimeoutExpired):
                try:
                    diagnostics = self.sample_scripting_command(command)
                except Exception as sampling:
                    diagnostics.append(
                        f"native scripting sample failed: {type(sampling).__name__}: {sampling}"
                    )
                try:
                    diagnostics.extend(self.sample_native_runtime())
                except Exception as sampling:
                    diagnostics.append(
                        f"native Hammerspoon server sample failed: {type(sampling).__name__}: {sampling}"
                    )
            self.retain_diagnostics(diagnostics, phase)
            try:
                self.retire_scripting_command(command)
            except Exception as cleanup:
                diagnostics.append(
                    f"owned scripting process cleanup failed: {type(cleanup).__name__}: {cleanup}"
                )
            detail = "; ".join(diagnostics)
            raise RuntimeError(
                f"Native scripting command failed: {type(primary).__name__}: {primary}"
                + (f"; {detail}" if detail else "")
            ) from primary
        finally:
            if worker is not None:
                try:
                    qualified_interval = worker.finish()
                except Exception as cleanup:
                    if primary_error is not None:
                        raise RuntimeError(
                            "Native scripting command failed: "
                            + type(primary_error).__name__
                            + "; owned no-prompt sampler cleanup has not settled"
                        ) from primary_error
                    # The existing PID helper classifies a TimeoutExpired cause as
                    # sender debt. A sampler-only timeout must not impersonate it.
                    raise RuntimeError("Owned no-prompt sampler cleanup has not settled") from None
                self.server_sample_workers.remove(worker)
                prefix = "native server sample phase=pid_no_prompt command=" + str(
                    self.scripting_command_number
                )
                if qualified_interval:
                    try:
                        messages = self.read_native_runtime_sample(worker.sample, pid, processes)
                    except Exception:
                        # Supplemental admission must neither replace the primary
                        # sender failure nor expose private native exception text.
                        messages = [
                            "native Hammerspoon server sample unqualified: sample admission refused"
                        ]
                    owner_state = (
                        "qualified"
                        if messages[0].startswith("native Hammerspoon server sample retained:")
                        else "unqualified"
                    )
                    self.no_prompt_sample_diagnostics = [
                        prefix
                        + " send_interval=observed worker=retired sample_owner="
                        + owner_state
                    ] + messages
                else:
                    self.no_prompt_sample_diagnostics = [
                        prefix + " send_interval=unqualified worker=retired reason=" + worker.reason
                    ]
        if command.returncode is None:
            raise RuntimeError(
                "The native scripting command did not acknowledge actual process exit"
            )
        self.scripting_commands.remove(command)
        if phase in ("constructor", "pid_no_prompt"):
            if command.returncode != 0:
                raise RuntimeError(
                    f"The native {phase} command refused its bounded receipt "
                    f"(exit {command.returncode}): {stderr.strip()[:1000]}"
                )
            return (
                validate_constructor_receipt(stdout, self.nonce, pid, source)
                if phase == "constructor"
                else validate_no_prompt_receipt(stdout, self.nonce, pid)
            )
        acknowledged = (
            stdout == self.nonce + "\n"
            if phase in ("control", "pid_control")
            else stdout.strip() == self.nonce
        )
        if command.returncode != 0 or not acknowledged:
            raise RuntimeError(
                "The packaged native timer scripting command did not acknowledge its nonce "
                f"(exit {command.returncode}): {stderr.strip()[:1000]}"
            )

        return self.nonce

    def control(self, pid, processes):
        """Test the same live AppleEvent handler with an exact owned nonce line."""
        observer = self.managed_launch_observation
        if observer is not None:
            observer.mark_control_entry()
        try:
            self.bind_runtime(pid, processes)
            acknowledgement = self.execute("return " + json.dumps(self.nonce), phase="control")
            if type(acknowledgement) is not str or acknowledgement != self.nonce:
                raise RuntimeError(
                    "The native AppleEvent control owner did not acknowledge its nonce"
                )
            if processes(self.executable) != [pid]:
                raise RuntimeError(
                    "The native AppleEvent control process changed before receipt admission"
                )
            return {
                "schema_version": 1,
                "contract": CONTROL_CONTRACT,
                "phase": "control",
                "acknowledged": True,
                "nonce": self.nonce,
                "pid": pid,
                "executable": str(self.executable),
            }
        finally:
            if observer is not None:
                observer.mark_control_exit()

    @staticmethod
    def pid_event_constructor():
        """Construct the one native command shared by smoke and actual sending."""
        return """ObjC.import('Foundation');
function constructOwnedEvent(pid, source) {
    if (!Number.isInteger(pid) || pid <= 0) throw new Error('PID control target refused');
    var target = $.NSAppleEventDescriptor.descriptorWithProcessIdentifier(pid);
    if (target.isNil() || Number(target.descriptorType) !== 0x6b706964)
        throw new Error('Native kernel-PID address refused');
    var event = $.NSAppleEventDescriptor.appleEventWithEventClassEventIDTargetDescriptorReturnIDTransactionID(
        0x486d5370, 0x45584543, target, -1, 0);
    event.setParamDescriptorForKeyword($.NSAppleEventDescriptor.descriptorWithString(source), 0x2d2d2d2d);
    return event;
}
"""

    @staticmethod
    def pid_control_script():
        """Send the pinned direct-text command to a kernel PID from osascript."""
        return (
            NativeDelayedTimerProbe.pid_event_constructor()
            + """
function run(argv) {
    if (argv.length !== 2) throw new Error('PID control arguments refused');
    var event = constructOwnedEvent(Number(argv[0]), argv[1]);
    var error = Ref();
    var reply = event.sendEventWithOptionsTimeoutError(3, __SCRIPTING_TIMEOUT_SECONDS__, error);
    if (!reply || reply.isNil()) {
        var nativeError = error[0];
        var status = nativeError && !nativeError.isNil() ? Number(nativeError.code) : 'unavailable';
        throw new Error('Native PID AppleEvent send refused (status ' + status + ')');
    }
    var errorNumber = reply.paramDescriptorForKeyword(0x6572726e);
    if (!errorNumber.isNil() && Number(errorNumber.int32Value) !== 0)
        throw new Error('Native PID AppleEvent handler refused (status ' + Number(errorNumber.int32Value) + ')');
    var result = reply.paramDescriptorForKeyword(0x2d2d2d2d);
    if (result.isNil()) throw new Error('Native PID AppleEvent result missing');
    return ObjC.unwrap(result.stringValue);
}
""".replace("__SCRIPTING_TIMEOUT_SECONDS__", json.dumps(SCRIPTING_TIMEOUT_SECONDS))
        )

    @staticmethod
    def no_prompt_script(scope=None):
        """Discriminate native admission without prompting or changing permission."""
        script = (
            NativeDelayedTimerProbe.pid_event_constructor()
            + """
function run(argv) {
    if (argv.length !== 3) throw new Error('No-prompt control arguments refused');
    var pid = Number(argv[0]);
    var event = constructOwnedEvent(pid, argv[1]);
    var error = Ref();
    var reply = event.sendEventWithOptionsTimeoutError(__NO_PROMPT_OPTIONS__, __NO_PROMPT_NATIVE_TIMEOUT_SECONDS__, error);
    var status = 0, result = null, origin = 'none', domain = null;
    if (!reply || reply.isNil()) {
        var nativeError = error[0];
        if (!nativeError || nativeError.isNil()) throw new Error('Native send status unavailable');
        status = Number(nativeError.code);
        domain = ObjC.unwrap(nativeError.domain);
        origin = 'send';
    } else {
        var errorNumber = reply.paramDescriptorForKeyword(0x6572726e);
        if (!errorNumber.isNil()) status = Number(errorNumber.int32Value);
        if (status !== 0) origin = 'handler';
        else {
            var direct = reply.paramDescriptorForKeyword(0x2d2d2d2d);
            if (direct.isNil()) throw new Error('Native no-prompt result missing');
            result = ObjC.unwrap(direct.stringValue);
        }
    }
    if (!Number.isInteger(status)) throw new Error('Native send status refused');
    return JSON.stringify({schema_version:1, contract:'hs.applescript.pid-no-prompt',
        phase:'pid_no_prompt', nonce:argv[2], pid:pid, send_options:__NO_PROMPT_OPTIONS__,
        status:status, result:result, error_origin:origin, error_domain:domain});
}
""".replace("__NO_PROMPT_OPTIONS__", str(NO_PROMPT_SEND_OPTIONS)).replace(
                "__NO_PROMPT_NATIVE_TIMEOUT_SECONDS__",
                str(NO_PROMPT_NATIVE_TIMEOUT_SECONDS),
            )
        )

        if scope is None:
            return script
        script = script.replace(
            "function run(argv) {",
            scope.javascript_prelude() + scope.calibration_javascript() + "\nfunction run(argv) {",
            1,
        )
        script = script.replace(
            "constructOwnedEvent(pid, argv[1])",
            "constructOwnedEvent(pid, ownedWitnessSource(argv[1], pid, argv[2]))",
            1,
        )
        script = script.replace(
            "    var error = Ref();",
            "    recordOwnedStage('constructed');\n    calibrateOwnedNSError(event);\n    qualifyOwnedScalars(event);\n    var error = $();\n    recordOwnedStage('send_entered');",
            1,
        )
        script = script.replace(
            "    var status = 0,",
            "    recordOwnedStage('send_returned');\n    recordOwnedStage('error_decode_entered');\n    var status = 0,",
            1,
        )
        script = script.replace(
            "        origin = 'send';",
            "        origin = 'send';\n        recordOwnedStage('error_decode_complete');",
            1,
        )
        script = script.replace(
            "        if (status !== 0) origin = 'handler';",
            "        recordOwnedStage('error_decode_complete');\n        if (status !== 0) origin = 'handler';",
            1,
        )
        script = script.replace(
            "            result = ObjC.unwrap(direct.stringValue);",
            "            result = ObjC.unwrap(direct.stringValue);\n            recordOwnedStage('reply_decode_complete');",
            1,
        )

        script = script.replace(
            "        var nativeError = error[0];",
            "        recordDecoderBoundary('send', 'reference_entered');\n        var nativeError = error;\n        ObjC.castObjectToRef(nativeError);\n        if (nativeError.isNil() !== false || nativeError.isKindOfClass($.NSError) !== true)\n            throw new Error('Native NSError identity unavailable');\n        recordDecoderBoundary('send', 'reference_returned');",
            1,
        )
        script = script.replace(
            "        status = Number(nativeError.code);",
            "        recordDecoderBoundary('send', 'code_entered');\n        var rawCode = nativeError.code;\n        status = Number(rawCode);\n        recordDecoderBoundary('send', 'code_returned', 'code', integerFact(status));\n        observeOwnedIntegerGetter('send', nativeError, rawCode, null);",
            1,
        )
        script = script.replace(
            "        domain = ObjC.unwrap(nativeError.domain);",
            "        recordDecoderBoundary('send', 'domain_entered');\n        domain = ObjC.unwrap(nativeError.domain);\n        recordDecoderBoundary('send', 'domain_returned', 'domain', {type:typeof domain,recognized:domain === 'NSOSStatusErrorDomain'});\n        status = projectOwnedNSErrorInteger(nativeError, rawCode);\n        if (typeof domain !== 'string' || domain.length === 0)\n            throw new Error('Native NSError domain unavailable');",
            1,
        )
        script = script.replace(
            "        var errorNumber = reply.paramDescriptorForKeyword(0x6572726e);",
            "        recordDecoderBoundary('handler', 'errn_entered');\n        var rawErrorNumber = reply.paramDescriptorForKeyword(0x6572726e);\n        var errorNumber = projectOwnedDescriptor(rawErrorNumber);\n        recordDecoderBoundary('handler', 'errn_returned', 'errn', descriptorFact(rawErrorNumber, errorNumber));",
            1,
        )
        script = script.replace(
            "        if (!errorNumber.isNil()) status = Number(errorNumber.int32Value);",
            "        if (errorNumber !== null) {\n            recordDecoderBoundary('handler', 'int32_entered');\n            var rawInt32 = errorNumber.int32Value;\n            status = Number(rawInt32);\n            recordDecoderBoundary('handler', 'int32_returned', 'int32', integerFact(status));\n            if (typeof rawInt32 !== 'number' || !Number.isInteger(rawInt32))\n                throw new Error('Native descriptor integer unavailable');\n        } else recordDecoderBoundary('handler', 'absent_errn');",
            1,
        )
        return script

    def control_pid_no_prompt(self, pid, processes):
        """Retain execution witnesses separately from actual native admission status."""
        self.bind_runtime(pid, processes)
        if self.no_prompt_scope is not None:
            raise RuntimeError("Prior supplemental receipt cleanup has not settled")
        scope = NoPromptDiagnosticScope(self.output, self.nonce, pid, self.executable, self.domain)
        self.no_prompt_scope = scope
        receipt_owner = None
        try:
            try:
                result = self.execute(
                    "return " + json.dumps(self.nonce), phase="pid_no_prompt", _target_pid=pid
                )
                receipt_owner = processes(self.executable)
                if receipt_owner != [pid]:
                    raise RuntimeError(
                        "The no-prompt native process changed before receipt admission"
                    )
                evidence = scope.observe(
                    require_completion=result["status"] == 0, terminal=True, native=result
                )
            except Exception as primary:
                if scope.sender_pid is not None:
                    if receipt_owner is None:
                        receipt_owner = processes(self.executable)
                    if receipt_owner != [pid]:
                        raise RuntimeError(
                            "The supplemental server owner changed before witness observation"
                        ) from primary
                evidence = scope.observe()
                self.retain_diagnostics(
                    [
                        *self.no_prompt_sample_diagnostics,
                        f"Supplemental server witness: {evidence['server']}; sender stage: {evidence['sender_stage']}",
                        f"Supplemental scalar stage: {evidence['scalar_stage']}; qualified: {str(evidence['scalar_qualified']).lower()}; decoder branch: {evidence['decoder_branch']}; boundary: {evidence['decoder_boundary']}",
                        f"Supplemental constructor scalars: {evidence['scalar_facts']}",
                        f"Supplemental decoder scalars: {evidence['decoder_facts']}",
                        f"Supplemental NSError calibration: {evidence['nserror_calibration']}",
                        f"Supplemental integer getter: {evidence['integer_getter']}",
                    ],
                    "pid_no_prompt",
                )
                raise
            result["executable"] = str(self.executable)
            self.retain_diagnostics(
                [
                    *self.no_prompt_sample_diagnostics,
                    f"Exact owned no-prompt AppleEvent {result['outcome']}: "
                    f"status {result['status']}, origin {result['error_origin']}",
                    f"Supplemental server witness: {evidence['server']}; sender stage: {evidence['sender_stage']}",
                    f"Supplemental scalar stage: {evidence['scalar_stage']}; qualified: {str(evidence['scalar_qualified']).lower()}; decoder branch: {evidence['decoder_branch']}; boundary: {evidence['decoder_boundary']}",
                    f"Supplemental constructor scalars: {evidence['scalar_facts']}",
                    f"Supplemental decoder scalars: {evidence['decoder_facts']}",
                    f"Supplemental NSError calibration: {evidence['nserror_calibration']}",
                    f"Supplemental integer getter: {evidence['integer_getter']}",
                ],
                "pid_no_prompt",
            )
            return result
        finally:
            if not self.scripting_commands and not self.server_sample_workers:
                scope.cleanup()
                self.no_prompt_scope = None

    def observe_early_lua_stage(self, journal):
        """A complete line observes attempted publication, never its acknowledgement."""
        result = {
            "phase": "received_lua_body",
            "body_stage": "unobserved",
            "publication_ack": "unobserved",
            "timing": "unknown",
            "qualified": False,
        }
        if self.runtime_owner is None or self.scripting_commands or self.server_sample_workers:
            return result
        pid, _ = self.runtime_owner
        if (
            type(pid) is not int
            or pid <= 0
            or type(self.nonce) is not str
            or re.fullmatch(r"[0-9a-f]{32}", self.nonce) is None
            or type(journal) is not str
            or len(journal) > SCRIPT_SAMPLE_READ_LIMIT
        ):
            return result
        expected = (
            r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[INFO\] \[init\] "
            r"Native scripting Lua body stage: phase=received_lua_body; pid="
            + re.escape(str(pid))
            + "; nonce="
            + re.escape(self.nonce)
            + r"\."
        )
        # Flush/close may refuse after writing a complete LF record. Even one
        # exact fresh line never acknowledges append(), or entry before timeout.
        matches = [
            line
            for line in journal.splitlines(keepends=True)
            if line.endswith("\n")
            and not line.endswith("\r\n")
            and re.fullmatch(expected, line[:-1]) is not None
        ]
        if len(matches) == 1:
            result["body_stage"] = "observed"
        return result

    @staticmethod
    def constructor_script():
        """Inspect native construction only; this script never sends or launches."""
        return (
            NativeDelayedTimerProbe.pid_event_constructor()
            + """
function run(argv) {
    if (argv.length !== 3) throw new Error('Constructor arguments refused');
    var pid = Number(argv[0]);
    var event = constructOwnedEvent(pid, argv[1]);
    var address = event.attributeDescriptorForKeyword(0x61646472);
    var direct = event.paramDescriptorForKeyword(0x2d2d2d2d);
    if (address.isNil() || direct.isNil()) throw new Error('Native descriptor inspection refused');
    return JSON.stringify({schema_version: 1, contract: 'hs.applescript.constructor',
        phase: 'constructor', constructed: true, nonce: argv[2], pid: pid,
        address_type: Number(address.descriptorType),
        address_bytes_base64: ObjC.unwrap(address.data.base64EncodedStringWithOptions(0)),
        event_class: Number(event.eventClass), event_id: Number(event.eventID),
        direct_type: Number(direct.descriptorType), direct_text: ObjC.unwrap(direct.stringValue)});
}
"""
        )

    def constructor_control(self, pid, processes):
        """Measure the actual bridge in native scenarios without sending an event."""
        self.bind_runtime(pid, processes)
        direct_text = "return " + json.dumps(self.nonce + " — ù ★", ensure_ascii=False)
        receipt = self.execute(direct_text, phase="constructor", _target_pid=pid)
        if processes(self.executable) != [pid]:
            raise RuntimeError("The native constructor process changed before receipt admission")
        receipt = validate_constructor_receipt(
            json.dumps(receipt, ensure_ascii=False) + "\n", self.nonce, pid, direct_text
        )
        receipt["executable"] = str(self.executable)
        self.retain_diagnostics(
            ["Actual native kernel-PID, event and Unicode descriptor construction qualified"],
            phase="constructor",
        )
        return receipt

    def control_pid(self, pid, processes):
        """Compare exact-PID delivery without admitting the original feature gate."""
        self.bind_runtime(pid, processes)
        acknowledgement = self.execute(
            "return " + json.dumps(self.nonce), phase="pid_control", _target_pid=pid
        )
        if type(acknowledgement) is not str or acknowledgement != self.nonce:
            raise RuntimeError("The native PID control did not acknowledge its nonce")
        if processes(self.executable) != [pid]:
            raise RuntimeError("The native PID control process changed before receipt admission")
        receipt = {
            "schema_version": 1,
            "contract": PID_CONTROL_CONTRACT,
            "phase": "pid_control",
            "acknowledged": True,
            "nonce": self.nonce,
            "pid": pid,
            "executable": str(self.executable),
        }
        validate_pid_control_summary(receipt)
        self.retain_diagnostics(
            ["Exact owned kernel-PID control acknowledged its nonce"], phase="pid_control"
        )
        return receipt

    def pid_control_error_diagnostic(self, error):
        """Bound the alternate control error without publishing its script argv."""
        if isinstance(error, subprocess.TimeoutExpired) or isinstance(
            error.__cause__, subprocess.TimeoutExpired
        ):
            detail = (
                "TimeoutExpired: the owned PID scripting command exceeded its unchanged deadline"
            )
        else:
            detail = f"{type(error).__name__}: {error}"
        return self.bounded_diagnostic_text(detail)

    @staticmethod
    def bounded_diagnostic_text(text):
        """Apply the one shared source-redaction and receipt-size policy."""
        observations = NativeDelayedTimerProbe.sample_frame_text(text)
        lines = observations.splitlines()
        if (
            len(observations) > SCRIPT_DIAGNOSTIC_CHARACTER_LIMIT
            or len(lines) > SCRIPT_DIAGNOSTIC_LINE_LIMIT
        ):
            marker = "\n[native diagnostic truncated]"
            observations = "\n".join(lines[: SCRIPT_DIAGNOSTIC_LINE_LIMIT - 1])
            observations = observations[: SCRIPT_DIAGNOSTIC_CHARACTER_LIMIT - len(marker)] + marker
        return observations

    def retain_diagnostics(self, diagnostics, phase="observation"):
        """Retain bounded native observations independently of error annotations."""
        if not diagnostics:
            return
        if len(self.diagnostic_receipts) >= SCRIPT_DIAGNOSTIC_RECEIPT_LIMIT:
            self.diagnostic_receipts[-1]["additional_commands_omitted"] = True
            return
        # Path control, construction, PID control and feature lifecycle own native
        # sampling replies. Do not include the Lua source or the primary error;
        # either could contain unrelated user data. Redact native source paths.
        observations = self.bounded_diagnostic_text("\n".join(diagnostics))
        self.diagnostic_receipts.append(
            {
                "command": self.scripting_command_number,
                "phase": phase,
                "observations": observations,
            }
        )

    def retain_primary_error(self, error, phase):
        """Keep the bounded primary refusal even when native samples already exist."""
        detail = self.pid_control_error_diagnostic(error)
        if not any(receipt["phase"] == phase for receipt in self.diagnostic_receipts):
            self.retain_diagnostics(["Native scripting phase refused"], phase)
        for receipt in self.diagnostic_receipts:
            if receipt["phase"] == phase:
                receipt["primary_error"] = detail
                return

    def sample_scripting_command(self, command):
        """Sample only an unreaped own child before any timeout retirement signal."""
        diagnostics = []
        if command.poll() is not None:
            return ["native scripting process exited before its timeout sample"]
        # This Popen has not reaped the child: its PID cannot be reused while
        # the independent sampler runs, even if the child exits meanwhile.
        sample = self.output / f"sample-osascript-{self.scripting_command_number}.txt"
        try:
            result = subprocess.run(
                [
                    "/usr/bin/sample",
                    str(command.pid),
                    str(SCRIPT_SAMPLE_SECONDS),
                    "-file",
                    str(sample),
                ],
                capture_output=True,
                text=True,
                timeout=SCRIPT_CLEANUP_TIMEOUT_SECONDS,
            )
            if result.returncode or not sample.is_file():
                diagnostics.append(
                    f"native scripting sample refused (exit {result.returncode}): {result.stderr.strip()[:1000]}"
                )
            else:
                diagnostics.append(f"native scripting sample retained: {sample.name}")
                # Job annotations remain readable when artifact downloads fail.
                # Report observed native frames, without guessing a permission
                # or run-loop diagnosis from an unresponsive AppleEvent alone.
                with sample.open(encoding="utf-8", errors="replace") as handle:
                    sample_text = handle.read(SCRIPT_SAMPLE_READ_LIMIT)
                markers = (
                    "TCC",
                    "AppleEvent",
                    "AESend",
                    "AEWait",
                    "NSAppleScript",
                    "LaunchServices",
                )
                frames = self.observed_sample_frames(sample_text, markers)
                if frames:
                    diagnostics.append("observed native scripting frames: " + " | ".join(frames))
        except Exception as error:
            diagnostics.append(f"native scripting sample failed: {type(error).__name__}: {error}")
        return diagnostics

    @staticmethod
    def observed_sample_frames(sample_text, markers):
        """Binary-image presence is not evidence that a stack executes there."""
        stacks = sample_text.split("Binary Images:", 1)[0]
        return list(
            dict.fromkeys(
                line.strip()
                for line in stacks.splitlines()
                if any(marker in line for marker in markers)
            )
        )[:SCRIPT_SAMPLE_FRAME_LIMIT]

    @staticmethod
    def sample_frame_text(line):
        """Retain native symbols while omitting private source locations from logs."""
        safe = re.sub(r"\([^)]*/[^)]*\)", "(location redacted)", line)
        return re.sub(r"(?:https?://|/)[^\s)]+", "[path redacted]", safe)

    @staticmethod
    def observed_sample_contexts(sample_text, markers):
        """Keep native thread ownership and call ancestry instead of merging frames."""
        if "Call graph:" not in sample_text:
            return []
        stacks = sample_text.split("Call graph:", 1)[1].split("Binary Images:", 1)[0]
        threads = []
        current = None
        ancestors = []
        for line in stacks.splitlines():
            thread = re.match(r"^\s*(\d+\s+Thread_(?:\d+|0x[0-9a-fA-F]+))\b(.*)$", line)
            if thread:
                queue = re.search(
                    r"\b(DispatchQueue_\d+)(?::\s*([A-Za-z_][A-Za-z0-9_.-]*)(?=\s|$))?",
                    thread[2],
                )
                main = queue is not None and queue[2] == "com.apple.main-thread"
                label = thread[1]
                if queue:
                    label += " " + queue[1]
                    if queue[2]:
                        label += ": " + queue[2]
                current = {
                    "label": label,
                    "main": main,
                    "frames": [],
                    "selected": set(),
                    "critical": [],
                }
                threads.append(current)
                ancestors = []
                continue
            frame = re.match(r"^([ \t+!|:]*)(\d+\s+.+)$", line)
            if current is None or not frame:
                continue
            depth = len(frame[1].expandtabs())
            while ancestors and ancestors[-1][0] >= depth:
                ancestors.pop()
            index = len(current["frames"])
            # Source locations can contain private paths; retain symbols and native ancestry.
            safe = NativeDelayedTimerProbe.sample_frame_text(line)
            current["frames"].append(safe)
            ancestors.append((depth, index))
            critical = any(marker in safe for marker in markers)
            if critical:
                current["critical"].append(index)
            if critical or (
                current["main"] and any(marker in frame[2] for marker in ("CFRunLoop", "mach_msg"))
            ):
                current["selected"].update(ancestor[1] for ancestor in ancestors)
        selected = [thread for thread in threads if thread["selected"]]
        selected.sort(key=lambda thread: not thread["main"])
        contexts = []
        remaining = SCRIPT_SAMPLE_CONTEXT_CHARACTER_LIMIT
        for thread in selected[:SCRIPT_SAMPLE_CONTEXT_THREAD_LIMIT]:
            indices = sorted(thread["selected"])
            truncated = len(indices) > SCRIPT_SAMPLE_CONTEXT_FRAME_LIMIT
            if truncated:
                retained = set(thread["critical"][:SCRIPT_SAMPLE_FRAME_LIMIT])
                retained.update(indices[:2])
                for index in reversed(indices):
                    if len(retained) >= SCRIPT_SAMPLE_CONTEXT_FRAME_LIMIT:
                        break
                    retained.add(index)
                indices = sorted(retained)
            omitted = thread["selected"] - set(indices)
            heading = "observed native Hammerspoon server thread: " + thread["label"]
            context = heading
            previous = -1
            truncation_note = "\n[native sample context truncated]"
            for index in indices:
                gap = (
                    "\n[native ancestry omitted]"
                    if any(previous < item < index for item in omitted)
                    else ""
                )
                frame = gap + "\n" + thread["frames"][index]
                if len(context) + len(frame) + len(truncation_note) > remaining:
                    truncated = True
                    break
                context += frame
                previous = index
            if truncated:
                context += truncation_note
            if len(context) > remaining:
                break
            contexts.append(context)
            remaining -= len(context)
        if len(selected) > len(contexts) and contexts:
            note = "\n[additional native thread contexts omitted]"
            if len(note) <= remaining:
                contexts[-1] += note
        return contexts

    def bind_runtime(self, pid, processes):
        """Retain the exact installed server owner already admitted by the gate."""
        if type(pid) is not int or pid <= 0 or processes(self.executable) != [pid]:
            raise RuntimeError("The native probe cannot bind a foreign or changed runtime owner")
        self.runtime_owner = (pid, processes)

    def sample_native_runtime(self):
        """Observe the qualified server before retirement; never infer TCC causality."""
        if self.runtime_owner is None:
            return ["native Hammerspoon server sample unavailable: no qualified owner"]
        pid, processes = self.runtime_owner
        if processes(self.executable) != [pid]:
            return ["native Hammerspoon server sample unavailable: exact owner changed"]
        sample = self.output / f"sample-hammerspoon-{self.scripting_command_number}.txt"
        result = subprocess.run(
            ["/usr/bin/sample", str(pid), str(SCRIPT_SAMPLE_SECONDS), "-file", str(sample)],
            capture_output=True,
            text=True,
            timeout=SCRIPT_CLEANUP_TIMEOUT_SECONDS,
        )
        if result.returncode or not sample.is_file():
            return [
                f"native Hammerspoon server sample refused (exit {result.returncode}): {result.stderr.strip()[:1000]}"
            ]
        return self.read_native_runtime_sample(sample, pid, processes)

    def read_native_runtime_sample(self, sample, pid, processes):
        """Use identical native owner/header/closed-frame admission for both samplers."""
        if processes(self.executable) != [pid]:
            return ["native Hammerspoon server sample unqualified: owner changed before admission"]
        if not sample.is_file() or sample.is_symlink():
            return ["native Hammerspoon server sample unqualified: owned output unavailable"]
        with sample.open(encoding="utf-8", errors="replace") as handle:
            sample_text = handle.read(SCRIPT_SAMPLE_READ_LIMIT)
        header = sample_text.split("Call graph:", 1)[0]
        fields = {
            line.split(":", 1)[0].strip(): line.split(":", 1)[1].strip()
            for line in header.splitlines()
            if ":" in line
        }
        if (
            fields.get("Path") != str(self.executable)
            or fields.get("Process") != f"{self.executable.name} [{pid}]"
        ):
            return [
                "native Hammerspoon server sample unqualified: native Process/Path identity differs"
            ]
        diagnostics = [f"native Hammerspoon server sample retained: {sample.name}"]
        if "Call graph:" not in sample_text:
            diagnostics.append(
                "native Hammerspoon server stack context unavailable: no Call graph section"
            )
            return diagnostics
        markers = (
            "TCC",
            "AppleEvent",
            "AEWait",
            "NSAppleScript",
            "HSAppleScript",
            "NSAlert",
            "runModal",
            "lua_pcall",
            "dispatch_semaphore_wait",
            # Hammerspoon 1.1.1 extensions/task/libtask.m dispatches create_task's
            # termination block to the main queue before synchronous pipe reads.
            # Preserve observed ancestry without attributing a timeout cause.
            "__create_task_block_invoke",
            "readDataToEndOfFile",
        )
        contexts = self.observed_sample_contexts(sample_text, markers)
        if contexts:
            diagnostics.extend(contexts)
        else:
            stacks = sample_text.split("Call graph:", 1)[-1]
            critical_frames = self.observed_sample_frames(stacks, markers)
            context_frames = self.observed_sample_frames(stacks, ("CFRunLoop", "mach_msg"))
            frames = list(dict.fromkeys(critical_frames + context_frames))[
                :SCRIPT_SAMPLE_FRAME_LIMIT
            ]
            frames = [self.sample_frame_text(frame) for frame in frames]
            if frames:
                diagnostics.append(
                    "observed native Hammerspoon server frames (thread unattributed): "
                    + " | ".join(frames)
                )
        return diagnostics

    def retire_scripting_command(self, command):
        """Retain the child until bounded communicate acknowledges its actual exit."""
        if command.poll() is None:
            command.kill()
        command.communicate(timeout=SCRIPT_CLEANUP_TIMEOUT_SECONDS)
        if command.returncode is None:
            raise RuntimeError(
                "The native scripting cleanup did not acknowledge actual process exit"
            )
        self.scripting_commands.remove(command)

    def observe(self, pid, processes):
        """Retain and judge the async native receipt within a bounded observation."""
        fixture = Path(__file__).with_name("hs_delayed_timer_native.lua")
        receipt = self.output / "native-delayed-timers.json"
        if receipt.exists():
            raise RuntimeError("A native delayed-timer receipt already exists")
        if processes(self.executable) != [pid]:
            raise RuntimeError(
                "The native delayed-timer runtime is not the launcher's exact live process"
            )
        self.bind_runtime(pid, processes)
        source = "return dofile({}).run({}, {})".format(
            json.dumps(str(fixture), ensure_ascii=False),
            json.dumps(str(receipt), ensure_ascii=False),
            json.dumps(self.nonce),
        )
        self.started = True
        primary_error = None
        try:
            self.execute(source)
            deadline = time.monotonic() + 15
            while not receipt.exists():
                if time.monotonic() >= deadline or processes(self.executable) != [pid]:
                    raise RuntimeError(
                        "Native delayed-timer receipt timed out or its exact process exited"
                    )
                time.sleep(0.05)
            result = json.loads(
                receipt.read_text(encoding="utf-8"), object_pairs_hook=unique_object
            )
            if processes(self.executable) != [pid]:
                raise RuntimeError(
                    "The native delayed-timer process changed before receipt admission"
                )
            return validate_receipt(result, self.nonce, pid, self.executable, self.domain)
        except Exception as error:
            primary_error = error
            raise
        finally:
            try:
                if self.started and processes(self.executable) == [pid]:
                    self.execute(
                        "return dofile({}).cleanup({})".format(
                            json.dumps(str(fixture), ensure_ascii=False), json.dumps(self.nonce)
                        ),
                        phase="cleanup",
                    )
            except Exception as cleanup_error:
                cleanup_cause = f"{type(cleanup_error).__name__}: {cleanup_error}"
                if primary_error is None:
                    raise RuntimeError(
                        f"Native delayed-timer cleanup failed: {cleanup_cause}"
                    ) from cleanup_error
                raise RuntimeError(
                    "Native delayed-timer observation failed: "
                    f"{type(primary_error).__name__}: {primary_error}; "
                    f"native cleanup failed: {cleanup_cause}"
                ) from primary_error

    def restore(self):
        """Restore the scripting key after ordinary Quit or exact process cleanup."""
        if self.managed_launch_observation is not None:
            self.managed_launch_observation.finish()
        for command in list(self.scripting_commands):
            self.retire_scripting_command(command)
        for worker in list(self.server_sample_workers):
            worker.finish()
            self.server_sample_workers.remove(worker)
        self.preference.restore()
        if self.no_prompt_scope is not None:
            self.no_prompt_scope.cleanup()
            self.no_prompt_scope = None
