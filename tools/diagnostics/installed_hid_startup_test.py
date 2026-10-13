# tools/diagnostics/installed_hid_startup_test.py
"""Execute the actual typed startup predicates over finite native port models.

The retained service registration, Blocks callback and manager publish/progress
methods are compiled without rewriting their bodies. IOKit discovery and actual
native scheduling remain unqualified by these controls.
"""

import argparse
from pathlib import Path
import subprocess
import tempfile
import unittest


OPTIONS = None
PORTS = r"""
#include <nod/nod.hpp>
#include <pqrs/osx/iokit_types/iokit_registry_entry_id.hpp>
#include <atomic>
#include <functional>
#include <memory>
#include <unordered_set>
#include <map>
#include <vector>
#include <stdexcept>
#include <iostream>
#include <string>
namespace ergoptiplus::remap { inline constexpr std::size_t native_interface_capacity=64; }
namespace krbn::core_service::daemon { class device_grabber; }
namespace pqrs::osx {
class iokit_hid_manager;
class iokit_service_monitor {
  friend class iokit_hid_manager;
SERVICE_REGISTRATION
SERVICE_METHOD
  struct iterator_port { int handle=1; bool valid_value=true; int get() const { return handle; }
    bool valid() const { return valid_value; } } matched_notification_,terminated_notification_;
  struct thread_port { void enqueue(void (^body)()) { body(); } };
  std::shared_ptr<thread_port> run_loop_thread_=std::make_shared<thread_port>();
  std::shared_ptr<owned_registration> owned_registration_;
  int notification_port_=1;
  bool owned_initial_inventory_valid_=true;
  std::shared_ptr<bool> ergopti_inventory_live_;
  int started_=0;
  bool model_initial_valid_=true,model_start_throws_=false;
  void start() {
START_PREFIX
    ++started_;
    if (model_start_throws_) throw std::runtime_error("native allocation refused");
    ergopti_initial_valid=model_initial_valid_;
START_FINISH
    (void)ergopti_success;
  }
  template<class F> bool enqueue_to_dispatcher(F body) { body();return true; }
};
class iokit_hid_manager {
MANAGER_REGISTRATION
PROGRESS_METHOD
PUBLISH_METHOD
  std::shared_ptr<owned_registration> owned_registration_;
  bool ergopti_failed_=false;
  std::size_t ergopti_watcher_count_=1;
  std::unordered_set<int> ergopti_completed_watchers_{1};
  std::map<iokit_registry_entry_id::value_t,int> devices_;
  std::unordered_set<iokit_registry_entry_id::value_t> device_matched_called_ids_;
  nod::signal<void(const std::vector<iokit_registry_entry_id::value_t>&,bool,bool)> ergopti_inventory_changed;
public:
  static int control(const std::string& scenario) {
    iokit_hid_manager manager;
    auto service=std::make_shared<iokit_service_monitor>();
    const bool scope=scenario!="scope-refused";
    if (scenario=="initial-invalid") service->model_initial_valid_=false;
    if (scenario=="start-throws") {
      service->owned_initial_inventory_valid_=true;
      service->model_start_throws_=true;
      try { service->start(); } catch (const std::runtime_error&) {}
      return service->owned_initial_inventory_valid_ ? 16 : 0;
    }
    if (scenario=="iterator-invalid") service->matched_notification_.valid_value=false;
    if (scenario=="missing-handle") service->matched_notification_.handle=0;
    std::shared_ptr<const iokit_service_monitor::owned_registration> native;
    bool called=false;
    const auto admitted=service->async_owned_start([scope] { return scope; },[&](auto result) {
      called=true;native=std::move(result);
    });
    if (!admitted || !called) return 80;
    if (scenario=="initial-invalid" || scenario=="iterator-invalid" ||
        scenario=="missing-handle" || scenario=="scope-refused") {
      if (native) return 11;
      if (service->started_!=(scope?1:0)) return 12;
      return 0;
    }
    if (!native || !native->current()) return 13;
    auto receipt=std::shared_ptr<owned_registration>(new owned_registration({}));
    manager.owned_registration_=receipt;
    receipt->expected_=1;
    receipt->monitors_.push_back(native);
    const bool fail=scenario=="null-dictionary" || scenario=="late-failure";
    if (scenario=="late-failure" || scenario=="delivery-throws") receipt->completed_=true;
    manager.ergopti_failed_=fail; // Native discovery failure port: one valid monitor plus null dictionary, or later loss.
    bool completed=false,positive=false;
    receipt->completion_=[&](auto value) { completed=true;positive=static_cast<bool>(value); };
    int signals=0;
    const auto connection=manager.ergopti_inventory_changed.connect([&](const auto&,bool,bool failed) {
      ++signals;
      if (scenario=="delivery-throws" && signals==1) throw std::runtime_error("first delivery refused");
      if (scenario=="delivery-throws" && !failed) throw std::runtime_error("failure delivery absent");
    });
    (void)connection;
    manager.ergopti_publish();
    manager.progress_owned_start();
    if (scenario=="delivery-throws" && signals!=2) return 17;
    if (scenario=="late-failure" || scenario=="delivery-throws") {
      if (completed || receipt->current() || !receipt->failed_) return 14;
    } else {
      if (!completed || positive==fail || receipt->current()==fail) return 15;
    }
    return 0;
  }
};
}
int main(int argc,char** argv) {
  if (argc!=2) return 99;
  return pqrs::osx::iokit_hid_manager::control(argv[1]);
}
"""


