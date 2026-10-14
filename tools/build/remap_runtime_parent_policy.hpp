#pragma once

// Portable value rules only. Native process/role acquisition is a separate seam.
#include <cstdint>
#include <optional>

namespace ergoptiplus::remap::parent_policy {

enum class console_role { unknown, owned_console };

struct process_frame final {
  bool complete;
  std::int32_t pid;
  std::int32_t ppid;
  std::uint32_t state;
  std::uint64_t start_seconds;
  std::uint64_t start_microseconds;
};

struct observation final {
  console_role role;
  process_frame self;
  process_frame parent;
};

struct identity final {
  std::int32_t self_pid;
  std::int32_t parent_pid;
  std::uint64_t self_start_seconds;
  std::uint64_t self_start_microseconds;
  std::uint64_t parent_start_seconds;
  std::uint64_t parent_start_microseconds;
};

[[nodiscard]] inline bool live_frame(const process_frame& value) noexcept {
  // Pinned Darwin proc.h: SRUN=2, SSLEEP=3, SSTOP=4. Creation/zombie/unknown refuse.
  return value.complete && value.pid > 1 &&
         (value.state == 2 || value.state == 3 || value.state == 4) &&
         value.start_seconds > 0 && value.start_microseconds < 1000000;
}

[[nodiscard]] inline std::optional<identity> qualify(const observation& value) noexcept {
  if (value.role != console_role::owned_console ||
      !live_frame(value.self) || !live_frame(value.parent) ||
      value.self.pid == value.parent.pid || value.self.ppid != value.parent.pid) {
    return std::nullopt;
  }
  return identity{value.self.pid,
                  value.parent.pid,
                  value.self.start_seconds,
                  value.self.start_microseconds,
                  value.parent.start_seconds,
                  value.parent.start_microseconds};
}

[[nodiscard]] inline bool current(const identity& sealed, const observation& value) noexcept {
  const auto actual = qualify(value);
  return actual && actual->self_pid == sealed.self_pid &&
         actual->parent_pid == sealed.parent_pid &&
         actual->self_start_seconds == sealed.self_start_seconds &&
         actual->self_start_microseconds == sealed.self_start_microseconds &&
         actual->parent_start_seconds == sealed.parent_start_seconds &&
         actual->parent_start_microseconds == sealed.parent_start_microseconds;
}

} // namespace ergoptiplus::remap::parent_policy
