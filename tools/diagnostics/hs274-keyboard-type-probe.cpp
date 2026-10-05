// tools/diagnostics/hs274-keyboard-type-probe.cpp
// Read only the caller's exact native HID service; never publish capture readiness.
#include "hs274-keyboard-type-observation.hpp"
#include <cstdio>

namespace {
const char* name(hs274_keyboard_type_observation::status state) noexcept {
  using hs274_keyboard_type_observation::status;
  switch (state) {
    case status::supported: return "supported";
    case status::no_device: return "no-device";
    case status::no_service: return "no-service";
    case status::identity_unavailable: return "identity-unavailable";
    case status::identity_mismatch: return "identity-mismatch";
    case status::property_missing: return "property-missing";
    case status::property_wrong_type: return "property-wrong-type";
    case status::property_noninteger: return "property-noninteger";
    case status::property_conversion_refused: return "property-conversion-refused";
    case status::property_unsupported: return "property-unsupported";
    case status::matching_unavailable: return "matching-unavailable";
    case status::acquisition_unavailable: return "acquisition-unavailable";
    case status::service_class_refused: return "service-class-refused";
    case status::device_creation_refused: return "device-creation-refused";
  }
  return "observation-refused";
}
const char* name(hs274_key_policy::keyboard_type type) noexcept {
  using hs274_key_policy::keyboard_type;
  switch (type) {
    case keyboard_type::ansi: return "ansi";
    case keyboard_type::iso: return "iso";
    case keyboard_type::jis: return "jis";
    case keyboard_type::none: return "none";
    case keyboard_type::unavailable: return "unavailable";
  }
  return "unavailable";
}
const char* name(hs274_observation_control::reference_release release) noexcept {
  using hs274_observation_control::reference_release;
  switch (release) {
    case reference_release::not_acquired: return "not-acquired";
    case reference_release::released: return "released";
    case reference_release::refused: return "refused";
  }
  return "refused";
}
} // namespace

int main(int argc, char** argv) {
  if (argc != 2) return 2;
  const auto expected = hs274_observation_control::parse_registry_id(argv[1]);
  if (!expected) return 2;
  using hs274_keyboard_type_observation::status;
  auto observed = hs274_keyboard_type_observation::observation{status::matching_unavailable};
  const auto matching = IORegistryEntryIDMatching(*expected);
  // GetMatchingService consumes the matching dictionary, including on refusal.
  const bool matching_created = matching != nullptr;
  const auto service = matching_created ? IOServiceGetMatchingService(kIOMainPortDefault, matching) : IO_OBJECT_NULL;
  IOHIDDeviceRef device = nullptr;
  if (matching_created) {
    if (!service) observed.state = status::acquisition_unavailable;
    else if (!IOObjectConformsTo(service, "IOHIDDevice")) observed.state = status::service_class_refused;
    else {
      device = IOHIDDeviceCreate(kCFAllocatorDefault, service);
      observed = device ? hs274_keyboard_type_observation::observe(device, *expected)
                        : hs274_keyboard_type_observation::observation{status::device_creation_refused};
    }
  }
  const bool device_reference_release_issued = device != nullptr;
  if (device) CFRelease(device);
  // This is ONLY the reference acquired by GetMatchingService. The borrowed
  // IOHIDDeviceGetService reference remains untouched inside observe().
  const auto release = !service ? hs274_observation_control::reference_release::not_acquired
      : IOObjectRelease(service) == KERN_SUCCESS ? hs274_observation_control::reference_release::released
                                                : hs274_observation_control::reference_release::refused;
  // No registry ID, names, serials, raw property payloads, paths or argv.
  const auto written = std::printf("{\"schema\":1,\"role\":\"diagnostic_only\",\"observation\":\"%s\","
      "\"observed_keyboard_type\":\"%s\",\"property_read_attempted\":%s,"
      "\"service_reference_release\":\"%s\",\"device_reference_release\":\"%s\","
      "\"capture_admitted\":false,\"stream_correlation_proved\":false,\"coverage_proved\":false}\n",
      name(observed.state), name(observed.type), observed.property_read_attempted ? "true" : "false",
      name(release), device_reference_release_issued ? "issued" : "not-acquired");
  if (written < 0 || std::fflush(stdout) != 0) return 3;
  return hs274_observation_control::probe_exit(observed, release);
}
