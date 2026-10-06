// tools/diagnostics/hs274-native-fence-test.cpp
// Exact receiver selection fences detach and foreign selector reentry.
#include "hs274-stream-source.hpp"
#include "hs274-stream-native-boundary.hpp"
#include <cassert>
#include <memory>
using namespace hs274_stream_protocol;
using receiver_type = source<64, 8, 4>;
int main() {
  {
    receiver_type original("original", [] { return 100ULL; });
    receiver_type successor("successor", [] { return 200ULL; });
    auto owner = original.native_attach(1, false, hs274_key_policy::keyboard_type::none);
    auto* selected = &original;
    unsigned faults = 0;
    const auto current = [&](const auto& fence) { return selected && fence.belongs_to(*selected); };
    const bool accepted = diagnostic_acquisition(owner, [&](native_fault) { ++faults; }, [&] {
      selected = &successor;
      return true;
    }, current);
    assert(!accepted && faults == 0 && owner.active());
    assert(original.native_fault_reason() == native_fault::none);
    assert(successor.native_fault_reason() == native_fault::none);
    unsigned queries = 0;
    assert(!diagnostic_acquisition(owner, [&](native_fault) { ++faults; }, [&] { ++queries; return true; }, current));
    assert(queries == 0 && faults == 0);
  }
  {
    auto original = std::make_unique<receiver_type>("selector", [] { return 100ULL; });
    auto owner = original->native_attach(1, false, hs274_key_policy::keyboard_type::none);
    unsigned queries = 0;
    const bool accepted = diagnostic_acquisition(owner, [](native_fault) {}, [&] { ++queries; return true; },
        [&](const auto&) { original.reset(); return true; });
    assert(!accepted && queries == 0 && !owner.active());
  }
}
