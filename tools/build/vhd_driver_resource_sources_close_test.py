"""Execute the genuine packaging finally with actual held-source descriptors.

Only the original finalizer is extracted, not the native/signing admission. No
compilation, Git source admission, factory image or signed scope is minted.
"""

import ast
import errno
import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import owned_runtime_product_build as product


def finalizer():
    tree = ast.parse(Path(product.__file__).read_text())
    function = next(
        row for row in tree.body if isinstance(row, ast.FunctionDef) and row.name == "_package_live"
    )
    final = next(
        row.finalbody
        for row in reversed(function.body)
        if isinstance(row, ast.Try) and row.finalbody
    )
    frame = ast.parse(
        "def run(sdk, held_sources, backend_source, primary):\n    try:\n        if primary is not None:\n            raise primary\n    finally:\n        pass\n"
    )
    frame.body[0].body[0].finalbody = final
    ast.fix_missing_locations(frame)
    namespace = dict(product.__dict__)
    exec(compile(frame, str(Path(product.__file__)), "exec"), namespace)
    return namespace["run"]


class HeldSourceRetirementControls(unittest.TestCase):
    def setUp(self):
        self.owner = tempfile.TemporaryDirectory(prefix="ergopti-held-source-retirement-")
        self.addCleanup(self.owner.cleanup)
        self.root = Path(self.owner.name).resolve()
        self.real_close = os.close
        self.sources = []
        for index in range(4):
            path = self.root / str(index)
            data = ("frozen source " + str(index)).encode()
            path.write_bytes(data)
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
            self.sources.append(
                product.HeldSource(
                    path,
                    fd,
                    product.identity(os.fstat(fd)),
                    data,
                    "filesystem-control-not-git-qualification",
                )
            )
        self.original_fds = [source.descriptor for source in self.sources]
        self.addCleanup(self.recover)
        self.closed = []

    def recover(self):
        for fd in self.original_fds:
            try:
                os.fstat(fd)
            except OSError as error:
                self.assertEqual(error.errno, errno.EBADF)
            else:
                self.real_close(fd)

    def test_sdk_primary_and_first_close_refusal_preserve_primary_and_close_all_once(self):
        primary = RuntimeError("frozen primary resource refusal")
        original_custody = type("PriorCustody", (), {"debt": True})()
        primary._resource_custody = original_custody
        refusal = OSError("frozen first source close refusal")

        def close(fd):
            self.closed.append(fd)
            self.real_close(fd)
            if fd == self.original_fds[0]:
                raise refusal

        with patch.object(product.os, "close", side_effect=close):
            with self.assertRaises(RuntimeError) as caught:
                finalizer()(True, self.sources[:3], self.sources[3], primary)
        self.assertIs(caught.exception, primary)
        self.assertEqual(self.closed, self.original_fds)
        custody = caught.exception._resource_custody
        self.assertTrue(custody.debt)
        self.assertIs(custody.prior_custody, original_custody)
        self.assertIn(refusal, custody.failures)
        self.assertTrue(all(source.descriptor == -1 for source in self.sources))
        self.assertFalse(custody.owners[0]["closed"])
        self.assertTrue(custody.owners[0]["close_attempted"])

    def test_sdk_clean_body_close_refusal_is_not_a_positive_finalizer(self):
        refusal = OSError("frozen first source close refusal")

        def close(fd):
            self.closed.append(fd)
            self.real_close(fd)
            if fd == self.original_fds[0]:
                raise refusal

        with patch.object(product.os, "close", side_effect=close):
            with self.assertRaises(OSError) as caught:
                finalizer()(True, self.sources[:3], self.sources[3], None)
        self.assertIs(caught.exception, refusal)
        self.assertEqual(self.closed, self.original_fds)
        self.assertTrue(caught.exception._resource_custody.debt)

    def test_legacy_finalizer_behavior_remains_exact_on_first_close_refusal(self):
        primary = RuntimeError("frozen legacy primary")
        refusal = OSError("frozen legacy close refusal")

        def close(fd):
            self.closed.append(fd)
            self.real_close(fd)
            raise refusal

        with patch.object(product.os, "close", side_effect=close):
            with self.assertRaises(OSError) as caught:
                finalizer()(False, self.sources[:3], self.sources[3], primary)
        self.assertIs(caught.exception, refusal)
        self.assertEqual(self.closed, [self.original_fds[0]])
        self.assertFalse(hasattr(caught.exception, "_resource_custody"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
