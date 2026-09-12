// tools/diagnostics/hs274-stream-runtime.hpp
// Disposable native bridge; all access belongs to the shared dispatcher.
#pragma once

#include "hs274-stream-source.hpp"
#include "hs274-stream-input.hpp"
#include <uuid/uuid.h>

namespace hs274_stream_protocol {
class runtime final {
  // Bound observed keyboard interfaces; exhaustion explicitly invalidates coverage.
  using source_type = source<4096, 64, 64>;
public:
  using monitor = source_type::monitor;

  runtime() : source_(make_incarnation()) {
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

  static monitor attach(std::uint64_t device) {
    if (!active_) throw std::logic_error("Capture monitor has no receiver owner");
    return active_->source_.attach(device);
  }

  static void append(monitor& owner, bool is_reference, const value& input) noexcept {
    // Retain the finite independent receipt during this fixture experiment.
    append_input(owner, hs274_raw_capture::fixture, is_reference, input);
  }

private:
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
