// tools/diagnostics/hs274-key-element.hpp
// Qualify keyboard leaves before relying on native value transitions.
#pragma once

#include <cstdint>

namespace hs274_stream_protocol {
struct key_element {
  bool input;
  bool relative;
  bool array;
  std::uint32_t bits;
  std::uint32_t count;
  std::int64_t minimum;
  std::int64_t maximum;
};

inline bool binary_key(const key_element& element) noexcept {
  // The public count getter preserves the original array report count, even
  // for individual one-bit children. Scalar values still require one item.
  return element.input && !element.relative && element.bits == 1 &&
         (element.array ? element.count > 0 : element.count == 1) &&
         element.minimum == 0 && element.maximum == 1;
}
} // namespace hs274_stream_protocol
