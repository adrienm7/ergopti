# tools/diagnostics/journal_native_append_receipt.py
"""Mandatory Common Linux native EFBIG control; selected by its Linux feature.

This is deliberately outside portable hs274_*_test.py discovery. Unsupported
hosts have no native control selected, rather than a passing substitute or skip.
"""

import json
import resource
import signal
import unittest

from hs274_journal_append_test import JournalAppendReceiptTests
from hs274_ledger_bootstrap_test import LedgerBootstrapTests


class NativeLimitControl:
    original = {}

    @staticmethod
    def ignore_signal():
        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)

    @classmethod
    def set_limit(cls, pid, limit):
        previous = resource.prlimit(pid, resource.RLIMIT_FSIZE)
        assert pid not in cls.original, "native child already owns a size-limit receipt"
        soft, hard = previous
        assert soft == resource.RLIM_INFINITY or limit < soft, (
            "native fault must lower the child's soft limit"
        )
        assert hard == resource.RLIM_INFINITY or limit <= hard, (
            "requested native fault exceeds the child's hard limit"
        )
        cls.original[pid] = previous
        resource.prlimit(pid, resource.RLIMIT_FSIZE, (limit, hard))
        assert resource.prlimit(pid, resource.RLIMIT_FSIZE) == (limit, hard), (
            "native size fault was not established"
        )

    @classmethod
    def restore_limit(cls, pid):
        previous = cls.original[pid]
        resource.prlimit(pid, resource.RLIMIT_FSIZE, previous)
        assert resource.prlimit(pid, resource.RLIMIT_FSIZE) == previous, (
            "native child's original limits were not restored"
        )
        del cls.original[pid]


class NativeJournalAppendReceiptTests(unittest.TestCase):
    def test_actual_native_bootstrap_close_refusal_then_retry(self):
        self.assertTrue(
            callable(getattr(resource, "prlimit", None)), "native prlimit boundary required"
        )
        original_parent_limits = resource.getrlimit(resource.RLIMIT_FSIZE)
        receipt = LedgerBootstrapTests().replay("native", NativeLimitControl)
        self.assertEqual(resource.getrlimit(resource.RLIMIT_FSIZE), original_parent_limits)
        self.assertEqual(
            NativeLimitControl.original, {}, "the native child's exact limit receipt must settle"
        )
        fields = (
            "fault_mode",
            "raw_rows",
            "duration_ms",
            "outbox_empty",
            "header_bytes",
            "failed_write",
            "failed_close",
            "canonical_absent_after_refusal",
            "journal_absent_after_refusal",
            "retry_initialized",
            "native_limit_changes",
        )
        print(
            "NATIVE_LEDGER_BOOTSTRAP_RECEIPT " + json.dumps({key: receipt[key] for key in fields})
        )

    def test_actual_native_short_write_counts_one_event_and_duration(self):
        self.assertTrue(
            callable(getattr(resource, "prlimit", None)),
            "The Common Linux native control requires resource.prlimit",
        )
        original_parent_limits = resource.getrlimit(resource.RLIMIT_FSIZE)
        receipt = JournalAppendReceiptTests().replay("native", NativeLimitControl)
        self.assertEqual(resource.getrlimit(resource.RLIMIT_FSIZE), original_parent_limits)
        self.assertEqual(
            NativeLimitControl.original,
            {},
            "the native child must restore its exact original limit receipt",
        )
        fields = (
            "fault_mode",
            "raw_rows",
            "aggregate_app_time_ms",
            "duration_ms",
            "rows_before_recovery",
            "append_streams",
            "native_limit_changes",
        )
        print("NATIVE_JOURNAL_APPEND_RECEIPT " + json.dumps({key: receipt[key] for key in fields}))


if __name__ == "__main__":
    unittest.main(defaultTest="NativeJournalAppendReceiptTests")
