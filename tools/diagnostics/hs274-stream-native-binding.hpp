// tools/diagnostics/hs274-stream-native-binding.hpp
// Immutable observations from this original IOHID device, scoped to fixture capture.
#pragma once
#include "hs274-stream-native-control.hpp"
#include "hs274-keyboard-type-observation.hpp"
#include <IOKit/hid/IOHIDLib.h>
namespace hs274_stream_protocol {
class native_binding final {
public:
  native_binding(IOHIDDeviceRef device, std::uint64_t expected) :
      native_device_(device), device_(expected), observed_(inspect(device, expected)) {}
  std::uint64_t device() const noexcept { return device_; }
  bool keyboard() const noexcept { return observed_.keyboard; }
  hs274_key_policy::keyboard_type type() const noexcept { return observed_.type; }
  native_refusal refusal() const noexcept { return observed_.reason; }
  bool unchanged(IOHIDDeviceRef device, bool inventory_keyboard) const {
    if (!device || device != native_device_ || refusal() != native_refusal::none ||
        inventory_keyboard != keyboard()) return false;
    const auto current = inspect(device, device_);
    return current.reason == native_refusal::none && current.keyboard == keyboard() && current.type == type();
  }
private:
  struct result {
    bool keyboard = false;
    hs274_key_policy::keyboard_type type = hs274_key_policy::keyboard_type::unavailable;
    native_refusal reason = native_refusal::inventory_unavailable;
  };
  static result inspect(IOHIDDeviceRef device, std::uint64_t expected) {
    result result;
    if (!device) return result;
    // Query the exact borrowed native object before any property observation.
    const auto service = IOHIDDeviceGetService(device);
    std::uint64_t actual = 0;
    if (!service || IORegistryEntryGetRegistryEntryID(service, &actual) != KERN_SUCCESS) {
      result.reason = native_refusal::identity_unavailable;
      return result;
    }
    if (!expected || actual != expected) {
      result.reason = native_refusal::identity_mismatch;
      return result;
    }
    const auto elements = IOHIDDeviceCopyMatchingElements(device, nullptr, kIOHIDOptionsTypeNone);
    if (!elements) return result;
    for (CFIndex index = 0; index < CFArrayGetCount(elements); ++index) {
      const auto element = static_cast<IOHIDElementRef>(const_cast<void*>(CFArrayGetValueAtIndex(elements, index)));
      const auto type = IOHIDElementGetType(element);
      const auto usage = IOHIDElementGetUsage(element);
      if (IOHIDElementGetUsagePage(element) == 7 && usage && usage != UINT32_MAX &&
          type >= kIOHIDElementTypeInput_Misc && type <= kIOHIDElementTypeInput_ScanCodes) result.keyboard = true;
    }
    CFRelease(elements);
    if (!result.keyboard) {
      result.type = hs274_key_policy::keyboard_type::none;
      result.reason = native_refusal::none;
      return result;
    }
    const auto observed = hs274_keyboard_type_observation::observe(device, expected);
    if (observed.state != hs274_keyboard_type_observation::status::supported || !observed.property_read_attempted) {
      result.reason = native_refusal::keyboard_type_unavailable;
      return result;
    }
    result.type = observed.type;
    result.reason = native_refusal::none;
    return result;
  }
  // Borrowed under the original native monitor owner; never release its reference.
  const IOHIDDeviceRef native_device_;
  const std::uint64_t device_;
  const result observed_;
};
} // namespace hs274_stream_protocol
