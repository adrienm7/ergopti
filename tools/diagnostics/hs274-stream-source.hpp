// tools/diagnostics/hs274-stream-source.hpp
// Dispatcher-owned monitor lifetimes and explicit fixture acquisition readiness.
#pragma once

#include "hs274-stream-protocol.hpp"
#include "hs274-stream-native-control.hpp"
#include "hs274-stream-native-fault.hpp"
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
    hs274_key_policy::keyboard_type keyboard_type = hs274_key_policy::keyboard_type::unavailable;
    std::unique_ptr<keyboard_state> keys;
    native_refusal refusal = native_refusal::none;
  };
  struct state {
    explicit state(std::string identity) : incarnation(std::move(identity)), protocol(incarnation) {}
    const std::string incarnation;
    controller<Capacity, Limit> protocol;
    std::array<slot, Devices> monitors{};
    std::uint64_t serial = 0;
    bool exhausted = false;
    native_fault native_failure = native_fault::none;

    slot* find(std::uint64_t token) {
      for (auto& monitor : monitors) if (monitor.token == token) return &monitor;
      return nullptr;
    }

    void native_fail(native_fault reason) noexcept {
      if (native_failure == native_fault::none) native_failure = reason == native_fault::none || reason == native_fault::inactive
          ? native_fault::invalid_device_type : reason;
      exhausted = true;
      protocol.interrupt();
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
                         current.keys ? current.keys->snapshot(boundary)
                                      : std::vector<typename baseline::element>{}, current.keyboard_type});
    }
    return baseline(boundary, std::move(devices));
  }

  class native_owner_fence final {
  public:
    native_owner_fence() = default;
    bool live() const noexcept {
      if (!token_) return false;
      if (auto owner = owner_.lock()) return owner->find(token_) != nullptr;
      return false;
    }
    bool belongs_to(const source& receiver) const noexcept {
      return live() && !owner_.owner_before(receiver.state_) && !receiver.state_.owner_before(owner_);
    }
    native_fault fault() const noexcept {
      if (auto owner = owner_.lock()) {
        if (token_ && owner->find(token_)) return owner->native_failure;
      }
      return native_fault::inactive;
    }
    void stopped() const noexcept {
      if (auto owner = owner_.lock()) {
        if (token_) if (auto current = owner->find(token_)) {
          current->ready = false;
          current->keys.reset();
          owner->protocol.interrupt();
        }
      }
    }
    void fail(native_fault reason) const noexcept {
      if (auto owner = owner_.lock()) {
        if (token_ && owner->find(token_)) owner->native_fail(reason);
      }
    }
  private:
    friend class source;
    native_owner_fence(const std::weak_ptr<state>& owner, std::uint64_t token) : owner_(owner), token_(token) {}
    std::weak_ptr<state> owner_;
    std::uint64_t token_ = 0;
  };

  class monitor final {
  public:
    monitor() = default;
    monitor(const monitor&) = delete;
    monitor& operator=(const monitor&) = delete;
    monitor(monitor&& other) noexcept : owner_(std::move(other.owner_)), token_(std::exchange(other.token_, 0)) {}
    monitor& operator=(monitor&&) = delete;
    ~monitor() { retire(); }

    native_owner_fence capture_fence() const noexcept { return native_owner_fence(owner_, token_); }
    bool active() const noexcept { return capture_fence().live(); }

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
        if (current->refusal != native_refusal::none) { owner->protocol.interrupt(); return false; }
        if (count > keyboard_inventory_capacity || (count && !samples)) { owner->protocol.interrupt(); return false; }
        bool has_keyboard = false;
        for (std::size_t i = 0; i < count; ++i) has_keyboard = has_keyboard || samples[i].page == 7;
        if (has_keyboard != current->keyboard || !enumerated || exhausted) {
          owner->protocol.interrupt();
          return false;
        }
        // A successful start replaces the whole inventory, including an empty
        // one. Failed qualification must not publish a partial replacement.
        std::unique_ptr<keyboard_state> keys;
        if (count) {
          keys = std::make_unique<keyboard_state>(current->device);
          try {
            keys->initialize(samples, count, enumerated, exhausted);
          } catch (const std::invalid_argument&) {
            owner->protocol.interrupt();
            return false;
          }
        }
        current->keys = std::move(keys);
        current->ready = true;
        return true;
      }
      return false;
    }

    void refuse(native_refusal reason) noexcept {
      if (auto owner = owner_.lock()) {
        if (auto current = owner->find(token_)) {
          current->ready = false;
          current->keys.reset();
          current->refusal = reason == native_refusal::none ? native_refusal::changed_native_provenance : reason;
          owner->protocol.interrupt();
        }
      }
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
        if ((current->keys && current->keys->apply(input) == keyboard_state::action::invalid) ||
            (!current->keys && input.has_page &&
             hs274_key_policy::is_button_page(static_cast<std::uint32_t>(input.page)))) {
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

  class native_registration final {
  public:
    native_registration() = default;
    native_registration(const native_registration&) = delete;
    native_registration& operator=(const native_registration&) = delete;
    native_registration(native_registration&& other) noexcept
        : owner_(std::move(other.owner_)), reason_(std::exchange(other.reason_, native_fault::inactive)) {}
    native_registration& operator=(native_registration&&) = delete;
    // An owned registration permits qualification work, never capture readiness.
    bool active() const noexcept { return reason_ == native_fault::none && owner_.active(); }
    native_owner_fence capture_fence() const noexcept {
      return reason_ == native_fault::none ? owner_.capture_fence() : native_owner_fence{};
    }
    native_fault reason() const noexcept { return reason_; }
    bool started(const sample* samples, std::size_t count, bool enumerated, bool exhausted) {
      return active() && owner_.started(samples, count, enumerated, exhausted);
    }
    void append(const value& input) noexcept { if (active()) owner_.append(input); }
    void stopped() noexcept { if (active()) owner_.stopped(); }
    void refuse(native_refusal reason) noexcept { if (active()) owner_.refuse(reason); }
    void retire() noexcept { owner_.retire(); reason_ = native_fault::inactive; }
  private:
    friend class source;
    explicit native_registration(native_fault reason) : reason_(reason) {}
    explicit native_registration(monitor&& owner) : owner_(std::move(owner)), reason_(native_fault::none) {}
    monitor owner_;
    native_fault reason_ = native_fault::inactive;
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

  // Explicit diagnostic type is not evidence of native property correlation.
  // Old native callers supply no type and remain refused until independently
  // qualified observation is wired; no guessed type may advertise readiness.
  monitor attach(std::uint64_t device, bool keyboard,
                 hs274_key_policy::keyboard_type keyboard_type = hs274_key_policy::keyboard_type::unavailable) {
    if (!hs274_key_policy::admits_device_type(keyboard, keyboard_type))
      throw std::invalid_argument("Missing qualified capture keyboard type");
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
    *available = {device, ++state_->serial, false, keyboard, keyboard_type, nullptr};
    return monitor(state_, available->token);
  }

  monitor refuse(std::uint64_t device, native_refusal reason) {
    if (reason == native_refusal::none) throw std::invalid_argument("Missing native refusal reason");
    auto result = attach(device, false, hs274_key_policy::keyboard_type::none);
    result.refuse(reason);
    return result;
  }

  native_fault native_fault_reason() const noexcept { return state_->native_failure; }

  void native_failure(native_fault reason) noexcept { state_->native_fail(reason); }

  // Native diagnostic registration contains known refusals without throwing
  // through ordinary monitor construction. Strict attach() remains unchanged.
  native_registration native_attach(std::uint64_t device, bool keyboard,
      hs274_key_policy::keyboard_type type, native_refusal refusal = native_refusal::none) {
    const auto refused = [this](native_fault reason) {
      native_failure(reason);
      return native_registration(state_->native_failure);
    };
    if (state_->native_failure != native_fault::none) return native_registration(state_->native_failure);
    if (!device) return refused(native_fault::invalid_device_identity);
    for (const auto& current : state_->monitors)
      if (current.token && current.device == device) return refused(native_fault::duplicate_device_identity);
    if (refusal == native_refusal::none && !hs274_key_policy::admits_device_type(keyboard, type))
      return refused(native_fault::invalid_device_type);
    if (state_->serial == UINT64_MAX) return refused(native_fault::registration_serial_exhausted);
    bool available = false;
    for (const auto& current : state_->monitors) available = available || !current.token;
    if (!available || state_->exhausted) return refused(native_fault::registration_capacity_exhausted);
    return native_registration(refusal == native_refusal::none ? attach(device, keyboard, type)
                                                              : refuse(device, refusal));
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
        if (current.token) monitors.push_back({{"device", std::to_string(current.device)}, {"started", current.ready},
                                               {"refusal", refusal_name(current.refusal)}});
      }
      return {{"version", 1u}, {"kind", "status"}, {"coverage", "fixture_only"},
              {"incarnation", state_->incarnation}, {"ready", state_->ready()},
              {"exhausted", state_->exhausted}, {"native_fault", native_fault_name(state_->native_failure)},
              {"monitors", std::move(monitors)}};
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
        opened["baseline"] = {{"version", 2u}, {"boundary", std::to_string(boundary)}, {"rows", frozen.size()}};
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
