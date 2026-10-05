// tools/diagnostics/hs274-keyboard-type-observation.hpp
// Diagnostic native-property observation, never physical-stream admission.
#pragma once

#include "hs274-observation-control.hpp"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDLib.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hidsystem/IOHIDParameter.h>
#include <cstdint>

namespace hs274_keyboard_type_observation {
using status = hs274_observation_control::status;
using observation = hs274_observation_control::observation;

// Decode only the borrowed object's real CoreFoundation type. Integral-looking
// strings, booleans and floating-point values are never native integer proof.
inline observation classify_property(CFTypeRef property) noexcept {
  if (!property) return {status::property_missing};
  observation result{status::property_wrong_type};
  if (CFGetTypeID(property) == CFNumberGetTypeID()) {
    const auto number = static_cast<CFNumberRef>(property);
    if (CFNumberIsFloatType(number)) {
      result.state = status::property_noninteger;
    } else {
      std::int64_t native_id = 0;
      if (!CFNumberGetValue(number, kCFNumberSInt64Type, &native_id)) {
        result.state = status::property_conversion_refused;
      } else if (native_id < 0) {
        result.state = status::property_unsupported;
      } else {
        result.type = hs274_key_policy::classify_keyboard_type(static_cast<std::uint64_t>(native_id));
        result.state = result.type == hs274_key_policy::keyboard_type::unavailable
            ? status::property_unsupported : status::supported;
      }
    }
  }
  return result;
}

// The borrowed service and requested registry identity refer to this exact
// native object. They do not establish its correspondence to a stream device.
// No parent traversal, product-name inference, property write or global lookup.
inline observation observe(IOHIDDeviceRef device, std::uint64_t expected_registry_id) noexcept {
  return hs274_observation_control::observe_exact_identity(device != nullptr, expected_registry_id,
      [device] { return IOHIDDeviceGetService(device); },
      [](io_service_t service, std::uint64_t& identity) {
        return IORegistryEntryGetRegistryEntryID(service, &identity) == KERN_SUCCESS;
      },
      [](io_service_t service) {
        const auto property = IORegistryEntryCreateCFProperty(service, CFSTR(kIOHIDSubinterfaceIDKey),
                                                             kCFAllocatorDefault, 0);
        const auto result = classify_property(property);
        if (property) CFRelease(property);
        return result;
      });
}
} // namespace hs274_keyboard_type_observation
