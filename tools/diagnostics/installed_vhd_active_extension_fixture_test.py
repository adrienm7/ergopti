"""Before-code controls: genuine filesystem and observational wire, zero native APIs."""

import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

SOURCE = Path(__file__).with_name("installed_vhd_active_extension_fixture.py")
spec = importlib.util.spec_from_file_location("active_fixture_controls", SOURCE)
F = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = F
spec.loader.exec_module(F)


def empty():
    return {
        "schema": 1,
        "query_identifier": "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice",
        "status": "observed_empty",
        "reason": "native_properties_empty",
        "properties": [],
        "callback_count": 1,
        "elapsed_ms": 5,
        "error_domain": None,
        "error_code": None,
        "reference_qualified": False,
        "approval_qualified": False,
        "installed_positive_qualified": False,
        "test_only": True,
        "signing_identifier": "com.ergoptiplus.test.vhd-properties",
        "public_leaf_sha256": "a" * 64,
    }


class ObservationControls(unittest.TestCase):
    def consume(self, packet):
        return F.observation((json.dumps(packet) + "\n").encode(), "a" * 64)

    def reject(self, packet):
        with self.assertRaises(F.FixtureRefusal):
            self.consume(packet)

    def test_empty_observation_is_delivery_only(self):
        packet = self.consume(empty())
        self.assertEqual(packet["status"], "observed_empty")
        self.assertFalse(packet["reference_qualified"])
        self.assertFalse(packet["installed_positive_qualified"])

    def test_denied_observation_remains_named_prerequisite_failure(self):
        packet = empty()
        packet.update(
            status="query_denied",
            reason="native_query_failed",
            error_domain="OSSystemExtensionErrorDomain",
            error_code=2,
        )
        actual = self.consume(packet)
        self.assertEqual(actual["status"], "query_denied")
        self.assertFalse(F.query_delivery_qualified(actual))

    def test_authority_promotion_is_refused(self):
        for key in (
            "reference_qualified",
            "approval_qualified",
            "installed_positive_qualified",
        ):
            packet = empty()
            packet[key] = True
            self.reject(packet)

    def test_identifier_and_test_signer_are_fixed(self):
        for key in ("query_identifier", "signing_identifier"):
            packet = empty()
            packet[key] = "arbitrary.caller.identifier"
            self.reject(packet)

    def test_duplicate_json_member_and_replayed_callback_refuse(self):
        data = json.dumps(empty()).replace('"schema": 1', '"schema": 1, "schema": 1').encode()
        with self.assertRaises(F.FixtureRefusal):
            F.observation(data, "a" * 64)
        packet = empty()
        packet["callback_count"] = 2
        self.reject(packet)

    def test_wrong_leaf_cannot_borrow_test_credential(self):
        packet = empty()
        packet["public_leaf_sha256"] = "b" * 64
        self.reject(packet)

    def test_timeout_does_not_qualify_native_delivery(self):
        packet = empty()
        packet.update(
            status="query_timeout",
            reason="native_query_timeout",
            callback_count=0,
            elapsed_ms=8000,
        )
        actual = self.consume(packet)
        self.assertFalse(F.query_delivery_qualified(actual))

    def test_noncanonical_types_and_unknown_fields_refuse(self):
        for key, value in (
            ("schema", True),
            ("callback_count", True),
            ("elapsed_ms", -1),
            ("test_only", 1),
            ("properties", {}),
        ):
            packet = empty()
            packet[key] = value
            self.reject(packet)
        packet = empty()
        packet["dynamic_reference_valid"] = True
        self.reject(packet)

    def test_native_properties_are_observations_without_approval_authority(self):
        packet = empty()
        packet.update(
            status="observed_properties",
            reason="native_properties_observed",
            properties=[
                {
                    "identifier": "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice",
                    "version": "1.8.0",
                    "short_version": "1.8.0",
                    "url": "/Library/SystemExtensions/fixture/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext",
                    "enabled": True,
                    "awaiting_approval": False,
                    "uninstalling": False,
                }
            ],
        )
        actual = self.consume(packet)
        self.assertFalse(actual["approval_qualified"])
        self.assertFalse(actual["installed_positive_qualified"])

    def test_ambiguous_or_caller_shaped_properties_refuse(self):
        packet = empty()
        packet.update(
            status="observed_properties",
            reason="native_properties_observed",
            properties=[
                {
                    "identifier": "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice",
                    "version": "1.8.0",
                    "short_version": "1.8.0",
                    "url": "/Library/SystemExtensions/fixture/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext",
                    "enabled": False,
                    "awaiting_approval": True,
                    "uninstalling": False,
                }
            ],
        )
        twice = copy.deepcopy(packet)
        twice["properties"] *= 2
        self.reject(twice)
        for key, value in (
            ("url", "file:///caller/path"),
            ("enabled", 1),
            ("identifier", "caller.extension"),
        ):
            changed = copy.deepcopy(packet)
            changed["properties"][0][key] = value
            self.reject(changed)

    def test_real_input_inode_replacement_refuses_before_consumer(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            source = root / "source.swift"
            source.write_bytes(b"fixed input")
            held = F.capture(source)
            replacement = root / "replacement"
            replacement.write_bytes(b"fixed input")
            replacement.replace(source)
            with self.assertRaises(F.FixtureRefusal):
                F.check_current(held)

    def test_real_symlink_and_hardlink_inputs_refuse(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            source = root / "source.swift"
            source.write_bytes(b"fixed input")
            link = root / "link"
            link.symlink_to(source)
            with self.assertRaises(F.FixtureRefusal):
                F.capture(link)
            import os

            os.link(source, root / "hardlink")
            with self.assertRaises(F.FixtureRefusal):
                F.capture(source)

    def test_native_work_shares_one_absolute_budget(self):
        self.assertEqual(F.time_left(100.0, now=99.0), 1.0)
        with self.assertRaises(F.FixtureRefusal):
            F.time_left(100.0, now=100.0)
        with self.assertRaises(F.FixtureRefusal):
            F.time_left(100.0, now=101.0)


if __name__ == "__main__":
    unittest.main()
