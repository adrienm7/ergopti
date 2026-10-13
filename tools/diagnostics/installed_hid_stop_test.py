# tools/diagnostics/installed_hid_stop_test.py
"""Execute the real merged HID stop body with genuine nod signal dispatch.

Service monitor destructors are finite fence models. This regression proves
cleanup ordering and primary exception custody, not native IOKit retirement.
"""

import argparse
from pathlib import Path
import subprocess
import tempfile
import unittest


OPTIONS = None
FIXTURE = r"""
#include <nod/nod.hpp>
#include <atomic>
#include <exception>
#include <memory>
#include <functional>
#include <vector>
#include <set>
#include <iostream>
#include <stdexcept>
#include <string>
struct callback_error : std::exception {
  std::shared_ptr<int> identity;
  explicit callback_error(std::shared_ptr<int> value):identity(std::move(value)) {}
};
class manager {
public:
  struct registration {
    std::atomic<bool> invalidated_{false};
    bool completed_=false,failed_=false;
    std::function<void(std::nullptr_t)> completion_;
  };
  struct monitor {
    int* closed;
    explicit monitor(int& count):closed(&count) {}
    ~monitor() { ++*closed; }
  };
  std::shared_ptr<registration> owned_registration_;
  std::shared_ptr<bool> ergopti_inventory_live_=std::make_shared<bool>(true);
  nod::signal<void(const std::vector<unsigned long long>&,bool,bool)> ergopti_inventory_changed;
  std::vector<std::unique_ptr<monitor>> service_monitors_;
  std::vector<int> devices_{1,2},device_matched_called_ids_{1,2},ergopti_completed_watchers_{1,2};
  std::size_t ergopti_watcher_count_=2;
  bool ergopti_failed_=false;
STOP_BODY
};
int main(int argc,char** argv) {
  if (argc!=2) return 99;
  const std::string scenario=argv[1];
  const bool source_throws=scenario=="primary" || scenario=="both" || scenario=="completed";
  const bool completion_throws=scenario=="both" || scenario=="secondary";
  const bool legacy=scenario=="legacy";
  const auto primary=std::make_shared<int>(17),secondary=std::make_shared<int>(27);
  manager value;
  int closed=0,signals=0,completions=0;
  bool fences_before_completion=true;
  const std::weak_ptr<bool> original_lifetime=value.ergopti_inventory_live_;
  for (int i=0;i<3;++i) value.service_monitors_.push_back(std::make_unique<manager::monitor>(closed));
  if (!legacy) {
    value.owned_registration_=std::make_shared<manager::registration>();
    value.owned_registration_->completed_=scenario=="completed";
    value.owned_registration_->completion_=[&](std::nullptr_t) {
      ++completions;
      fences_before_completion=fences_before_completion && closed==3 && value.service_monitors_.empty() &&
        value.devices_.empty() && value.device_matched_called_ids_.empty() &&
        value.ergopti_completed_watchers_.empty() && value.ergopti_watcher_count_==0 && original_lifetime.expired();
      if (completion_throws) throw callback_error(secondary);
    };
  }
  const auto signal_connection=value.ergopti_inventory_changed.connect(
      [&](const auto& ids,bool settled,bool failed) {
        (void)failed;
        ++signals;
        if (!ids.empty() || settled) throw std::runtime_error("wrong withdrawal");
        if (source_throws) throw callback_error(primary);
      });
  (void)signal_connection;
  std::shared_ptr<int> observed;
  try { value.stop(); }
  catch (const callback_error& error) { observed=error.identity; }
  catch (...) { return 90; }
  const auto expected=source_throws?primary:(completion_throws?secondary:nullptr);
  if (observed!=expected) return 10;
  if (signals!=1 || closed!=3 || !value.service_monitors_.empty() || !value.devices_.empty() ||
      !value.device_matched_called_ids_.empty() || !value.ergopti_completed_watchers_.empty() ||
      value.ergopti_watcher_count_!=0 || !original_lifetime.expired() || !fences_before_completion) return 11;
  if (completions!=(legacy || scenario=="completed" ? 0 : 1)) return 12;
  if (value.owned_registration_ && !value.owned_registration_->invalidated_.load()) return 13;
  if (value.owned_registration_ && scenario!="completed" &&
      (!value.owned_registration_->completed_ || !value.owned_registration_->failed_)) return 14;
  if (source_throws && !value.ergopti_failed_) return 15;
  std::cout<<"PASS "<<scenario<<"\n";
  return 0;
}
"""


def stop_body(source):
    text = source.decode("utf-8")
    start = "  void stop() {\n"
    end = "  void ergopti_publish(bool may_settle = true) noexcept {\n"
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError("The actual stop boundaries changed")
    return text[text.index(start) : text.index(end)]


class StopControls(unittest.TestCase):
    """Keep original signal failure after all model native fences close."""

    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="ergopti-hid-stop-")
        cls.root = Path(cls.temporary.name)
        cls.binaries = {}
        for name, source in (("before", OPTIONS.before), ("current", OPTIONS.current)):
            path = cls.root / (name + ".cpp")
            path.write_text(
                FIXTURE.replace("STOP_BODY", stop_body(source.read_bytes())), encoding="utf-8"
            )
            binary = cls.root / name
            result = subprocess.run(
                [
                    "c++",
                    "-std=c++20",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-pthread",
                    "-I",
                    str(OPTIONS.vendor_include),
                    str(path),
                    "-o",
                    str(binary),
                ],
                capture_output=True,
                timeout=60,
                check=False,
            )
            if result.returncode or result.stdout or result.stderr:
                raise RuntimeError("Actual stop compilation refused: " + result.stderr.decode())
            cls.binaries[name] = binary

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def observe(self, scenario, name="current"):
        result = subprocess.run(
            [str(self.binaries[name]), scenario], capture_output=True, timeout=10, check=False
        )
        return result.returncode, result.stdout, result.stderr

    def test_signal_primary_survives_after_all_cleanup_fences(self):
        self.assertEqual(self.observe("primary"), (0, b"PASS primary\n", b""))
        self.assertEqual(self.observe("primary", "before"), (11, b"", b""))

    def test_secondary_startup_failure_cannot_replace_original_primary(self):
        self.assertEqual(self.observe("both"), (0, b"PASS both\n", b""))
        self.assertEqual(self.observe("both", "before"), (11, b"", b""))

    def test_completion_error_propagates_after_cleanup(self):
        self.assertEqual(self.observe("secondary"), (0, b"PASS secondary\n", b""))

    def test_completed_startup_is_never_completed_twice(self):
        self.assertEqual(self.observe("completed"), (0, b"PASS completed\n", b""))
        self.assertEqual(self.observe("completed", "before"), (11, b"", b""))

    def test_normal_pending_startup_gets_null_after_cleanup(self):
        self.assertEqual(self.observe("pending"), (0, b"PASS pending\n", b""))
        self.assertEqual(self.observe("pending", "before"), (0, b"PASS pending\n", b""))

    def test_normal_legacy_stop_keeps_original_signal_and_reset(self):
        self.assertEqual(self.observe("legacy"), (0, b"PASS legacy\n", b""))
        self.assertEqual(self.observe("legacy", "before"), (0, b"PASS legacy\n", b""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--current", type=Path, required=True)
    parser.add_argument("--vendor-include", type=Path, required=True)
    OPTIONS = parser.parse_args()
    unittest.main(argv=[__file__], verbosity=2)
