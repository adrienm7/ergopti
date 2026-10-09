// Dispatcher-owned expected interfaces; this is not a native queue fence.
#pragma once
#include <array>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <utility>
#include <vector>

namespace ergoptiplus::remap {
inline constexpr std::size_t native_interface_capacity = 64;
template <std::size_t Limit>
class native_inventory final {
  static_assert(Limit > 0);
  struct state {
    void* receiver;
    void (*interrupt)(void*) noexcept;
    std::array<std::uint64_t, Limit> expected{};
    std::size_t count = 0;
    std::uint64_t serial = 0, current = 0;
    bool settled = false, failed = false;
    void invalidate() noexcept {
      interrupt(receiver);
      settled = false;
    }
  };
public:
  class watch final {
  public:
    watch() = default;
    watch(const watch&) = delete;
    watch& operator=(const watch&) = delete;
    watch(watch&& other) noexcept : owner_(std::move(other.owner_)), token_(std::exchange(other.token_, 0)) {}
    watch& operator=(watch&&) = delete;
    ~watch() { retire(); }
    void publish(const std::vector<std::uint64_t>& identities, bool settled, bool failed) const noexcept {
      auto owner = owner_.lock();
      if (!owner || !token_ || owner->current != token_) return;
      bool invalid = identities.size() > Limit;
      for (std::size_t i = 0; i < identities.size() && !invalid; ++i) {
        if (!identities[i]) invalid = true;
        for (std::size_t j = 0; j < i; ++j) if (identities[j] == identities[i]) invalid = true;
      }
      failed = failed || invalid || owner->failed;
      settled = settled && !failed;
      bool changed = settled != owner->settled || failed != owner->failed || identities.size() != owner->count;
      if (!changed) {
        for (auto identity : identities) {
          bool found = false;
          for (std::size_t i = 0; i < owner->count; ++i) found = found || owner->expected[i] == identity;
          changed = changed || !found;
        }
      }
      if (changed) owner->invalidate();
      owner->failed = failed;
      owner->settled = settled;
      owner->count = invalid ? 0 : identities.size();
      for (std::size_t i = 0; i < owner->count; ++i) owner->expected[i] = identities[i];
    }
    void retire() noexcept {
      if (auto owner = owner_.lock(); token_ && owner && owner->current == token_) {
        owner->invalidate();
        owner->current = 0;
        owner->count = 0;
      }
      token_ = 0;
    }
  private:
    friend class native_inventory;
    watch(std::weak_ptr<state> owner, std::uint64_t token) : owner_(std::move(owner)), token_(token) {}
    std::weak_ptr<state> owner_;
    std::uint64_t token_ = 0;
  };
  native_inventory(void* receiver, void (*interrupt)(void*) noexcept)
      : state_(std::make_shared<state>(state{receiver, interrupt})) {}
  watch begin() {
    if (state_->current || state_->serial == UINT64_MAX) {
      state_->invalidate();
      state_->failed = true;
      throw std::logic_error("Native inventory has no fresh ownership");
    }
    state_->invalidate();
    state_->failed = false;
    state_->current = ++state_->serial;
    return watch(state_, state_->current);
  }
  bool matches(const std::vector<std::uint64_t>& registrations) const noexcept {
    if (!state_->current || !state_->settled || state_->failed || registrations.size() != state_->count) return false;
    for (std::size_t i = 0; i < registrations.size(); ++i) {
      bool found = false;
      for (std::size_t j = 0; j < state_->count; ++j) found = found || registrations[i] == state_->expected[j];
      if (!found) return false;
      for (std::size_t j = 0; j < i; ++j) if (registrations[j] == registrations[i]) return false;
    }
    return true;
  }
private:
  std::shared_ptr<state> state_;
};
} // namespace ergoptiplus::remap
