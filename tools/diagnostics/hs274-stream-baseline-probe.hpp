// tools/diagnostics/hs274-stream-baseline-probe.hpp
// Disposable fixture acquisition probe, never a complete-coverage declaration.
#pragma once

#include "hs274-stream-inventory.hpp"
#include <IOKit/hid/IOHIDLib.h>
#include <mach/mach_time.h>
#include <nlohmann/json.hpp>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <string>

namespace hs274_baseline_probe {
using json = nlohmann::json;

struct elements_owner {
  CFArrayRef value;
  ~elements_owner() { if (value) CFRelease(value); }
};

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

inline void capture_inventory(IOHIDDeviceRef device, std::uint64_t identity) {
  // Preserve every element cookie, including separate scalar/array modifiers.
  // Duplicate cookies and exhaustion revoke readability, never truncate it.
  hs274_stream_protocol::key_inventory<hs274_stream_protocol::keyboard_inventory_capacity> inventory;
  elements_owner elements{IOHIDDeviceCopyMatchingElements(device, nullptr, kIOHIDOptionsTypeNone)};
  json result{{"version", 2u}, {"device", std::to_string(identity)}, {"coverage", "fixture_only"},
              {"capacity", hs274_stream_protocol::keyboard_inventory_capacity},
              {"enumerated", elements.value != nullptr}, {"exhausted", false}, {"elements", json::array()}};
  if (elements.value) {
    for (CFIndex i = 0; i < CFArrayGetCount(elements.value); ++i) {
      auto element = static_cast<IOHIDElementRef>(const_cast<void*>(CFArrayGetValueAtIndex(elements.value, i)));
      const auto page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element);
      const auto type = IOHIDElementGetType(element);
      if (page != 7 || usage == 0 || usage == UINT32_MAX ||
          type < kIOHIDElementTypeInput_Misc || type > kIOHIDElementTypeInput_ScanCodes) continue;
      if (inventory.full()) { result["exhausted"] = true; break; }
      const auto cookie = static_cast<std::uint32_t>(IOHIDElementGetCookie(element));
      const hs274_stream_protocol::key_element descriptor{
          true, static_cast<bool>(IOHIDElementIsRelative(element)), static_cast<bool>(IOHIDElementIsArray(element)),
          IOHIDElementGetReportSize(element), IOHIDElementGetReportCount(element),
          IOHIDElementGetLogicalMin(element), IOHIDElementGetLogicalMax(element)};
      const auto sample = read(device, element, kIOHIDDeviceGetValueWithoutUpdate);
      const bool valid = sample.at("status") == 0 && sample.at("returned_value") == true;
      inventory.append({usage, cookie, descriptor, sample.at("status").get<std::int32_t>(),
          sample.at("returned_value").get<bool>(), valid ? sample.at("value_cookie").get<std::uint32_t>() : 0,
          valid ? std::stoll(sample.at("value").get<std::string>()) : 0,
          valid ? std::stoull(sample.at("timestamp").get<std::string>()) : 0,
          std::stoull(sample.at("started").get<std::string>()), std::stoull(sample.at("finished").get<std::string>())});
      result["elements"].push_back({{"usage", usage}, {"cookie", cookie}, {"sample", sample},
          {"relative", descriptor.relative}, {"array", descriptor.array}, {"bits", descriptor.bits},
          {"count", descriptor.count}, {"minimum", descriptor.minimum}, {"maximum", descriptor.maximum}});
    }
  }
  result["readable"] = inventory.finish(result.at("enumerated").get<bool>(), result.at("exhausted").get<bool>());
  const auto encoded = result.dump();
  if (std::fprintf(stderr, "HS274_KEY_INVENTORY %s\n", encoded.c_str()) < 0 || std::fflush(stderr) != 0) {
    throw std::runtime_error("Could not retain the native keyboard inventory receipt");
  }
}

inline void capture(IOHIDDeviceRef device, std::uint64_t identity) {
  elements_owner elements{IOHIDDeviceCopyMatchingElements(device, nullptr, kIOHIDOptionsTypeNone)};
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
