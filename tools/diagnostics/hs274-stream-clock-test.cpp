// tools/diagnostics/hs274-stream-clock-test.cpp
// Match the exported scale to the native API, including its failure boundary.
#include "hs274-stream-clock.hpp"

int main() {
  const auto receipt = hs274_clock::information();
  mach_timebase_info_data_t scale{};
  if (mach_timebase_info(&scale) != KERN_SUCCESS) return 1;
  if (receipt != nlohmann::json{{"version", 1u}, {"domain", "mach_absolute_time"},
                              {"numer", scale.numer}, {"denom", scale.denom}}) return 2;
#ifdef HS274_CLOCK_TEST_STUB
  // The local API double makes otherwise rare native refusals reproducible.
  for (int scenario = 1; scenario <= 3; ++scenario) {
    hs274_clock_test_scenario = scenario;
    bool failed = false;
    try { hs274_clock::information(); } catch (const std::runtime_error&) { failed = true; }
    if (!failed) return 3;
  }
#endif
  return 0;
}
