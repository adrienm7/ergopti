// tools/diagnostics/hs274-keyboard-type-observation-test.cpp
// Real CoreFoundation decoder controls; no IORegistry writes or device substitutes.
#include "hs274-keyboard-type-observation.hpp"
#include <cstdio>
#include <limits>
#include <stdexcept>
#include <string_view>

namespace {
using namespace hs274_keyboard_type_observation;
using hs274_key_policy::keyboard_type;
unsigned assertions = 0;
void require(bool valid) {
  ++assertions;
  if (!valid) throw std::runtime_error("Native property decoder assertion failed");
}
void integer(std::int64_t value, status state, keyboard_type type) {
  const auto number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &value);
  require(number != nullptr);
  const auto result = classify_property(number);
  CFRelease(number);
  require(result.state == state && result.type == type);
}

struct native_fixture_owner {
  io_service_t service = IO_OBJECT_NULL;
  IOHIDDeviceRef device = nullptr;
  bool& reference_release_refused;
  ~native_fixture_owner() {
    if (device) CFRelease(device);
    if (service && IOObjectRelease(service) != KERN_SUCCESS) {
      reference_release_refused = true;
      std::fprintf(stderr, "Native control acquired service reference release refused\n");
    }
  }
};

// The controller must supply its own unique live fixture identity. A different
// expected ID tests this SAME native service and queries no foreign device.
void actual_owned_identity(std::uint64_t registry_id) {
  bool release_refused = false;
  {
    native_fixture_owner owner{IO_OBJECT_NULL, nullptr, release_refused};
    const auto matching = IORegistryEntryIDMatching(registry_id);
    require(matching != nullptr);
    owner.service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    require(owner.service != IO_OBJECT_NULL);
    require(IOObjectConformsTo(owner.service, "IOHIDDevice"));
    owner.device = IOHIDDeviceCreate(kCFAllocatorDefault, owner.service);
    require(owner.device != nullptr);
    const auto wrong = observe(owner.device, registry_id == 1 ? 2 : 1);
    require(wrong.state == status::identity_mismatch);
    require(!wrong.property_read_attempted && wrong.type == keyboard_type::unavailable);
    const auto zero = observe(owner.device, 0);
    require(zero.state == status::identity_mismatch && !zero.property_read_attempted);
    const auto exact = observe(owner.device, registry_id);
    require(exact.property_read_attempted);
    require(exact.state == status::supported || exact.state == status::property_missing
        || exact.state == status::property_wrong_type || exact.state == status::property_noninteger
        || exact.state == status::property_conversion_refused || exact.state == status::property_unsupported);
  }
  require(!release_refused);
}
} // namespace

int main(int argc, char** argv) {
  std::uint64_t owned_registry_id = 0;
  if (argc != 1) {
    if (argc != 3 || std::string_view(argv[1]) != "--owned-registry") return 2;
    const auto parsed = hs274_observation_control::parse_registry_id(argv[2]);
    if (!parsed) return 2;
    owned_registry_id = *parsed;
  }
  try {
    integer(40, status::supported, keyboard_type::ansi);
    integer(41, status::supported, keyboard_type::iso);
    integer(42, status::supported, keyboard_type::jis);
    for (const auto value : {-1LL, 0LL, 39LL, 43LL, std::numeric_limits<long long>::max()}) {
      integer(value, status::property_unsupported, keyboard_type::unavailable);
    }
    require(classify_property(nullptr).state == status::property_missing);
    require(classify_property(kCFBooleanTrue).state == status::property_wrong_type);
    require(classify_property(kCFBooleanFalse).state == status::property_wrong_type);
    require(classify_property(CFSTR("40")).state == status::property_wrong_type);
    const auto dictionary = CFDictionaryCreate(kCFAllocatorDefault, nullptr, nullptr, 0,
                                               &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    require(dictionary != nullptr);
    const auto dictionary_result = classify_property(dictionary);
    CFRelease(dictionary);
    require(dictionary_result.state == status::property_wrong_type);
    for (const auto value : {40.0, 40.5, std::numeric_limits<double>::infinity(),
                             std::numeric_limits<double>::quiet_NaN()}) {
      const auto number = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &value);
      require(number != nullptr);
      const auto result = classify_property(number);
      CFRelease(number);
      require(result.state == status::property_noninteger && result.type == keyboard_type::unavailable);
    }
    require(observe(nullptr, 1).state == status::no_device);
    if (owned_registry_id) actual_owned_identity(owned_registry_id);
    std::printf("PASS native decoder/identity controls assertions=%u owned_service_tested=%s; availability and stream correlation unproved\n",
                assertions, owned_registry_id ? "true" : "false");
    return 0;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "FAIL %s\n", error.what());
    return 1;
  }
}
