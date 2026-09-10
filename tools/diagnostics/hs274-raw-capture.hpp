// tools/diagnostics/hs274-raw-capture.hpp
// Finite fixture observation; not a production physical-event stream.
#pragma once

#include <array>
#include <atomic>
#include <cinttypes>
#include <cstddef>
#include <cstdint>
#include <cstdio>

namespace hs274_raw_capture {
struct record {
  std::uint64_t device;
  std::uint64_t timestamp;
  std::int64_t value;
  bool has_page;
  bool has_usage;
  std::int32_t page;
  std::int32_t usage;
  std::uint64_t sequence = 0;
};

template <std::size_t Capacity>
class capture {
  static_assert(Capacity > 0);
  static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
  static_assert(std::atomic<std::size_t>::is_always_lock_free);
public:
  struct snapshot {
    std::array<record, Capacity> records{};
    std::size_t count = 0;
    std::uint64_t seen = 0;
    std::uint64_t overflow = 0;
    std::uint64_t contention = 0;
  };

  // No allocation, I/O, waiting, or overwriting a published record on input.
  void append(record value) noexcept {
    seen_.fetch_add(1, std::memory_order_relaxed);
    if (writer_.test_and_set(std::memory_order_acquire)) {
      contention_.fetch_add(1, std::memory_order_relaxed);
      return;
    }
    const auto index = committed_.load(std::memory_order_relaxed);
    if (index < Capacity) {
      value.sequence = index + 1;
      records_[index] = value;
      committed_.store(index + 1, std::memory_order_release);
    } else {
      overflow_.fetch_add(1, std::memory_order_relaxed);
    }
    writer_.clear(std::memory_order_release);
  }

  // Only the immutable committed prefix is copied, even during a late callback.
  snapshot read() const noexcept {
    snapshot result;
    result.count = committed_.load(std::memory_order_acquire);
    for (std::size_t i = 0; i < result.count; ++i) result.records[i] = records_[i];
    result.seen = seen_.load(std::memory_order_relaxed);
    result.overflow = overflow_.load(std::memory_order_relaxed);
    result.contention = contention_.load(std::memory_order_relaxed);
    return result;
  }

private:
  std::array<record, Capacity> records_{};
  std::atomic_flag writer_ = ATOMIC_FLAG_INIT;
  std::atomic<std::size_t> committed_{0};
  std::atomic<std::uint64_t> seen_{0}, overflow_{0}, contention_{0};
};

// Bound only this short fixture observation. Any exhaustion invalidates coverage.
inline capture<4096> fixture;

inline bool finish() {
  const auto state = fixture.read();
  std::printf("HS274_RAW_CAPTURE {\"coverage\":\"fixture_only\",\"seen\":%" PRIu64
              ",\"overflow\":%" PRIu64 ",\"contention\":%" PRIu64 ",\"records\":[",
              state.seen, state.overflow, state.contention);
  for (std::size_t i = 0; i < state.count; ++i) {
    const auto& r = state.records[i];
    std::printf("%s{\"device\":%" PRIu64 ",\"timestamp\":%" PRIu64 ",\"value\":%" PRId64
                ",\"has_page\":%s,\"has_usage\":%s,\"page\":%" PRId32
                ",\"usage\":%" PRId32 ",\"sequence\":%" PRIu64 "}",
                i ? "," : "", r.device, r.timestamp, r.value,
                r.has_page ? "true" : "false", r.has_usage ? "true" : "false",
                r.page, r.usage, r.sequence);
  }
  std::printf("]}\n");
  return std::fflush(stdout) == 0 && !std::ferror(stdout);
}
} // namespace hs274_raw_capture
