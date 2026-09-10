// tools/diagnostics/hs274-stream-runtime.hpp
// Disposable native bridge; all access belongs to the shared dispatcher.
#pragma once

#include "hs274-stream-protocol.hpp"
#include <uuid/uuid.h>

namespace hs274_stream_protocol {
class runtime final {
public:
  runtime() : controller_(make_incarnation()) {
    if (active_) throw std::logic_error("Capture receiver already owns the native bridge");
    active_ = this;
  }
  runtime(const runtime&) = delete;
  runtime& operator=(const runtime&) = delete;
  ~runtime() { active_ = nullptr; }

  json request(std::uint64_t peer, const json& input) { return controller_.request(peer, input); }
  void peer_closed(std::uint64_t peer) { controller_.peer_closed(peer); }

  static void append(const value& input) noexcept {
    // Retain the finite independent receipt during this fixture experiment.
    hs274_raw_capture::fixture.append(input);
    if (active_) active_->controller_.append(input);
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
  controller<4096, 64> controller_;
  inline static runtime* active_ = nullptr;
};
} // namespace hs274_stream_protocol
