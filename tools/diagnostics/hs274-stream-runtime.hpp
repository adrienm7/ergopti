// tools/diagnostics/hs274-stream-runtime.hpp
// Disposable native bridge; all access belongs to the shared dispatcher.
#pragma once

#include "hs274-stream-source.hpp"
#include "hs274-stream-input.hpp"
#include "hs274-stream-native-binding.hpp"
#include "hs274-stream-baseline-probe.hpp"
#include "hs274-stream-native-boundary.hpp"
#include <uuid/uuid.h>
#include <mach/mach_time.h>

namespace hs274_stream_protocol {
class runtime final {
  // Bound observed keyboard interfaces; exhaustion explicitly invalidates coverage.
  using source_type = source<4096, 64, 64>;
public:
  using monitor = source_type::native_registration;

  runtime() : source_(make_incarnation(), [] { return mach_absolute_time(); }) {
    if (active_) throw std::logic_error("Capture receiver already owns the native bridge");
    active_ = this;
  }
  runtime(const runtime&) = delete;
  runtime& operator=(const runtime&) = delete;
  ~runtime() { active_ = nullptr; }

  json request(std::uint64_t peer, const json& input) { return source_.request(peer, input); }
  void peer_closed(std::uint64_t peer) { source_.peer_closed(peer); }
  bool observing() const noexcept { return source_.observing(); }

  static bool observes(std::uint64_t device, bool needs_seize, bool temporarily_ignored) {
    if (!active_) throw std::logic_error("Capture policy has no receiver owner");
    return active_->source_.observes(device, needs_seize, temporarily_ignored);
  }

  static monitor attach(const native_binding& binding) {
    if (!active_) throw std::logic_error("Capture monitor has no receiver owner");
    return active_->source_.native_attach(binding.device(), binding.keyboard(), binding.type(), binding.refusal());
  }

  static bool started(monitor& owner, const native_binding& binding, IOHIDDeviceRef device) {
    const auto fence = owner.capture_fence();
    if (!current(fence) || !owner.active()) return false;
    if (fence.fault() != native_fault::none) { fence.stopped(); return false; }
    const native_binding captured(binding);
    return diagnostic_acquisition(owner, [fence](native_fault reason) { fence.fail(reason); }, [&] {
      const auto inventory = hs274_baseline_probe::capture_inventory(device, captured.device());
      if (!current(fence)) return false;
      bool keyboard = false;
      for (const auto& sample : inventory.samples) keyboard = keyboard || sample.page == 7;
      const bool unchanged = captured.unchanged(device, keyboard);
      if (!current(fence)) return false;
      if (!unchanged) {
        owner.refuse(captured.refusal() == native_refusal::none
                         ? native_refusal::changed_native_provenance : captured.refusal());
        return false;
      }
      return owner.started(inventory.samples.data(), inventory.samples.size(), inventory.enumerated, inventory.exhausted);
    }, current);
  }

  static bool reference(monitor& owner, IOHIDDeviceRef device, std::uint64_t identity) {
    const auto fence = owner.capture_fence();
    if (!current(fence) || !owner.active()) return false;
    if (fence.fault() != native_fault::none) { fence.stopped(); return false; }
    return diagnostic_acquisition(owner, [fence](native_fault reason) { fence.fail(reason); }, [&] {
      hs274_baseline_probe::capture(device, identity);
      return current(fence);
    }, current);
  }

  static void append(monitor& owner, bool is_reference, const value& input) noexcept {
    // Retain the finite independent receipt during this fixture experiment.
    append_input(owner, hs274_raw_capture::fixture, is_reference, input);
  }

private:
  static bool current(const source_type::native_owner_fence& fence) noexcept {
    return active_ && fence.belongs_to(active_->source_);
  }

  static std::string make_incarnation() {
    uuid_t identifier;
    char text[37];
    uuid_generate(identifier);
    uuid_unparse_lower(identifier, text);
    return text;
  }

  // The finite fixture has 20 values. Bound both backlog and per-response work;
  // actual wire size must additionally pass the receiver's message-size gate.
  source_type source_;
  inline static runtime* active_ = nullptr;
};
} // namespace hs274_stream_protocol
