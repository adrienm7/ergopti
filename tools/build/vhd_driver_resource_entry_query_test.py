"""Actual original HeldSource finalization when the initial mask query refuses."""

import signal
import unittest
from unittest.mock import patch

import owned_runtime_product_build as product
import vhd_driver_resource_sources_close_test as source_controls


class EntryQueryRefusalControls(unittest.TestCase):
    def setUp(self):
        self.fixture = source_controls.HeldSourceRetirementControls()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
        self.addCleanup(signal.pthread_sigmask, signal.SIG_SETMASK, self.mask)
        self.original_query = signal.pthread_sigmask
        self.refusal = OSError("frozen initial signal-mask query refusal")

    def query(self, how, values):
        if how == signal.SIG_BLOCK and not values:
            raise self.refusal
        return self.original_query(how, values)

    def closed(self, fd):
        self.fixture.closed.append(fd)
        self.fixture.real_close(fd)

    def invoke(self, primary):
        with (
            patch.object(product.signal, "pthread_sigmask", side_effect=self.query),
            patch.object(product.os, "close", side_effect=self.closed),
        ):
            source_controls.finalizer()(
                True, self.fixture.sources[:3], self.fixture.sources[3], primary
            )

    def assert_retired_with_mask_debt(self, error):
        self.assertEqual(self.fixture.closed, self.fixture.original_fds)
        self.assertTrue(all(source.descriptor == -1 for source in self.fixture.sources))
        custody = error._resource_custody
        self.assertTrue(custody.debt)
        self.assertFalse(custody.mask_restored)
        self.assertIn(self.refusal, custody.failures)
        self.assertTrue(all(owner["closed"] for owner in custody.owners))

    def test_initial_query_refusal_closes_sources_and_retains_original_primary(self):
        primary = RuntimeError("frozen original resource primary")
        with self.assertRaises(RuntimeError) as caught:
            self.invoke(primary)
        self.assertIs(caught.exception, primary)
        self.assert_retired_with_mask_debt(caught.exception)

    def test_initial_query_refusal_closes_sources_and_retains_refusal_without_primary(self):
        with self.assertRaises(OSError) as caught:
            self.invoke(None)
        self.assertIs(caught.exception, self.refusal)
        self.assert_retired_with_mask_debt(caught.exception)


if __name__ == "__main__":
    unittest.main(verbosity=2)
