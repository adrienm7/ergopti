// tools/diagnostics/hs274-key-element.hpp
// Qualify keyboard leaves before relying on native value transitions.
#pragma once

#include <cstdint>

namespace hs274_stream_protocol {
struct key_element {
  bool input;
  bool relative;
  std::uint32_t bits;
  std::uint32_t count;
  std::int64_t minimum;
  std::int64_t maximum;
};

inline bool binary_key(const key_element& element) noexcept {
  // Array-backed keys have individual one-bit children; selectors do not.
  return element.input && !element.relative && element.bits == 1 &&
         element.count == 1 && element.minimum == 0 && element.maximum == 1;
}
} // namespace hs274_stream_protocol
