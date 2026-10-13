# tools/diagnostics/installed_cli_frontend_test.py
"""Execute the generated CLI dispatch with the genuine fixed option parser.

The native capture owner is a finite port model. These controls qualify option
dispatch and refusal propagation; they do not qualify native capture, Core
readiness, installation, or a physical keyboard.
"""

import argparse
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


OPTIONS = None
PORTS = r"""
#include <cxxopts.hpp>
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <string>
namespace hs274_clock {
struct clock_information { std::string dump() const { return "clock"; } };
inline clock_information information() { return {}; }
}
namespace krbn::cli::hs274_capture {
inline int run(int interval) { std::cout << "legacy:" << interval; return 42; }
}
namespace krbn::cli::installed_capture {
inline int run(int interval) {
  if (interval <= 0) throw std::invalid_argument("invalid interval");
  const auto mode = std::getenv("ERGOPTI_FRONTEND_CONTROL");
  if (mode && std::string(mode) == "refuse") throw std::runtime_error("private detail");
  std::cout << "installed:" << interval;
  return mode && std::string(mode) == "retirement-debt" ? 70 : 0;
}
}
int main(int argc, char** argv) {
  cxxopts::Options options("actual-cli-dispatch");
  options.add_options()("silent", "Suppress messages",
      cxxopts::value<bool>()->default_value("false"));
REGISTRATION
  int exit_code = 0;
  try {
    auto parse_result = options.parse(argc, argv);
DISPATCH
    (void)silent;
    exit_code = 41;
  } catch (const cxxopts::exceptions::exception&) { exit_code = 2; }
finish:
  return exit_code;
}
"""


def _span(text, start, end):
    """Retain one actual statement range, without rewriting its body."""
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError("The authentic dispatch boundary changed")
    begin = text.index(start)
    finish = text.index(end, begin)
    return text[begin:finish]


def _harness(source):
    text = source.decode("utf-8")
    registration = _span(
        text,
        '  options.add_options()("hs274-clock",',
        '  options.add_options()("select-profile",',
    )
    dispatch = _span(
        text,
        '    bool silent = parse_result["silent"].as<bool>();',
        '    {\n      std::string key = "select-profile";',
    )
    return PORTS.replace("REGISTRATION", registration).replace("DISPATCH", dispatch)


class FrontendControls(unittest.TestCase):
    """Receive real argument parsing and actual generated branch execution."""

    @classmethod
    def setUpClass(cls):
        specification = importlib.util.spec_from_file_location("cli_frontend", OPTIONS.supplier)
        module = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(module)
        cls.temporary = tempfile.TemporaryDirectory(prefix="ergopti-cli-frontend-")
        cls.root = Path(cls.temporary.name)
        cls.original = OPTIONS.legacy.read_bytes()
        cls.generated = module.render(cls.original)
        cls.module = module
        cls.binaries = {}
        for name, source in (("before", cls.original), ("current", cls.generated)):
            path = cls.root / (name + ".cpp")
            path.write_text(_harness(source), encoding="utf-8")
            binary = cls.root / name
            result = subprocess.run(
                [
                    "c++",
                    "-std=c++20",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-I",
                    str(OPTIONS.parser_include),
                    str(path),
                    "-o",
                    str(binary),
                ],
                capture_output=True,
                timeout=60,
                check=False,
            )
            if result.returncode or result.stdout or result.stderr:
                raise RuntimeError("Actual dispatch compilation refused: " + result.stderr.decode())
            cls.binaries[name] = binary

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def observe(self, arguments, name="current", mode=""):
        environment = dict(os.environ)
        environment.pop("ERGOPTI_FRONTEND_CONTROL", None)
        if mode:
            environment["ERGOPTI_FRONTEND_CONTROL"] = mode
        result = subprocess.run(
            [str(self.binaries[name]), *arguments],
            capture_output=True,
            timeout=10,
            check=False,
            env=environment,
        )
        return result.returncode, result.stdout, result.stderr

    def test_fixed_launcher_arguments_reach_original_installed_owner(self):
        self.assertEqual(
            self.observe(["--installed-physical-capture", "25"]), (0, b"installed:25", b"")
        )
        self.assertEqual(
            self.observe(["--installed-physical-capture", "25"], "before"), (2, b"", b"")
        )

    def test_positive_interval_is_forwarded_without_a_new_default(self):
        self.assertEqual(
            self.observe(["--installed-physical-capture", "37"]), (0, b"installed:37", b"")
        )

    def test_native_admission_refusal_has_no_private_error_detail(self):
        self.assertEqual(
            self.observe(["--installed-physical-capture", "25"], mode="refuse"),
            (1, b"", b"Installed physical source admission refused\n"),
        )

    def test_native_retirement_debt_status_is_preserved(self):
        self.assertEqual(
            self.observe(["--installed-physical-capture", "25"], mode="retirement-debt"),
            (70, b"installed:25", b""),
        )

    def test_invalid_interval_refuses_without_starting_a_mode(self):
        for interval in ("0", "-1"):
            with self.subTest(interval=interval):
                self.assertEqual(
                    self.observe(["--installed-physical-capture", interval]),
                    (1, b"", b"Installed physical source admission refused\n"),
                )

    def test_missing_interval_is_a_real_parser_refusal(self):
        self.assertEqual(self.observe(["--installed-physical-capture"]), (2, b"", b""))

    def test_legacy_clock_capture_and_default_dispatch_are_unchanged(self):
        for arguments, expected in (
            ([], (41, b"", b"")),
            (["--hs274-clock"], (0, b"clock\n", b"")),
            (["--hs274-capture", "25"], (42, b"legacy:25", b"")),
        ):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.observe(arguments, "before"), expected)
                self.assertEqual(self.observe(arguments), expected)

    def test_drift_and_reapplication_are_refused(self):
        for source in (self.generated, self.original + b"\n", bytearray(self.original)):
            with self.assertRaises(ValueError):
                self.module.render(source)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--supplier", type=Path, required=True)
    parser.add_argument("--legacy", type=Path, required=True)
    parser.add_argument("--parser-include", type=Path, required=True)
    OPTIONS = parser.parse_args()
    unittest.main(argv=[__file__], verbosity=2)