def declaration(text, start):
    """Retain one complete authentic class or method by its literal braces."""
    if text.count(start) != 1:
        raise ValueError("Actual declaration anchor changed")
    begin = text.index(start)
    opened = text.index("{", begin)
    depth = 0
    for offset in range(opened, len(text)):
        if text[offset] == "{":
            depth += 1
        elif text[offset] == "}":
            depth -= 1
            if depth == 0:
                finish = offset + 1
                if text[finish : finish + 1] == ";":
                    finish += 1
                return text[begin:finish]
    raise ValueError("Actual declaration did not close")


def source(manager, service):
    start_prefix = service.split("  void start() {\n", 1)[1].split(
        "    if (!notification_port_)", 1
    )[0]
    finish = service.split("    const bool ergopti_success =", 1)[1].split(
        "    enqueue_to_dispatcher", 1
    )[0]
    return (
        PORTS.replace("START_PREFIX", start_prefix)
        .replace("START_FINISH", "    const bool ergopti_success =" + finish)
        .replace("SERVICE_REGISTRATION", declaration(service, "  class owned_registration final {"))
        .replace("SERVICE_METHOD", declaration(service, "  bool async_owned_start("))
        .replace("MANAGER_REGISTRATION", declaration(manager, "  class owned_registration final {"))
        .replace("PROGRESS_METHOD", declaration(manager, "  void progress_owned_start() {"))
        .replace(
            "PUBLISH_METHOD",
            declaration(manager, "  void ergopti_publish(bool may_settle = true) noexcept {"),
        )
    )


class StartupControls(unittest.TestCase):
    """Retain actual failed native observations in the typed source owner."""

    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="ergopti-hid-startup-")
        cls.root = Path(cls.temporary.name)
        cls.binaries = {}
        for name, manager, monitor in (
            ("before", OPTIONS.before_manager, OPTIONS.before_monitor),
            ("current", OPTIONS.current_manager, OPTIONS.current_monitor),
        ):
            path = cls.root / (name + ".cpp")
            path.write_text(source(manager.read_text(), monitor.read_text()), encoding="utf-8")
            binary = cls.root / name
            result = subprocess.run(
                [
                    str(OPTIONS.compiler),
                    "-std=c++20",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-fblocks",
                    "-pthread",
                    "-I",
                    str(OPTIONS.vendor_include),
                    str(path),
                    str(OPTIONS.blocks_library),
                    "-o",
                    str(binary),
                ],
                capture_output=True,
                timeout=60,
                check=False,
            )
            if result.returncode or result.stdout or result.stderr:
                raise RuntimeError("Actual startup compilation refused: " + result.stderr.decode())
            cls.binaries[name] = binary

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def observe(self, scenario, name="current"):
        result = subprocess.run(
            [str(self.binaries[name]), scenario], capture_output=True, timeout=10, check=False
        )
        return result.returncode, result.stdout, result.stderr

    def test_initial_invalid_nonzero_iterators_cannot_grant_registration(self):
        self.assertEqual(self.observe("initial-invalid"), (0, b"", b""))
        self.assertEqual(self.observe("initial-invalid", "before"), (11, b"", b""))

    def test_current_invalid_nonzero_iterator_cannot_grant_registration(self):
        self.assertEqual(self.observe("iterator-invalid"), (0, b"", b""))
        self.assertEqual(self.observe("iterator-invalid", "before"), (11, b"", b""))

    def test_null_dictionary_failure_revokes_typed_startup(self):
        self.assertEqual(self.observe("null-dictionary"), (0, b"", b""))
        self.assertEqual(self.observe("null-dictionary", "before"), (15, b"", b""))

    def test_later_inventory_failure_revokes_completed_registration(self):
        self.assertEqual(self.observe("late-failure"), (0, b"", b""))
        self.assertEqual(self.observe("late-failure", "before"), (14, b"", b""))

    def test_throwing_inventory_delivery_revokes_typed_registration_before_retry(self):
        self.assertEqual(self.observe("delivery-throws"), (0, b"", b""))
        self.assertEqual(self.observe("delivery-throws", "before"), (14, b"", b""))

    def test_new_native_start_cannot_reuse_previous_validity_after_throw(self):
        self.assertEqual(self.observe("start-throws"), (0, b"", b""))
        self.assertEqual(self.observe("start-throws", "before"), (16, b"", b""))

    def test_missing_handle_and_scope_refusal_remain_closed(self):
        for scenario in ("missing-handle", "scope-refused"):
            with self.subTest(scenario=scenario):
                self.assertEqual(self.observe(scenario), (0, b"", b""))
                self.assertEqual(self.observe(scenario, "before"), (0, b"", b""))

    def test_valid_native_observation_keeps_existing_completion(self):
        self.assertEqual(self.observe("valid"), (0, b"", b""))
        self.assertEqual(self.observe("valid", "before"), (0, b"", b""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in (
        "before-manager",
        "before-monitor",
        "current-manager",
        "current-monitor",
        "vendor-include",
        "compiler",
        "blocks-library",
    ):
        parser.add_argument("--" + name, type=Path, required=True)
    OPTIONS = parser.parse_args()
    unittest.main(argv=[__file__], verbosity=2)
