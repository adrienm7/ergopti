// tools/diagnostics/hs274-native-acquisition-test.cpp
// Portable diagnostic containment never represents native device acquisition.
#include "hs274-stream-source.hpp"
#include "hs274-stream-native-boundary.hpp"
#include <cassert>
#include <new>
#include <stdexcept>
using namespace hs274_stream_protocol;
int main() {
  using receiver_type = source<64, 8, 4>;
  for (bool allocation : {false, true}) {
    receiver_type receiver("acquisition", [] { return 100ULL; });
    auto owner = receiver.native_attach(1, false, hs274_key_policy::keyboard_type::none);
    unsigned ordinary_started = 0, acquisitions = 0;
    const bool observed = diagnostic_acquisition(owner,
        [&](native_fault reason) { receiver.native_failure(reason); }, [&]() -> bool {
      ++acquisitions;
      if (allocation) throw std::bad_alloc();
      throw native_acquisition_error(native_fault::inventory_receipt_write_failed);
    });
    ++ordinary_started; // This original callback remains outside diagnostic containment.
    assert(!observed);
    assert(ordinary_started == 1);
    assert(acquisitions == 1);
    assert(receiver.native_fault_reason() == (allocation ? native_fault::acquisition_resource_exhausted
                                                        : native_fault::inventory_receipt_write_failed));
    const auto status = receiver.request(1, {{"version", 1u}, {"action", "status"}});
    assert(status.at("ready") == false);
    assert(status.at("exhausted") == true);
  }
  receiver_type receiver("unexpected", [] { return 100ULL; });
  auto owner = receiver.native_attach(1, false, hs274_key_policy::keyboard_type::none);
  bool propagated = false;
  try { diagnostic_acquisition(owner, [&](native_fault reason) { receiver.native_failure(reason); },
      []() -> bool { throw std::logic_error("unexpected program defect"); }); }
  catch (const std::logic_error&) { propagated = true; }
  assert(propagated);
  assert(receiver.native_fault_reason() == native_fault::none);
  auto inactive = receiver.native_attach(0, false, hs274_key_policy::keyboard_type::none);
  unsigned forbidden_queries = 0;
  assert(!diagnostic_acquisition(inactive, [&](native_fault reason) { receiver.native_failure(reason); },
      [&]() { ++forbidden_queries; return true; }));
  assert(forbidden_queries == 0);
}
