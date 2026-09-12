// tools/diagnostics/hs274-stream-baseline-probe.hpp
// Disposable fixture acquisition probe, never a complete-coverage declaration.
#pragma once

#include <IOKit/hid/IOHIDLib.h>
#include <mach/mach_time.h>
#include <nlohmann/json.hpp>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <string>

namespace hs274_baseline_probe {
using json = nlohmann::json;

inline json read(IOHIDDeviceRef device, IOHIDElementRef element, std::uint32_t options) {
  IOHIDValueRef value = nullptr;
  const auto before = mach_absolute_time();
  const auto status = IOHIDDeviceGetValueWithOptions(device, element, &value, options);
  const auto after = mach_absolute_time();
  json result{{"status", static_cast<std::int32_t>(status)}, {"returned_value", value != nullptr},
              {"started", std::to_string(before)}, {"finished", std::to_string(after)}};
  // A failed call may leave a cached value in the output parameter. Preserve the
  // refusal instead of interpreting that pointer as a successful empty baseline.
  if (status == kIOReturnSuccess && value) {
    result["timestamp"] = std::to_string(IOHIDValueGetTimeStamp(value));
    result["value"] = std::to_string(IOHIDValueGetIntegerValue(value));
    result["value_cookie"] = static_cast<std::uint32_t>(IOHIDElementGetCookie(IOHIDValueGetElement(value)));
  }
  return result;
}

inline void capture(IOHIDDeviceRef device, std::uint64_t identity) {
  struct elements_owner {
    CFArrayRef value;
    ~elements_owner() { if (value) CFRelease(value); }
  } elements{IOHIDDeviceCopyMatchingElements(device, nullptr, kIOHIDOptionsTypeNone)};
  json result{{"device", std::to_string(identity)}, {"coverage", "fixture_only"},
              {"enumerated", elements.value != nullptr}, {"exhausted", false}, {"elements", json::array()}};
  if (elements.value) {
    for (CFIndex i = 0; i < CFArrayGetCount(elements.value); ++i) {
      auto element = static_cast<IOHIDElementRef>(const_cast<void*>(CFArrayGetValueAtIndex(elements.value, i)));
      const auto page = IOHIDElementGetUsagePage(element);
      const auto usage = IOHIDElementGetUsage(element);
      const auto type = IOHIDElementGetType(element);
      // The independent fixture uses Escape and Space. This deliberately does
      // not pretend that two sampled usages inventory an arbitrary keyboard.
      if (page != 7 || (usage != 41 && usage != 44) ||
          type < kIOHIDElementTypeInput_Misc || type > kIOHIDElementTypeInput_ScanCodes) continue;
      if (result["elements"].size() == 2) {
        result["exhausted"] = true;
        break;
      }
      result["elements"].push_back({
          {"page", page}, {"usage", usage}, {"cookie", static_cast<std::uint32_t>(IOHIDElementGetCookie(element))},
          {"cached", read(device, element, kIOHIDDeviceGetValueWithoutUpdate)},
          {"updated", read(device, element, kIOHIDDeviceGetValueWithUpdate)}});
    }
  }
  const auto encoded = result.dump();
  if (std::fprintf(stderr, "HS274_BASELINE_PROBE %s\n", encoded.c_str()) < 0 || std::fflush(stderr) != 0) {
    throw std::runtime_error("Could not retain the native baseline probe receipt");
  }
}
} // namespace hs274_baseline_probe
