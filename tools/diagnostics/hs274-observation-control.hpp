// tools/diagnostics/hs274-observation-control.hpp
// Pure diagnostic identity/argument control; it substitutes for no native framework.
#pragma once

#include "hs274-stream-key-policy.hpp"
#include <charconv>
#include <optional>
#include <string_view>
#include <system_error>

namespace hs274_observation_control {
enum class status : std::uint8_t {
  supported, no_device, no_service, identity_unavailable, identity_mismatch,
  property_missing, property_wrong_type, property_noninteger,
  property_conversion_refused, property_unsupported, matching_unavailable,
  acquisition_unavailable, service_class_refused, device_creation_refused
};
struct observation {
  status state;
  hs274_key_policy::keyboard_type type = hs274_key_policy::keyboard_type::unavailable;
  bool property_read_attempted = false;
};
enum class reference_release : std::uint8_t { not_acquired, released, refused };

inline std::optional<std::uint64_t> parse_registry_id(std::string_view text) noexcept {
  if (text.empty() || text.size() > 20 || text.front() == '0') return std::nullopt;
  std::uint64_t result = 0;
  const auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
  if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size() || !result) return std::nullopt;
  return result;
}

// Callback order is independently testable without supplying fake native APIs.
// Read is invoked only after the exact supplied identity was observed. Its
// witness denotes the attempt, never native success or stream correlation.
template <typename AcquireService, typename QueryIdentity, typename ReadProperty>
observation observe_exact_identity(bool has_device, std::uint64_t expected,
                                   AcquireService acquire, QueryIdentity query, ReadProperty read) {
  if (!has_device) return {status::no_device};
  const auto service = acquire();
  if (!service) return {status::no_service};
  std::uint64_t actual = 0;
  if (!query(service, actual)) return {status::identity_unavailable};
  if (!expected || actual != expected) return {status::identity_mismatch};
  auto result = read(service);
  result.property_read_attempted = true;
  return result;
}

// This acknowledges only the acquired reference's native release result.
// It never proves absence of a service, process or physical capture.
inline int probe_exit(const observation& observed, reference_release release) noexcept {
  return observed.state == status::supported && observed.property_read_attempted
      && hs274_key_policy::admits_device_type(true, observed.type)
      && release == reference_release::released ? 0 : 3;
}
} // namespace hs274_observation_control
