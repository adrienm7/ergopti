// tools/diagnostics/hs274-hid-metadata.hpp
// Test ordinary metadata writes on the uniquely owned CI keyboard only.
#pragma once

#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <vector>

namespace hs274_metadata {
constexpr int vendor_id = 0x16c0;
constexpr int product_id = 0x0274;

inline bool find_devices(std::vector<io_service_t>& devices) {
  auto matching = IOServiceMatching("IOHIDDevice");
  if (!matching) return false;
  auto properties = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
  auto vendor = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vendor_id);
  auto product = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &product_id);
  if (!properties || !vendor || !product) {
    if (properties) CFRelease(properties);
    if (vendor) CFRelease(vendor);
    if (product) CFRelease(product);
    CFRelease(matching);
    return false;
  }
  CFDictionarySetValue(properties, CFSTR(kIOHIDVendorIDKey), vendor);
  CFDictionarySetValue(properties, CFSTR(kIOHIDProductIDKey), product);
  CFDictionarySetValue(matching, CFSTR(kIOPropertyMatchKey), properties);
  CFRelease(properties);
  CFRelease(vendor);
  CFRelease(product);
  io_iterator_t iterator = IO_OBJECT_NULL;
  if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) return false;
  while (auto device = IOIteratorNext(iterator)) devices.push_back(device);
  IOObjectRelease(iterator);
  return true;
}

inline int device_count() {
  std::vector<io_service_t> devices;
  const bool found = find_devices(devices);
  for (auto device : devices) IOObjectRelease(device);
  return found ? static_cast<int>(devices.size()) : -1;
}

struct Result {
  bool owner_verified = false;
  uint64_t registry_entry_id = 0;
  kern_return_t write_status = kIOReturnNotReady;
  bool readback_matches = false;
  kern_return_t restore_status = kIOReturnNotReady;
  bool restored = false;
};

inline Result observe() {
  Result result;
  std::vector<io_service_t> devices;
  if (!find_devices(devices) || devices.size() != 1) {
    for (auto device : devices) IOObjectRelease(device);
    return result;
  }
  auto device = devices.front();
  auto manufacturer = IORegistryEntryCreateCFProperty(device, CFSTR(kIOHIDManufacturerKey), kCFAllocatorDefault, 0);
  auto original = IORegistryEntryCreateCFProperty(device, CFSTR(kIOHIDProductKey), kCFAllocatorDefault, 0);
  result.owner_verified = manufacturer && CFEqual(manufacturer, CFSTR("pqrs.org")) &&
      original && CFGetTypeID(original) == CFStringGetTypeID() &&
      CFStringHasPrefix(static_cast<CFStringRef>(original), CFSTR("Karabiner DriverKit VirtualHIDKeyboard")) &&
      IORegistryEntryGetRegistryEntryID(device, &result.registry_entry_id) == KERN_SUCCESS;
  if (result.owner_verified) {
    result.write_status = IORegistryEntrySetCFProperty(device, CFSTR(kIOHIDProductKey), CFSTR("HS274 CI Keyboard"));
    auto changed = IORegistryEntryCreateCFProperty(device, CFSTR(kIOHIDProductKey), kCFAllocatorDefault, 0);
    result.readback_matches = changed && CFEqual(changed, CFSTR("HS274 CI Keyboard"));
    if (changed) CFRelease(changed);
    // A success return can hide an ignored property; restore and read back even
    // after a rejected write rather than assuming that no mutation occurred.
    result.restore_status = IORegistryEntrySetCFProperty(device, CFSTR(kIOHIDProductKey), original);
    auto restored = IORegistryEntryCreateCFProperty(device, CFSTR(kIOHIDProductKey), kCFAllocatorDefault, 0);
    result.restored = restored && CFEqual(restored, original);
    if (restored) CFRelease(restored);
  }
  if (original) CFRelease(original);
  if (manufacturer) CFRelease(manufacturer);
  IOObjectRelease(device);
  return result;
}
} // namespace hs274_metadata
