// tools/diagnostics/hs274-stream-key-policy-test.cpp
// Independently authored button and keyboard-type admission boundaries.
#include "hs274-stream-key-policy.hpp"
#include <cstdint>
#include <iostream>
#include <limits>
#include <stdexcept>

namespace {
using namespace hs274_key_policy;
std::uint32_t assertions = 0;
void require(bool condition, const char* message) {
  ++assertions;
  if (!condition) throw std::runtime_error(message);
}
hs274_stream_protocol::key_element scalar() { return {true, false, false, 1, 1, 0, 1}; }
void types() {
  require(classify_keyboard_type(40) == keyboard_type::ansi, "Native ID40 is ANSI");
  require(classify_keyboard_type(41) == keyboard_type::iso, "Native ID41 is ISO");
  require(classify_keyboard_type(42) == keyboard_type::jis, "Native ID42 is JIS");
  for (const auto value : {0ULL, 1ULL, 39ULL, 43ULL, 255ULL,
                          static_cast<unsigned long long>(std::numeric_limits<std::uint64_t>::max())}) {
    require(classify_keyboard_type(value) == keyboard_type::unavailable,
            "Unknown native ID must never become ANSI");
  }
  for (const auto type : {keyboard_type::ansi, keyboard_type::iso, keyboard_type::jis}) {
    require(admits_device_type(true, type), "Observed keyboard type is permitted");
    require(!admits_device_type(false, type), "Nonkeyboard interface must declare none");
  }
  require(admits_device_type(false, keyboard_type::none), "No keyboard-page elements permits none");
  require(!admits_device_type(true, keyboard_type::none), "Missing keyboard type cannot admit a keyboard");
  require(!admits_device_type(true, keyboard_type::unavailable), "Unavailable type refuses keyboard");
  require(!admits_device_type(false, keyboard_type::unavailable), "Unavailable is not a none declaration");
  require(!admits_device_type(true, static_cast<keyboard_type>(127)), "Malformed enum refuses keyboard");
  require(!admits_device_type(false, static_cast<keyboard_type>(127)), "Malformed enum refuses interface");
}
void buttons() {
  const auto key = scalar();
  for (const auto page : {7U, 12U, 255U, 65281U}) {
    require(is_button_page(page), "Every explicitly supported button page is included");
    require(admit_button(page, 44, key, 0) == button_admission::admitted, "Released button is admitted");
    require(admit_button(page, 44, key, 1) == button_admission::admitted, "Pressed button is admitted");
    require(admit_button(page, 0, key, 0) == button_admission::invalid_usage, "Zero usage is not a key");
    require(admit_button(page, std::numeric_limits<std::uint32_t>::max(), key, 0)
                == button_admission::invalid_usage, "Array carrier is not silently credited");
    require(admit_button(page, 44, key, -1) == button_admission::invalid_value, "Negative key value refuses");
    require(admit_button(page, 44, key, 2) == button_admission::invalid_value, "Nonbinary key value refuses");
  }
  for (const auto page : {0U, 1U, 9U, 11U, 13U, 256U, 65280U, 65535U, 65536U}) {
    require(!is_button_page(page), "Foreign page is outside button coverage");
    require(admit_button(page, 44, key, 1) == button_admission::not_button_page,
            "Foreign page cannot manufacture a physical button");
  }
  require(admit_button(7, 255, key, 1) == button_admission::admitted, "Keyboard maximum usage is255");
  require(admit_button(7, 256, key, 1) == button_admission::invalid_usage, "Keyboard usage256 refuses");
  for (const auto page : {12U, 255U, 65281U}) {
    require(admit_button(page, 3, key, 1) == button_admission::admitted,
            "Vendor fn usage3 and consumer usage3 are not keyboard error indicators");
    require(admit_button(page, 65535, key, 1) == button_admission::admitted, "Nonkeyboard usage is16bit");
    require(admit_button(page, 65536, key, 1) == button_admission::invalid_usage, "Nonkeyboard usage overflow refuses");
  }
  for (const auto usage : {1U, 2U, 3U}) {
    require(admit_button(7, usage, key, 0) == button_admission::admitted, "Inactive keyboard error indicator retained");
    require(admit_button(7, usage, key, 1) == button_admission::keyboard_error, "Active keyboard error refuses");
  }
  for (int variation = 0; variation != 7; ++variation) {
    auto changed = key;
    switch (variation) {
      case 0: changed.input = false; break;
      case 1: changed.relative = true; break;
      case 2: changed.bits = 2; break;
      case 3: changed.count = 2; break;
      case 4: changed.minimum = -1; break;
      case 5: changed.maximum = 2; break;
      default: changed.array = true; changed.count = 0; break;
    }
    require(admit_button(12, 233, changed, 1) == button_admission::unqualified_element,
            "Unsupported descriptor must refuse rather than disappear from declared coverage");
  }
  auto array = key;
  array.array = true; array.count = 32;
  require(admit_button(255, 3, array, 1) == button_admission::admitted,
          "One-bit array leaf retains the original report count");
}
} // namespace

int main() {
  try {
    types(); buttons();
    std::cout << "PASS independent key policy assertions=" << assertions << '\n';
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL " << error.what() << '\n';
    return 1;
  }
}
