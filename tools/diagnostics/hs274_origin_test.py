# tools/diagnostics/hs274_origin_test.py
"""Execute the capture transformation across native and reconstructed callbacks."""

import json
from contextlib import ExitStack
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from hs274_raw_patch import REVISION, instrument_monitor, main
from hs274_stream_patch import qualify_native_keys


FIXTURE = r'''#pragma once
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>
namespace type_safe { template<class T> T get(T value) { return value; } }
namespace pqrs::osx::chrono { using absolute_time_point = unsigned long long; }
struct Value {
  std::optional<int> get_usage_page() const { return 7; }
  std::optional<int> get_usage() const { return 44; }
  unsigned long long get_time_stamp() const { return 100; }
  int get_integer_value() const { return 1; }
};
using Values = std::shared_ptr<std::vector<Value>>;
struct Signal {
  std::function<void(Values)> callback;
  template<class F> void connect(F fn) { callback = fn; }
};
struct Device { Signal input_values_arrived; };
struct Properties {
  int get_device_id() const { return 41; }
  std::string get_product() const { return "HS274 CI Keyboard"; }
} device_properties;
class Monitor {
public:
  Monitor() :
        last_time_stamp_(0) {
    device_events_monitor_->input_values_arrived.connect([this](auto&& values) {
      auto hid_values = values;
      input_values_arrived(hid_values);
    });
  }
  void native(Values values) { device_events_monitor_->input_values_arrived.callback(values); }
  void reconstructed(Values values) { input_values_arrived(values); }
  int delivered = 0;
private:
  void input_values_arrived(Values hid_values) {
    normalize_time_stamps(*hid_values);
    delivered += static_cast<int>(hid_values->size());
  }
  void normalize_time_stamps(std::vector<Value>&) { ++last_time_stamp_; }
  std::shared_ptr<Device> device_events_monitor_ = std::make_shared<Device>();
  pqrs::osx::chrono::absolute_time_point last_time_stamp_;
};
'''


class OriginTests(unittest.TestCase):
    def test_stream_staging_contains_every_capture_include(self):
        with tempfile.TemporaryDirectory(prefix="hs274-staging-") as directory, ExitStack() as scope:
            root = Path(directory).resolve()

            def baseline(command, **kwargs):
                if command[-2] == "rev-parse":
                    return REVISION
                target = root / command[-1].removeprefix("HEAD:")
                target.parent.mkdir(parents=True, exist_ok=True)
                source = b"#pragma once\n  return 0;\n"
                target.write_bytes(source)
                return source

            scope.enter_context(patch("hs274_raw_patch.subprocess.check_output", side_effect=baseline))
            # Staging is the boundary under test; source transformations have
            # their own compiled regressions and do not need an upstream clone.
            for name in ("stream_monitor", "stream_operations", "stream_receiver", "stream_client",
                         "stream_cli", "stream_server", "stream_entry", "stream_socket_ops"):
                scope.enter_context(patch("hs274_stream_patch." + name, lambda source: source))
            main(root, stream=True)
            shared = root / "src/share"
            self.assertTrue((shared / "hs274-stream-cli.hpp").is_file())
            for header in shared.glob("hs274-*.hpp"):
                for dependency in re.findall(r'#include "(hs274-[^"]+)"', header.read_text(encoding="utf-8")):
                    self.assertTrue((shared / dependency).is_file(),
                                    f"Staged {header.name} cannot include missing {dependency}")

    def test_native_descriptor_rejection_preserves_remapping_values(self):
        with tempfile.TemporaryDirectory(prefix="hs274-element-") as directory:
            root = Path(directory)
            fixture = Path(__file__).with_name("hs274-key-element-test.cpp")
            source = root / "element.cpp"
            source.write_text(qualify_native_keys(fixture.read_text(encoding="utf-8")), encoding="utf-8", newline="\n")
            binary = root / ("element.exe" if os.name == "nt" else "element")
            subprocess.run([os.environ.get("CXX", "c++"), "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(fixture.parent), str(source), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

    def test_reconstructed_values_keep_output_but_cannot_enter_native_capture(self):
        with tempfile.TemporaryDirectory(prefix="hs274-origin-") as directory:
            root = Path(directory)
            (root / "monitor.hpp").write_text(instrument_monitor(FIXTURE), encoding="utf-8", newline="\n")
            (root / "main.cpp").write_text('''#include "monitor.hpp"
int main() {
  Monitor monitor;
  auto values = std::make_shared<std::vector<Value>>(1);
  monitor.native(values);
  monitor.reconstructed(values);
  if (monitor.delivered != 2) return 2;
  return hs274_raw_capture::finish() ? 0 : 3;
}
''', encoding="utf-8", newline="\n")
            binary = root / ("origin.exe" if os.name == "nt" else "origin")
            subprocess.run([os.environ.get("CXX", "c++"), "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(Path(__file__).parent), str(root / "main.cpp"), "-o", str(binary)], check=True)
            output = subprocess.run([str(binary)], check=True, capture_output=True, text=True).stdout
            self.assertTrue(output.startswith("HS274_RAW_CAPTURE "))
            capture = json.loads(output.removeprefix("HS274_RAW_CAPTURE "))
            self.assertEqual(capture["seen"], 1)
            self.assertEqual(capture["overflow"], 0)
            self.assertEqual(capture["contention"], 0)
            self.assertEqual([(row["device"], row["usage"], row["value"]) for row in capture["records"]], [(41, 44, 1)])


if __name__ == "__main__":
    unittest.main()
