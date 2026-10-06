// tools/diagnostics/hs274-native-status-test.cpp
// Strict typed fault status excludes forged readiness and incomplete envelopes.
#include "hs274-stream-source.hpp"
#include "hs274-stream-readiness.hpp"
#include <cassert>
using namespace hs274_stream_protocol;
int main() {
  source<64, 8, 4> receiver("status", [] { return 100ULL; });
  const auto pending = receiver.request(1, {{"version", 1u}, {"action", "status"}});
  assert(!readiness{}.observe(pending));
  for (unsigned variation = 0; variation < 4; ++variation) {
    auto forged = pending;
    if (variation == 0) forged.erase("native_fault");
    if (variation == 1) forged["native_fault"] = true;
    if (variation == 2) forged["native_fault"] = "inactive";
    if (variation == 3) forged["native_fault"] = "unknown";
    bool refused = false;
    try { readiness{}.observe(forged); } catch (const std::exception&) { refused = true; }
    assert(refused);
  }
  receiver.native_failure(native_fault::inventory_receipt_write_failed);
  const auto faulted = receiver.request(1, {{"version", 1u}, {"action", "status"}});
  bool explained = false;
  try { readiness{}.observe(faulted); } catch (const std::runtime_error& error) {
    explained = std::string(error.what()) == "Capture native diagnostic refused: inventory_receipt_write_failed";
  }
  assert(explained);
  for (const auto* field : {"exhausted", "ready"}) {
    auto forged = faulted;
    forged[field] = std::string(field) == "ready";
    bool refused = false;
    try { readiness{}.observe(forged); } catch (const std::invalid_argument&) { refused = true; }
    assert(refused);
  }
  receiver.native_failure(native_fault::acquisition_resource_exhausted);
  assert(receiver.native_fault_reason() == native_fault::inventory_receipt_write_failed);
}
