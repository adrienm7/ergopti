// tools/diagnostics/hs274-stream-input.hpp
// Keep the finite reference separate from the general observed input stream.
#pragma once

#include "hs274-raw-capture.hpp"

namespace hs274_stream_protocol {
template <typename Monitor, std::size_t Capacity>
void append_input(Monitor& monitor, hs274_raw_capture::capture<Capacity>& reference,
                  bool is_reference, const hs274_raw_capture::record& input) noexcept {
  if (is_reference) reference.append(input);
  monitor.append(input);
}
} // namespace hs274_stream_protocol
