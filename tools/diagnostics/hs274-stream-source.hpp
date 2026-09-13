// tools/diagnostics/hs274-stream-source.hpp
// Dispatcher-owned monitor lifetimes and explicit fixture acquisition readiness.
#pragma once

#include "hs274-stream-protocol.hpp"
#include "hs274-key-state.hpp"
#include "hs274-stream-baseline-pages.hpp"
#include <array>
#include <functional>
#include <memory>
#include <utility>

namespace hs274_stream_protocol {
template <std::size_t Capacity, std::size_t Limit, std::size_t Devices>
class source final {
  static_assert(Devices > 0);
  using keyboard_state = key_state<keyboard_inventory_capacity>;
  struct slot {
    std::uint64_t device = 0, token = 0;
    bool ready = false;
    bool keyboard = false;
    std::unique_ptr<keyboard_state> keys;
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
  using sample = typename keyboard_state::sample;
  using baseline = baseline_pages<Limit, Devices, keyboard_inventory_capacity>;

  baseline freeze(std::uint64_t boundary) const {
    if (!state_->ready()) throw std::logic_error("Capture monitors are not ready for a baseline");
    std::vector<typename baseline::device_state> devices;
    for (const auto& current : state_->monitors) {
      if (!current.token) continue;
      devices.push_back({current.device, current.keyboard,
                         current.keyboard ? current.keys->snapshot(boundary)
                                          : std::vector<typename baseline::element>{}});
    }
    return baseline(boundary, std::move(devices));
  }

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

    bool started(const sample* samples, std::size_t count, bool enumerated, bool exhausted) {
      if (auto owner = owner_.lock()) {
        auto current = owner->find(token_);
        if (!current || current->ready) throw std::logic_error("Capture monitor started without pending ownership");
        if (current->keyboard) {
          current->keys = std::make_unique<keyboard_state>(current->device);
          try {
            current->keys->initialize(samples, count, enumerated, exhausted);
          } catch (const std::invalid_argument&) {
            owner->protocol.interrupt();
            return false;
          }
        } else if (!enumerated || exhausted || count != 0) {
          owner->protocol.interrupt();
          return false;
        }
        current->ready = true;
        return true;
      }
      return false;
    }

    bool key_down(std::uint32_t cookie) const {
      if (auto owner = owner_.lock()) {
        const auto current = owner->find(token_);
        if (current && current->ready && current->keys) return current->keys->down(cookie);
      }
      throw std::logic_error("Capture monitor has no qualified keyboard state");
    }

    void stopped() noexcept {
      if (auto owner = owner_.lock()) {
        if (auto current = owner->find(token_)) {
          current->ready = false;
          current->keys.reset();
          owner->protocol.interrupt();
        }
      }
    }

    void append(const value& input) noexcept {
      if (auto owner = owner_.lock()) {
        auto current = owner->find(token_);
        if (current && current->device != input.device) current->ready = false;
        if (!current || !current->ready || current->device != input.device) {
          owner->protocol.interrupt();
          return;
        }
        // State must advance even before a lease or while another monitor starts.
        // This does not claim an atomic queue cutover or suppress any raw value.
        if ((current->keyboard && current->keys->apply(input) == keyboard_state::action::invalid) ||
            (!current->keyboard && input.has_page && input.page == 7)) {
          current->ready = false;
          owner->protocol.interrupt();
          return;
        }
        if (!owner->ready()) { owner->protocol.interrupt(); return; }
        owner->protocol.append(input);
      }
    }

  private:
    friend class source;
    monitor(const std::shared_ptr<state>& owner, std::uint64_t token) : owner_(owner), token_(token) {}
    std::weak_ptr<state> owner_;
    std::uint64_t token_ = 0;
  };

  source(std::string incarnation, std::function<std::uint64_t()> clock)
      : state_(std::make_shared<state>(std::move(incarnation))), clock_(std::move(clock)) {
    if (!clock_) throw std::invalid_argument("Capture has no native clock");
  }
  source(const source&) = delete;
  source& operator=(const source&) = delete;

  bool observing() const noexcept { return preparation_.has_value(); }

  bool observes(std::uint64_t device, bool needs_seize, bool temporarily_ignored) const noexcept {
    // Observation bypasses virtual-output readiness, so it must never authorize seizure.
    if (!observing() || needs_seize || temporarily_ignored || state_->exhausted) return false;
    for (const auto& current : state_->monitors) {
      if (current.token && current.device == device) return true;
    }
    return false;
  }

  monitor attach(std::uint64_t device, bool keyboard) {
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
    *available = {device, ++state_->serial, false, keyboard, nullptr};
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
      const auto boundary = clock_();
      auto frozen = freeze(boundary);
      auto opened = state_->protocol.request(peer, {{"version", 1u}, {"action", "open"}});
      try {
        opened["baseline"] = {{"version", 1u}, {"boundary", std::to_string(boundary)}, {"rows", frozen.size()}};
        transfer_.emplace(transfer{std::move(frozen), opened, 0, std::nullopt, false});
      } catch (...) {
        state_->protocol.peer_closed(peer);
        throw;
      }
      return opened;
    }
    if (!preparation_ || preparation_->peer != peer) throw std::invalid_argument("Capture has no observation owner");
    if (action == "baseline") {
      if (input.size() != (input.contains("baseline_ack") ? 5u : 4u)) {
        throw std::invalid_argument("Invalid baseline request fields");
      }
      if (auto failure = state_->protocol.loss(peer, input)) return *failure;
      if (!transfer_) throw std::logic_error("Capture baseline is not pending");
      auto& current = *transfer_;
      if (current.pending) {
        if (!input.contains("baseline_ack") || decimal(input.at("baseline_ack")) != *current.pending) {
          throw std::invalid_argument("Baseline acknowledgement does not match its pending page");
        }
        current.cursor = *current.pending;
        current.pending.reset();
        if (current.complete) {
          auto ready = current.opened;
          ready.erase("baseline");
          ready["kind"] = "baseline_ready";
          transfer_.reset();
          return ready;
        }
      } else if (input.contains("baseline_ack")) {
        throw std::invalid_argument("Baseline has no page to acknowledge");
      }
      json page = current.pages.read(current.cursor);
      auto response = current.opened;
      response.erase("baseline");
      response["kind"] = "baseline";
      response.update(page);
      current.pending = page.at("next").get<std::size_t>();
      current.complete = page.at("complete").get<bool>();
      return response;
    }
    if (action == "pull" && transfer_) {
      if (auto failure = state_->protocol.loss(peer, input)) return *failure;
      throw std::logic_error("Capture baseline has not been acknowledged");
    }
    auto response = state_->protocol.request(peer, input);
    if (action == "close") { preparation_.reset(); transfer_.reset(); }
    return response;
  }

  void peer_closed(std::uint64_t peer) {
    state_->protocol.peer_closed(peer);
    if (preparation_ && preparation_->peer == peer) { preparation_.reset(); transfer_.reset(); }
  }

private:
  struct preparation { std::uint64_t peer, serial; };
  struct transfer {
    baseline pages;
    json opened;
    std::size_t cursor;
    std::optional<std::size_t> pending;
    bool complete;
  };
  std::shared_ptr<state> state_;
  const std::function<std::uint64_t()> clock_;
  std::optional<preparation> preparation_;
  std::optional<transfer> transfer_;
  std::uint64_t preparation_serial_ = 0;
};
} // namespace hs274_stream_protocol
