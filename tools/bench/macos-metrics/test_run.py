"""Reject false measurement receipts without launching any native process."""

import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('metrics_supervisor', Path(__file__).with_name('run.py'))
supervisor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)


class MeasurementReceiptTests(unittest.TestCase):
    def setUp(self):
        self.valid = dict(status='ok', manifest_ms=list(range(11)), rows=224,
                          ui='unmeasured', runtime='native Hammerspoon')

    def test_native_receipt_is_accepted(self):
        supervisor.validate_result(self.valid)

    def test_invalid_receipts_are_rejected(self):
        for field, value in [('status', 'error'), ('manifest_ms', []),
                             ('manifest_ms', [0] * 10), ('manifest_ms', [True] * 11),
                             ('manifest_ms', [float('nan')] * 11),
                             ('manifest_ms', [float('inf')] * 11),
                             ('manifest_ms', [-1] * 11), ('manifest_ms', ['0'] * 11),
                             ('rows', 0), ('ui', 'instant'), ('runtime', 'stub')]:
            with self.subTest(field=field, value=value):
                invalid = copy.deepcopy(self.valid)
                invalid[field] = value
                with self.assertRaises(RuntimeError):
                    supervisor.validate_result(invalid)
        for invalid in [None, [], {}, False]:
            with self.subTest(invalid=invalid):
                with self.assertRaises(RuntimeError):
                    supervisor.validate_result(invalid)


if __name__ == '__main__':
    unittest.main()
