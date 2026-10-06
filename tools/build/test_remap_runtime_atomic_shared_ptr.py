# tools/build/test_remap_runtime_atomic_shared_ptr.py
"""Compile actual registry atomics with genuine C++23 shared_ptr operations.

Only the enclosing Darwin watch, publication and dispatch leaves are modeled.
The capability-negative fixture removes the host libstdc++ specialization, not
the actual registry or shared_ptr free functions. It grants no native authority.
"""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


PRELUDE = r"""
#include <atomic>
#include <memory>
#include <mutex>
#include <vector>
#include <functional>
#include <cstdint>
#include <new>
#include <unistd.h>
#include <thread>
#include <iostream>
#include <cstdlib>
#include <type_traits>
static_assert(__cplusplus >= 202100L, "The control requires actual C++23");
#ifdef ERGOPTI_FIXTURE_NO_ATOMIC_SHARED_PTR
#undef __cpp_lib_atomic_shared_ptr
#endif
inline void* dispatch_get_main_queue() { return nullptr; }
inline void dispatch_async_f(void*, void*, void (*)(void*)) { std::abort(); }
namespace ergoptiplus::remap::auth {
class channel_owner;
class socket_lifetime;
class owned_console_parent_watch { public: bool current() const { return false; } };
namespace detail {
class console_runtime_binding;
struct publication_gate {
  std::mutex mutex_;
  bool stopped_ = false;
  const std::uint64_t generation_ = 1;
};
"""

CONTROL = r"""
}}
namespace detail = ergoptiplus::remap::auth::detail;
void require(bool condition, unsigned code) { if (!condition) std::exit(code); }
int main() {
  using registry = detail::console_registry;
  using pointer = registry::entry_ptr;
  static_assert(!std::is_copy_constructible_v<decltype(registry::current_)>);
  static_assert(!std::is_copy_assignable_v<decltype(registry::current_)>);
  auto watch = std::make_shared<ergoptiplus::remap::auth::owned_console_parent_watch>();
  pointer one = std::make_shared<registry::entry>(watch, 1, 501);
  pointer two = std::make_shared<registry::entry>(watch, 2, 501);
  pointer expected;
  require(!registry::current_.load(), 1);
  require(registry::current_.compare_exchange_strong(expected, one) && !expected, 2);
  require(!registry::current_.compare_exchange_strong(expected, two) && expected == one, 3);
  // Equal pointees with different ownership must not replace the real owner.
  pointer foreign(one.get(), [](registry::entry*) {});
  require(!registry::current_.compare_exchange_strong(foreign, two) &&
          !foreign.owner_before(one) && !one.owner_before(foreign), 4);
  expected = one;
  require(registry::current_.compare_exchange_strong(expected, two) && expected == one, 5);
  require(!registry::current_.compare_exchange_strong(expected, nullptr) && expected == two &&
          registry::current_.load() == two, 6);
  std::weak_ptr<registry::entry> retained = two;
  require(registry::current_.compare_exchange_strong(expected, nullptr) &&
          !registry::current_.load() && !retained.expired(), 7);
  two.reset(); expected.reset(); require(retained.expired(), 8);
  // Real simultaneous CAS contenders: exactly one owns the empty slot.
  std::atomic<unsigned> ready{0}, winners{0};
  std::atomic<bool> start{false};
  std::vector<std::thread> workers;
  for (unsigned index = 0; index != 4; ++index) {
    workers.emplace_back([&, index] {
      pointer candidate = std::make_shared<registry::entry>(watch, index + 3, 501);
      ++ready; while (!start.load()) std::this_thread::yield();
      pointer empty;
      if (registry::current_.compare_exchange_strong(empty, candidate)) ++winners;
      else require(empty && registry::current_.load() == empty, 9);
    });
  }
  while (ready.load() != 4) std::this_thread::yield();
  start.store(true);
  for (auto& worker : workers) worker.join();
  require(winners.load() == 1, 10);
  expected = registry::current_.load();
  require(expected && registry::current_.compare_exchange_strong(expected, nullptr), 11);
  std::cout << "portable_registry_atomic_cases=9; native_darwin_executed=0\n";
}
"""


class RegistryAtomicCompatibility(unittest.TestCase):
    """Compile fixed expectations against the actual private registry body."""

    def registry_source(self):
        path = Path(__file__).with_name("remap_runtime_auth.hpp")
        source = path.read_text()
        beginning = "class console_registry final {"
        ending = "\n};\n}\n\nclass channel_owner final"
        self.assertEqual(source.count(beginning), 1)
        self.assertEqual(source.count(ending), 1)
        actual = source[source.index(beginning) : source.index(ending) + len("\n};")]
        self.assertEqual(actual.count("private:"), 1)
        # Fixture visibility only; every production registry method stays exact.
        return PRELUDE + actual.replace("private:", "public:", 1) + CONTROL

    def compile_control(self, root, include=None):
        compiler = shutil.which(os.environ.get("CXX", "c++"))
        self.assertIsNotNone(compiler, "An actual C++23 compiler is required")
        cpp = root / "control.cpp"
        cpp.write_text(self.registry_source())
        command = [compiler, "-std=c++23", "-O0", "-pthread"]
        if include is not None:
            # This deliberately altered GNU library retains deprecation labels.
            # It models missing specialization, not genuine libc++ warning policy.
            command.extend(["-I", str(include), "-DERGOPTI_FIXTURE_NO_ATOMIC_SHARED_PTR"])
        else:
            command.extend(["-Wall", "-Wextra", "-Werror"])
        binary = root / "control"
        result = subprocess.run(
            command + [str(cpp), "-o", str(binary)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            result.stdout,
            "portable_registry_atomic_cases=9; native_darwin_executed=0\n",
        )
        self.assertEqual(result.stderr, "")

    def test_actual_registry_with_host_shared_ptr_atomics(self):
        with tempfile.TemporaryDirectory(prefix="ergopti-registry-atomic-") as directory:
            self.compile_control(Path(directory))

    def test_actual_registry_without_host_atomic_shared_ptr_specialization(self):
        compiler = shutil.which(os.environ.get("CXX", "c++"))
        self.assertIsNotNone(compiler, "An actual C++23 compiler is required")
        probe = subprocess.run(
            [compiler, "-std=c++23", "-H", "-fsyntax-only", "-x", "c++", "-"],
            input="#include <memory>\n",
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(probe.returncode, 0, probe.stderr)
        paths = {
            line.lstrip(". ")
            for line in probe.stderr.splitlines()
            if line.lstrip(". ").endswith("/bits/shared_ptr_atomic.h")
        }
        if not paths:
            self.skipTest("The capability-negative fixture specifically models host libstdc++")
        self.assertEqual(len(paths), 1)
        original_path = Path(paths.pop())
        original = original_path.read_bytes()
        guard = b"#ifdef  __glibcxx_atomic_shared_ptr // C++ >= 20 && HOSTED"
        self.assertEqual(original.count(guard), 1, "Reviewed host capability boundary changed")
        with tempfile.TemporaryDirectory(prefix="ergopti-registry-no-specialization-") as directory:
            root = Path(directory)
            header = root / "bits/shared_ptr_atomic.h"
            header.parent.mkdir()
            header.write_bytes(
                original.replace(guard, b"#if 0 // Fixture: specialization unavailable")
            )
            self.compile_control(root, root)
            self.assertEqual(
                header.read_bytes().replace(b"#if 0 // Fixture: specialization unavailable", guard),
                original,
            )
            self.assertEqual(original_path.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
