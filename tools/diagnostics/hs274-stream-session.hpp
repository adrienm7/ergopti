// tools/diagnostics/hs274-stream-session.hpp
// Experimental dispatcher-owned storage; no IPC or device-coverage claim.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <type_traits>

namespace hs274_stream {
// All operations belong to one dispatcher. Wire identity must additionally
// include a fresh producer incarnation; leases are unique only in this object.
template <typename Value, std::size_t Capacity, typename Serial = std::uint64_t>
class session final {
  static_assert(Capacity > 0);
  static_assert(std::is_trivially_copyable_v<Value> && std::is_nothrow_copy_assignable_v<Value>);
  static_assert(std::is_unsigned_v<Serial> && !std::is_same_v<Serial, bool>);

public:
  struct token {
    std::uint64_t peer;
    Serial lease;
  };
  struct entry {
    Value value{};
    Serial sequence = 0;
  };
  template <std::size_t Limit>
  struct batch {
    std::array<entry, Limit> records{};
    std::size_t count = 0;
  };
  enum class fault { none, overflow, sequence_exhausted };
  enum class admission { inactive, accepted, lost };

  session() = default;
  session(const session&) = delete;
  session& operator=(const session&) = delete;

  token acquire(std::uint64_t peer) {
    if (!peer || owner_) throw std::logic_error("Capture owner is invalid or already acquired");
    if (lease_ == std::numeric_limits<Serial>::max()) throw std::overflow_error("Capture lease exhausted");
    ++lease_;
    owner_ = peer;
    return {owner_, lease_};
  }

  void release(token expected) {
    require_owner(expected);
    records_ = {};
    owner_ = 0;
    first_ = size_ = pending_ = 0;
    sequence_ = 0;
    fault_ = fault::none;
  }

  // Fixed storage only: no allocation, callbacks, serialization or waiting.
  admission append(const Value& value) noexcept {
    if (!owner_) return admission::inactive;
    if (fault_ != fault::none) return admission::lost;
    if (size_ == Capacity) {
      fault_ = fault::overflow;
      return admission::lost;
    }
    if (sequence_ == std::numeric_limits<Serial>::max()) {
      fault_ = fault::sequence_exhausted;
      return admission::lost;
    }
    const auto index = (first_ + size_) % Capacity;
    records_[index] = {value, ++sequence_};
    ++size_;
    return admission::accepted;
  }

  template <std::size_t Limit>
  batch<Limit> read(token expected) {
    static_assert(Limit > 0 && Limit <= Capacity);
    require_healthy(expected);
    if (pending_) throw std::logic_error("Capture batch is awaiting acknowledgement");
    batch<Limit> result;
    result.count = size_ < Limit ? size_ : Limit;
    for (std::size_t i = 0; i < result.count; ++i) {
      result.records[i] = records_[(first_ + i) % Capacity];
    }
    pending_ = result.count;
    return result;
  }

  void acknowledge(token expected, Serial last_sequence) {
    require_healthy(expected);
    if (!pending_ || records_[(first_ + pending_ - 1) % Capacity].sequence != last_sequence) {
      throw std::logic_error("Capture acknowledgement does not match its outstanding batch");
    }
    for (std::size_t i = 0; i < pending_; ++i) records_[(first_ + i) % Capacity] = {};
    first_ = (first_ + pending_) % Capacity;
    size_ -= pending_;
    pending_ = 0;
  }

  fault status(token expected) const {
    require_owner(expected);
    return fault_;
  }

private:
  void require_owner(token expected) const {
    if (!owner_ || expected.peer != owner_ || expected.lease != lease_) {
      throw std::logic_error("Capture session is not owned by this lease");
    }
  }

  void require_healthy(token expected) const {
    require_owner(expected);
    if (fault_ != fault::none) throw std::logic_error("Capture coverage was lost");
  }

  std::array<entry, Capacity> records_{};
  std::uint64_t owner_ = 0;
  Serial lease_ = 0, sequence_ = 0;
  std::size_t first_ = 0, size_ = 0, pending_ = 0;
  fault fault_ = fault::none;
};
} // namespace hs274_stream
