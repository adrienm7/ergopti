"""Runner for the Ergopti XKB installer test suites.

Usage (from anywhere):

    python static/ergopti/linux/xkb_installation/tests/run_all_tests.py
"""

import sys
import unittest
from pathlib import Path

if __name__ == "__main__":
    tests_dir = Path(__file__).resolve().parent
    loader = unittest.TestLoader()
    suite = loader.discover(start_dir=str(tests_dir), top_level_dir=str(tests_dir))
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
