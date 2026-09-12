// tools/diagnostics/fixtures/hs274-clock-stub/mach/mach_time.h
// Compile-only native API double; never include this directory in a producer build.
#pragma once
#include <cstdint>
#define HS274_CLOCK_TEST_STUB 1
inline int hs274_clock_test_scenario = 0;
constexpr int KERN_SUCCESS = 0;
struct mach_timebase_info_data_t { std::uint32_t numer, denom; };
inline int mach_timebase_info(mach_timebase_info_data_t* value) {
  value->numer = hs274_clock_test_scenario == 2 ? 0 : 125;
  value->denom = hs274_clock_test_scenario == 3 ? 0 : 3;
  return hs274_clock_test_scenario == 1 ? 5 : KERN_SUCCESS;
}
