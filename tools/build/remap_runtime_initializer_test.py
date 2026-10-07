# tools/build/remap_runtime_initializer_test.py
"""Durable literal delivery13 plus nine independent lifetime controls; native0."""

import argparse
from pathlib import Path
import unittest

import remap_runtime_initializer_support as support

HARNESS = None


class InitializerControls(unittest.TestCase):
    def run_case(self, case):
        self.assertIn(case, support.CASES)
        self.assertIsNotNone(HARNESS, "Authentic offline prerequisite was not prepared")
        # Original compiler30/run10 ports and actual return-code/native0 assertions are whole.
        HARNESS.PortableCustodyControls().run_cpp("initializer_" + case)

    def test_healthy(self):
        self.run_case("healthy")

    def test_unbound(self):
        self.run_case("unbound")

    def test_bytes_mismatch(self):
        self.run_case("bytes_mismatch")

    def test_empty(self):
        self.run_case("empty")

    def test_noncanonical(self):
        self.run_case("noncanonical")

    def test_error(self):
        self.run_case("error")

    def test_unknown_response(self):
        self.run_case("unknown_response")

    def test_duplicate(self):
        self.run_case("duplicate")

    def test_retired(self):
        self.run_case("retired")

    def test_changed_peer(self):
        self.run_case("changed_peer")

    def test_timer(self):
        self.run_case("timer")

    def test_queue_refusal(self):
        self.run_case("queue_refusal")

    def test_callback(self):
        self.run_case("callback")

    def test_foreign_debt(self):
        self.run_case("foreign_debt")

    def test_timer_observation(self):
        self.run_case("timer_observation")

    def test_empty_refusal(self):
        self.run_case("empty_refusal")

    def test_reserved_kind(self):
        self.run_case("reserved_kind")

    def test_outbound_wire(self):
        self.run_case("outbound_wire")

    def test_pending_cancel(self):
        self.run_case("pending_cancel")

    def test_completion_reentry(self):
        self.run_case("completion_reentry")

    def test_peer_reentry(self):
        self.run_case("peer_reentry")

    def test_completion_exception(self):
        self.run_case("completion_exception")


def main():
    global HARNESS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--owner", type=Path, required=True)
    parser.add_argument("--case", choices=support.CASES)
    args = parser.parse_args()
    with support.prepared(args.owner) as harness:
        HARNESS = harness
        selection = ["InitializerControls.test_" + args.case] if args.case else []
        suite = (
            unittest.defaultTestLoader.loadTestsFromNames(selection, module=__import__(__name__))
            if selection
            else unittest.defaultTestLoader.loadTestsFromTestCase(InitializerControls)
        )
        result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
