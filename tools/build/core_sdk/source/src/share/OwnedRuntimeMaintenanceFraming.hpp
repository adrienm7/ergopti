// Native fixed framing. Parsed values never create a maintenance capability.
#pragma once
#include "OwnedRuntimeMaintenanceWire.h"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>

namespace ergoptiplus::installed_maintenance {
class wire_frame final {
public:
  using bytes_type = std::array<std::uint8_t, ERGOPTI_OWNED_MAINTENANCE_WIRE_SIZE>;
  using nonce_type = std::array<std::uint8_t, 16>;
  using incarnation_type = std::array<std::uint8_t, 16>;

  static std::optional<wire_frame> decode(const bytes_type& bytes) noexcept {
    const bool original = std::memcmp(bytes.data(), "EGRMNT01", 8) == 0 &&
        bytes[8] >= ERGOPTI_MAINTENANCE_ISSUER_REGISTER &&
        bytes[8] <= ERGOPTI_MAINTENANCE_ACQUIRE_CONFIRMED_UPDATE &&
        bytes[9] <= ERGOPTI_MAINTENANCE_WIRE_CLOSE_REFUSED;
    const bool intent_query = std::memcmp(bytes.data(), "EGRMNT02", 8) == 0 &&
        bytes[8] == ERGOPTI_MAINTENANCE_OBSERVE_RETIREMENT_INTENT &&
        bytes[9] <= ERGOPTI_MAINTENANCE_WIRE_OBSERVED;
    if ((!original && !intent_query) ||
        !std::all_of(bytes.begin() + 10, bytes.begin() + 16, [](auto byte) { return byte == 0; })) return std::nullopt;
    wire_frame result;
    result.bytes_ = bytes;
    if (intent_query && !result.complete_correlation()) return std::nullopt;
    return result;
  }
  static wire_frame request(ergopti_owned_maintenance_wire_operation operation) noexcept {
    wire_frame result;
    std::memcpy(result.bytes_.data(),
                operation == ERGOPTI_MAINTENANCE_OBSERVE_RETIREMENT_INTENT ? "EGRMNT02" : "EGRMNT01", 8);
    result.bytes_[8] = static_cast<std::uint8_t>(operation);
    return result;
  }
  std::uint8_t operation() const noexcept { return bytes_[8]; }
  std::uint8_t status() const noexcept { return bytes_[9]; }
  std::uint64_t cohort() const noexcept { return integer_at(16); }
  std::uint64_t preparation() const noexcept { return integer_at(40); }
  incarnation_type incarnation() const noexcept {
    incarnation_type result{};
    std::copy_n(bytes_.begin() + 24, result.size(), result.begin());
    return result;
  }
  nonce_type nonce() const noexcept {
    nonce_type result{};
    std::copy_n(bytes_.begin() + 48, result.size(), result.begin());
    return result;
  }
  const bytes_type& bytes() const noexcept { return bytes_; }
  bool empty_correlation() const noexcept {
    return std::all_of(bytes_.begin() + 16, bytes_.end(), [](auto byte) { return byte == 0; });
  }
  bool complete_correlation() const noexcept {
    return cohort() != 0 && preparation() != 0 &&
        std::any_of(bytes_.begin() + 24, bytes_.begin() + 40, [](auto byte) { return byte != 0; }) &&
        std::any_of(bytes_.begin() + 48, bytes_.end(), [](auto byte) { return byte != 0; });
  }
  bool same_correlation(const wire_frame& other) const noexcept {
    return std::equal(bytes_.begin() + 16, bytes_.end(), other.bytes_.begin() + 16);
  }
  wire_frame correlated_request(ergopti_owned_maintenance_wire_operation operation) const noexcept {
    auto result = request(operation);
    std::copy(bytes_.begin() + 16, bytes_.end(), result.bytes_.begin() + 16);
    return result;
  }
  wire_frame reply(ergopti_owned_maintenance_wire_status status) const noexcept {
    auto result = *this;
    result.bytes_[9] = static_cast<std::uint8_t>(status);
    return result;
  }
  wire_frame with_correlation(std::uint64_t cohort, const incarnation_type& incarnation,
                              std::uint64_t preparation, const nonce_type& nonce) const noexcept {
    auto result = *this;
    result.put_integer(16, cohort);
    std::copy(incarnation.begin(), incarnation.end(), result.bytes_.begin() + 24);
    result.put_integer(40, preparation);
    std::copy(nonce.begin(), nonce.end(), result.bytes_.begin() + 48);
    return result;
  }

private:
  bytes_type bytes_{};
  wire_frame() = default;
  std::uint64_t integer_at(std::size_t offset) const noexcept {
    std::uint64_t result = 0;
    for (std::size_t index = 0; index != 8; ++index) result = (result << 8) | bytes_[offset + index];
    return result;
  }
  void put_integer(std::size_t offset, std::uint64_t value) noexcept {
    for (std::size_t index = 8; index != 0; --index) {
      bytes_[offset + index - 1] = static_cast<std::uint8_t>(value & 0xff);
      value >>= 8;
    }
  }
};
} // namespace ergoptiplus::installed_maintenance
