// tools/diagnostics/hs274-priority-initial-policy.hpp
// One-shot initial capability qualification; never capture or display authority.
#pragma once
#include <cstdint>

namespace hs274_priority_initial {
enum class capability_class { refused, cpu_inactive, cpu_without_graphics, graphics_capable };

struct packet {
  std::uint32_t notify_ref = 0;
  std::uint32_t max_wait = 0;
  std::uint32_t flags = 0;
  std::uint32_t reserved = 0;
  std::uint32_t from = 0;
  std::uint32_t to = 0;
  std::uint32_t reserved_tail[4]{};
};

class observation final {
public:
  observation() = default;
  observation(const observation&) = delete;
  observation& operator=(const observation&) = delete;

  void subscribe() noexcept {
    if (phase_ != phase::created || failed_) { refuse(); return; }
    phase_ = phase::subscribed;
  }

  void receive(const packet& value, bool original_provider_current) noexcept {
    if (phase_ != phase::subscribed || initial_ || failed_ || !original_provider_current ||
        value.max_wait || value.flags || value.from || value.reserved || (value.to & ~15u)) {
      refuse(); return;
    }
    for (const auto reserved : value.reserved_tail) {
      if (reserved) { refuse(); return; }
    }
    const bool cpu = (value.to & 1u) != 0;
    const bool graphics = (value.to & 2u) != 0;
    if (!cpu && value.to) { refuse(); return; }
    value_ = !cpu ? capability_class::cpu_inactive :
        (graphics ? capability_class::graphics_capable : capability_class::cpu_without_graphics);
    initial_ = true;
  }

  // A legacy or transition notification is a gap for this initial-only sample.
  // No copied legacy payload is inspected and no power acknowledgement is sent.
  void observe_legacy() noexcept { refuse(); }
  void refuse() noexcept { failed_ = true; }
  bool failed() const noexcept { return failed_; }
  bool has_initial() const noexcept { return initial_ && !failed_ && phase_ == phase::subscribed; }

  void begin_retirement() noexcept {
    if (phase_ != phase::subscribed) refuse();
    phase_ = phase::retiring;
  }

  void complete_retirement(bool original_provider_current, bool source_invalidated,
                           bool notifier_closed, bool port_destroyed) noexcept {
    if (phase_ != phase::retiring || !original_provider_current || !source_invalidated ||
        !notifier_closed || !port_destroyed) refuse();
    phase_ = phase::retired;
  }

  capability_class result() const noexcept {
    return !failed_ && initial_ && phase_ == phase::retired ? value_ : capability_class::refused;
  }

private:
  enum class phase { created, subscribed, retiring, retired };
  phase phase_ = phase::created;
  bool failed_ = false;
  bool initial_ = false;
  capability_class value_ = capability_class::refused;
};
} // namespace hs274_priority_initial
