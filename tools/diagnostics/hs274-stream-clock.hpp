// tools/diagnostics/hs274-stream-clock.hpp
// Describe the native HID timestamp domain without changing the capture protocol.
#pragma once

#include <mach/mach_time.h>
#include <nlohmann/json.hpp>
#include <stdexcept>

namespace hs274_clock {
inline nlohmann::json information() {
  mach_timebase_info_data_t scale{};
  if (mach_timebase_info(&scale) != KERN_SUCCESS || !scale.numer || !scale.denom) {
    throw std::runtime_error("Cannot acquire physical timestamp timebase");
  }
  return {{"version", 1u}, {"domain", "mach_absolute_time"},
          {"numer", scale.numer}, {"denom", scale.denom}};
}
} // namespace hs274_clock
