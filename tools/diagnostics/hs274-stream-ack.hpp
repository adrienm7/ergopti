// tools/diagnostics/hs274-stream-ack.hpp
// A downstream receipt must name exactly the published session and sequence.
#pragma once

#include "hs274-stream-protocol.hpp"

namespace hs274_stream_protocol {
inline json acknowledgement(const json& opened, const json& sequence) {
  decimal(sequence);
  return {{"version", 1u}, {"incarnation", opened.at("incarnation")},
          {"lease", opened.at("lease")}, {"ack", sequence}};
}

// Read one compact JSON line. Its exact expected size bounds memory even when
// a consumer never sends a newline; object key order does not affect admission.
template <typename Read>
void await_acknowledgement(const json& expected, Read read) {
  const auto limit = expected.dump().size();
  std::string line;
  for (;;) {
    const auto character = read();
    if (character == '\n') break;
    if (line.size() == limit) throw std::runtime_error("Capture acknowledgement exceeds frame limit");
    line.push_back(character);
  }
  const auto received = json::parse(line);
  if (received != expected || !received.at("version").is_number_unsigned()) {
    throw std::runtime_error("Capture acknowledgement changed session or sequence");
  }
}
} // namespace hs274_stream_protocol
