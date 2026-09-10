// tools/diagnostics/hs274-stream-source.hpp
// Dispatcher-owned monitor lifetimes and explicit fixture acquisition readiness.
#pragma once

#include "hs274-stream-protocol.hpp"
#include <array>
#include <memory>
#include <utility>

namespace hs274_stream_protocol {
template <std::size_t Capacity, std::size_t Limit, std::size_t Devices>
class source final {
  static_assert(Devices > 0);
  struct slot {
    std::uint64_t device = 0, token = 0;
    bool ready = false;
  };
  struct state {
    explicit state(std::string identity) : incarnation(std::move(identity)), protocol(incarnation) {}
    const std::string incarnation;
    controller<Capacity, Limit> protocol;
    std::array<slot, Devices> monitors{};
    std::uint64_t serial = 0;
    bool exhausted = false;

    slot* find(std::uint64_t token) {
      for (auto& monitor : monitors) if (monitor.token == token) return &monitor;
      return nullptr;
    }

    bool ready() const {
      bool found = false;
      if (exhausted) return false;
      for (const auto& monitor : monitors) {
        if (!monitor.token) continue;
        found = true;
        if (!monitor.ready) return false;
      }
      return found;
    }
  };

public:
  class monitor final {
  public:
    monitor() = default;
    monitor(const monitor&) = delete;
    monitor& operator=(const monitor&) = delete;
    monitor(monitor&& other) noexcept : owner_(std::move(other.owner_)), token_(std::exchange(other.token_, 0)) {}
    monitor& operator=(monitor&&) = delete;
    ~monitor() { retire(); }

    void retire() noexcept {
      if (auto owner = owner_.lock()) {
        if (auto current = owner->find(token_)) {
          owner->protocol.interrupt();
          *current = {};
        }
      }
      owner_.reset();
      token_ = 0;
    }

    void started() {
      if (auto owner = owner_.lock()) {
        auto current = owner->find(token_);
        if (!current || current->ready) throw std::logic_error("Capture monitor started without pending ownership");
        current->ready = true;
      }
    }

    void stopped() noexcept {
      if (auto owner = owner_.lock()) {
        if (auto current = owner->find(token_)) {
          current->ready = false;
          owner->protocol.interrupt();
        }
      }
    }

    void append(const value& input) noexcept {
      if (auto owner = owner_.lock()) {
        auto current = owner->find(token_);
        if (current && current->device != input.device) current->ready = false;
        if (!current || !current->ready || current->device != input.device || !owner->ready()) {
          owner->protocol.interrupt();
          return;
        }
        owner->protocol.append(input);
      }
    }

  private:
    friend class source;
    monitor(const std::shared_ptr<state>& owner, std::uint64_t token) : owner_(owner), token_(token) {}
    std::weak_ptr<state> owner_;
    std::uint64_t token_ = 0;
  };

  explicit source(std::string incarnation) : state_(std::make_shared<state>(std::move(incarnation))) {}
  source(const source&) = delete;
  source& operator=(const source&) = delete;

  bool observing() const noexcept { return preparation_.has_value(); }

  monitor attach(std::uint64_t device) {
    if (!device) throw std::invalid_argument("Capture device identity is missing");
    for (const auto& current : state_->monitors) {
      if (current.device == device) throw std::logic_error("Capture device already registered");
    }
    slot* available = nullptr;
    for (auto& current : state_->monitors) if (!current.token) { available = &current; break; }
    if (!available || state_->serial == UINT64_MAX || state_->exhausted) {
      state_->exhausted = true;
      state_->protocol.interrupt();
      throw std::overflow_error("Capture monitor inventory exhausted");
    }
    state_->protocol.interrupt();
    *available = {device, ++state_->serial, false};
    return monitor(state_, available->token);
  }

  json request(std::uint64_t peer, const json& input) {
    if (!peer || !input.is_object() || !input.at("version").is_number_unsigned() || input.at("version") != 1u) {
      throw std::invalid_argument("Invalid observation request");
    }
    const auto action = input.at("action").get<std::string>();
    if (action == "prepare") {
      if (input.size() != 2 || preparation_) throw std::invalid_argument("Observation already owned or malformed");
      if (preparation_serial_ == UINT64_MAX) throw std::overflow_error("Observation identity exhausted");
      preparation_ = preparation{peer, ++preparation_serial_};
      return {{"version", 1u}, {"kind", "prepared"}, {"coverage", "fixture_only"},
              {"incarnation", state_->incarnation}, {"preparation", std::to_string(preparation_->serial)}};
    }
    if (input.at("action") == "status") {
      if (!peer || input.size() != 2 || !input.at("version").is_number_unsigned() || input.at("version") != 1u) {
        throw std::invalid_argument("Invalid capture status request");
      }
      json monitors = json::array();
      for (const auto& current : state_->monitors) {
        if (current.token) monitors.push_back({{"device", std::to_string(current.device)}, {"started", current.ready}});
      }
      return {{"version", 1u}, {"kind", "status"}, {"coverage", "fixture_only"},
              {"incarnation", state_->incarnation}, {"ready", state_->ready()},
              {"exhausted", state_->exhausted}, {"monitors", std::move(monitors)}};
    }
    if (action == "open" || action == "cancel") {
      if (input.size() != 4 || !preparation_ || preparation_->peer != peer ||
          input.at("incarnation") != state_->incarnation || decimal(input.at("preparation")) != preparation_->serial) {
        throw std::invalid_argument("Observation belongs to another preparation");
      }
      if (action == "cancel") {
        auto response = input;
        response.erase("action");
        response["kind"] = "cancelled";
        peer_closed(peer);
        return response;
      }
      if (!state_->ready()) throw std::runtime_error("Capture monitors are not ready");
      return state_->protocol.request(peer, {{"version", 1u}, {"action", "open"}});
    }
    if (!preparation_ || preparation_->peer != peer) throw std::invalid_argument("Capture has no observation owner");
    auto response = state_->protocol.request(peer, input);
    if (action == "close") preparation_.reset();
    return response;
  }

  void peer_closed(std::uint64_t peer) {
    state_->protocol.peer_closed(peer);
    if (preparation_ && preparation_->peer == peer) preparation_.reset();
  }

private:
  struct preparation { std::uint64_t peer, serial; };
  std::shared_ptr<state> state_;
  std::optional<preparation> preparation_;
  std::uint64_t preparation_serial_ = 0;
};
} // namespace hs274_stream_protocol
