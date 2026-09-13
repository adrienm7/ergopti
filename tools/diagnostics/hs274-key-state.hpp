// tools/diagnostics/hs274-key-state.hpp
// Qualified per-element reconciliation; native queue cutover remains external.
#pragma once

#include "hs274-stream-inventory.hpp"
#include "hs274-raw-capture.hpp"

namespace hs274_stream_protocol {
template <std::size_t Limit>
class key_state final {
  static_assert(Limit > 0);
  struct element {
    std::uint32_t usage = 0, cookie = 0;
    std::uint64_t sampled_at = 0, query_started = 0, last_at = 0;
    bool sampled_down = false, down = false, seen = false, last_down = false;
  };

public:
  using sample = typename key_inventory<Limit>::sample;
  enum class action { covered_by_snapshot, unchanged, pressed, released, auxiliary, invalid };
  enum class fault { none, initialization, device, element_identity, value, chronology, hid_error };

  explicit key_state(std::uint64_t device) : device_(device) {
    if (!device) throw std::invalid_argument("Missing keyboard state device");
  }
  key_state(const key_state&) = delete;
  key_state& operator=(const key_state&) = delete;

  void initialize(const sample* samples, std::size_t count, bool enumerated, bool exhausted) {
    if (initialized_ || failure_ != fault::none) throw std::logic_error("Keyboard state already initialized or failed");
    initialized_ = true;
    failure_ = fault::initialization;
    if (!samples || count == 0 || count > Limit) throw std::invalid_argument("Invalid keyboard state inventory size");
    key_inventory<Limit> qualified;
    for (std::size_t i = 0; i < count; ++i) qualified.append(samples[i]);
    if (!qualified.finish(enumerated, exhausted)) throw std::invalid_argument("Unreadable keyboard state inventory");
    for (std::size_t i = 0; i < count; ++i) {
      const auto& row = samples[i];
      elements_[i] = {row.usage, row.cookie, row.timestamp, row.started, 0,
                      row.value == 1, row.value == 1, false, false};
    }
    count_ = count;
    failure_ = fault::none;
  }

  bool healthy() const noexcept { return initialized_ && failure_ == fault::none; }
  fault failure() const noexcept { return failure_; }

  bool down(std::uint32_t cookie) const {
    if (!healthy()) throw std::logic_error("Keyboard state is not healthy");
    for (std::size_t i = 0; i < count_; ++i) if (elements_[i].cookie == cookie) return elements_[i].down;
    throw std::invalid_argument("Unknown keyboard state cookie");
  }

  // The caller must preserve queue order. Ambiguous clocks invalidate state;
  // this classification never deletes or rewrites the independent raw receipt.
  action apply(const hs274_raw_capture::record& input) noexcept {
    if (failure_ != fault::none) return action::invalid;
    if (!initialized_) return fail(fault::initialization);
    if (input.device != device_) return fail(fault::device);
    if (!input.has_page || input.page != 7) return action::auxiliary;
    if (!input.has_usage) return fail(fault::element_identity);
    if (input.usage == 0 || input.usage == -1) return action::auxiliary;
    if (!input.has_cookie || input.usage < 1 || input.usage > 255) return fail(fault::element_identity);
    element* current = nullptr;
    for (std::size_t i = 0; i < count_; ++i) {
      if (elements_[i].cookie == input.cookie) { current = &elements_[i]; break; }
    }
    if (!current || current->usage != static_cast<std::uint32_t>(input.usage)) return fail(fault::element_identity);
    if (input.value != 0 && input.value != 1) return fail(fault::value);
    if (input.usage <= 3 && input.value != 0) return fail(fault::hid_error);
    const bool pressed = input.value == 1;
    if ((current->seen && (input.timestamp < current->last_at ||
         (input.timestamp == current->last_at && pressed != current->last_down))) ||
        (input.timestamp == current->sampled_at && pressed != current->sampled_down) ||
        (input.timestamp > current->sampled_at && input.timestamp <= current->query_started)) {
      return fail(fault::chronology);
    }
    current->seen = true;
    current->last_at = input.timestamp;
    current->last_down = pressed;
    if (input.timestamp <= current->sampled_at) return action::covered_by_snapshot;
    if (current->down == pressed) return action::unchanged;
    current->down = pressed;
    return pressed ? action::pressed : action::released;
  }

private:
  action fail(fault reason) noexcept { failure_ = reason; return action::invalid; }

  const std::uint64_t device_;
  std::array<element, Limit> elements_{};
  std::size_t count_ = 0;
  bool initialized_ = false;
  fault failure_ = fault::none;
};
} // namespace hs274_stream_protocol
