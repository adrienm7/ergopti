// tools/diagnostics/hs274-stream-key-policy.hpp
// Portable admission predicates; no native ownership or coverage declaration.
#pragma once

#include "hs274-key-element.hpp"
#include <cstdint>

namespace hs274_key_policy {
enum class keyboard_type : std::uint8_t { unavailable, none, ansi, iso, jis };
enum class button_admission : std::uint8_t {
  admitted, not_button_page, invalid_usage, unqualified_element, invalid_value, keyboard_error
};

// These native IDs are explicit in the pinned upstream iokit_keyboard_type.
// Missing and other IDs remain unavailable; this never infers a device type.
inline keyboard_type classify_keyboard_type(std::uint64_t native_id) noexcept {
  switch (native_id) {
    case 40: return keyboard_type::ansi;
    case 41: return keyboard_type::iso;
    case 42: return keyboard_type::jis;
    default: return keyboard_type::unavailable;
  }
}

// The caller must first prove whether the inventory contains page-7 elements.
// This predicate does not prove that a supplied type came from that device.
inline bool admits_device_type(bool has_keyboard_elements, keyboard_type type) noexcept {
  if (!has_keyboard_elements) return type == keyboard_type::none;
  return type == keyboard_type::ansi || type == keyboard_type::iso || type == keyboard_type::jis;
}

inline bool is_button_page(std::uint32_t page) noexcept {
  return page == 7 || page == 12 || page == 0x00ff || page == 0xff01;
}

// A permitted page alone cannot qualify a leaf. Unsupported descriptors or
// values require an explicit caller refusal, not silent complete coverage.
inline button_admission admit_button(std::uint32_t page, std::uint32_t usage,
                                    const hs274_stream_protocol::key_element& element,
                                    std::int64_t value) noexcept {
  if (!is_button_page(page)) return button_admission::not_button_page;
  if (!usage || usage > (page == 7 ? 0xffU : 0xffffU)) return button_admission::invalid_usage;
  if (!hs274_stream_protocol::binary_key(element)) return button_admission::unqualified_element;
  if (value != 0 && value != 1) return button_admission::invalid_value;
  if (page == 7 && usage <= 3 && value == 1) return button_admission::keyboard_error;
  return button_admission::admitted;
}
} // namespace hs274_key_policy
