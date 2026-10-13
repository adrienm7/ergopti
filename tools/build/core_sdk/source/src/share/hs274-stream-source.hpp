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
    std::uint64_t queue_revision = 1;
    bool exhausted = false;
    native_fault native_failure = native_fault::none;

    slot* find(std::uint64_t token) {
      for (auto& monitor : monitors) if (monitor.token == token) return &monitor;
      return nullptr;
    }

    void invalidate_queue() noexcept {
      if (queue_revision == UINT64_MAX) { exhausted=true; protocol.interrupt(); }
      else ++queue_revision;
    }

    void native_fail(native_fault reason) noexcept {
      invalidate_queue();
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


  class monitor;
  class queue_interval;
  class queue_snapshot final {
  public:
    queue_snapshot() = default;
    bool current() const noexcept {
      auto owner=owner_.lock();
      return owner && token_ && owner->queue_revision==revision_ && owner->ready() && owner->find(token_);
    }
    std::uint64_t device() const noexcept { return frozen_.device; }
    std::uint64_t cut_at() const noexcept { return boundary_; }
  private:
    friend class source;
    friend class queue_interval;
    queue_snapshot(std::weak_ptr<state> owner, std::uint64_t token, std::uint64_t revision,
                   std::uint64_t boundary, typename baseline::device_state frozen)
        : owner_(std::move(owner)), token_(token), revision_(revision), boundary_(boundary), frozen_(std::move(frozen)) {}
    std::weak_ptr<state> owner_;
    std::uint64_t token_=0, revision_=0, boundary_=0;
    typename baseline::device_state frozen_{};
  };
  class queue_interval final {
  public:
    queue_interval() = default;
    bool current() const noexcept {
      auto owner=owner_.lock();
      return owner && token_ && owner->queue_revision==revision_ && owner->ready() && owner->find(token_);
    }
    queue_snapshot freeze(std::uint64_t boundary) const {
      if (!current()) throw std::logic_error("Native queue interval changed before folded snapshot");
      auto owner=owner_.lock();
      const auto current=owner->find(token_);
      typename baseline::device_state frozen{current->device, current->keyboard,
          current->keys ? current->keys->snapshot(boundary) : std::vector<typename baseline::element>{}, current->keyboard_type};
      return queue_snapshot(owner,token_,revision_,boundary,std::move(frozen));
    }
  private:
    friend class monitor;
    queue_interval(std::weak_ptr<state> owner, std::uint64_t token) : owner_(std::move(owner)),token_(token) {
      if (auto state=owner_.lock()) revision_=state->queue_revision;
    }
    std::weak_ptr<state> owner_;
    std::uint64_t token_=0, revision_=0;
  };
  baseline freeze_queue_snapshots(const std::vector<queue_snapshot>& snapshots, std::uint64_t boundary) const {
    if (!state_->ready()) throw std::logic_error("Queue snapshot source is not ready");
    std::size_t count=0;
    for (const auto& row:state_->monitors) count+=row.token!=0;
    if (snapshots.size()!=count) throw std::logic_error("Queue snapshot interface set is incomplete");
    std::vector<typename baseline::device_state> devices;
    for (const auto& row:snapshots) {
      if (!row.current() || row.boundary_>boundary || row.owner_.owner_before(state_) || state_.owner_before(row.owner_))
        throw std::logic_error("Queue snapshot ownership or clock changed");
      for (const auto& previous:devices) if (previous.device==row.device()) throw std::logic_error("Duplicate queue snapshot");
      devices.push_back(row.frozen_);
    }
    return baseline(boundary,std::move(devices));
  }

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
          owner->invalidate_queue(); owner->protocol.interrupt();
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

    queue_interval capture_queue_interval() const noexcept { return queue_interval(owner_, token_); }
    native_owner_fence capture_fence() const noexcept { return native_owner_fence(owner_, token_); }
    bool active() const noexcept { return capture_fence().live(); }

    void retire() noexcept {
      if (auto owner = owner_.lock()) {
        if (auto current = owner->find(token_)) {
          owner->invalidate_queue(); owner->protocol.interrupt();
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
        if (current->refusal != native_refusal::none) { owner->invalidate_queue(); owner->protocol.interrupt(); return false; }
        if (count > keyboard_inventory_capacity || (count && !samples)) { owner->invalidate_queue(); owner->protocol.interrupt(); return false; }
        bool has_keyboard = false;
        for (std::size_t i = 0; i < count; ++i) has_keyboard = has_keyboard || samples[i].page == 7;
        if (has_keyboard != current->keyboard || !enumerated || exhausted) {
          owner->invalidate_queue(); owner->protocol.interrupt();
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
            owner->invalidate_queue(); owner->protocol.interrupt();
            return false;
          }
        }
        current->keys = std::move(keys);
        owner->invalidate_queue();
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
          owner->invalidate_queue(); owner->protocol.interrupt();
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
          owner->invalidate_queue(); owner->protocol.interrupt();
        }
      }
    }

    void append(const value& input) noexcept {
      if (auto owner = owner_.lock()) {
        auto current = owner->find(token_);
        if (current && current->device != input.device) current->ready = false;
        if (!current || !current->ready || current->device != input.device) {
          owner->invalidate_queue(); owner->protocol.interrupt();
          return;
        }
        // State must advance even before a lease or while another monitor starts.
        // This does not claim an atomic queue cutover or suppress any raw value.
        if ((current->keys && current->keys->apply(input) == keyboard_state::action::invalid) ||
            (!current->keys && input.has_page &&
             hs274_key_policy::is_button_page(static_cast<std::uint32_t>(input.page)))) {
          current->ready = false;
          owner->invalidate_queue(); owner->protocol.interrupt();
          return;
        }
        if (!owner->ready()) { owner->invalidate_queue(); owner->protocol.interrupt(); return; }
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
    queue_interval capture_queue_interval() const noexcept { return active() ? owner_.capture_queue_interval() : queue_interval{}; }
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
      state_->invalidate_queue(); state_->protocol.interrupt();
      throw std::overflow_error("Capture monitor inventory exhausted");
    }
    state_->invalidate_queue(); state_->protocol.interrupt();
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

  void inventory_changed() noexcept { state_->invalidate_queue(); state_->protocol.interrupt(); }

  void peer_closed(std::uint64_t peer) {
    if (production_ && production_->peer == peer) production_.reset();
    state_->protocol.peer_closed(peer);
    if (preparation_ && preparation_->peer == peer) { preparation_.reset(); transfer_.reset(); }
  }

private:

  friend class runtime;
  struct production_interval {
    std::uint64_t peer;
    json opened;
    std::optional<std::uint64_t> baseline_sequence;
  };
  std::optional<production_interval> production_;

  json prepare_production(std::uint64_t peer, const json& input) {
    if (production_ || input.at("action") != "prepare_installed" || input.size() != 2)
      throw std::invalid_argument("Production preparation is already owned or malformed");
    auto canonical = input;
    canonical["action"] = "prepare";
    try {
      auto prepared = request(peer, canonical);
      production_.emplace(production_interval{peer, json{}, std::nullopt});
      // Authentication alone does not establish native queue coverage.
      prepared["coverage"] = "pending";
      return prepared;
    } catch (...) {
      production_.reset();
      peer_closed(peer);
      throw;
    }
  }
  void begin_production(std::uint64_t peer, const json& input) {
    if (!production_ || production_->peer != peer || !production_->opened.empty() ||
        !preparation_ || preparation_->peer != peer || input.size() != 4 ||
        input.at("action") != "open_installed" || input.at("version") != 1u ||
        !input.at("version").is_number_unsigned() ||
        input.at("incarnation") != state_->incarnation ||
        decimal(input.at("preparation")) != preparation_->serial || !state_->ready())
      throw std::invalid_argument("Production interval does not belong to this preparation");
    // This original bounded ring is acquired BEFORE the first native queue cut.
    production_->opened = state_->protocol.request(peer, {{"version", 1u}, {"action", "open"}});
  }
  json finish_production(std::uint64_t peer, const std::vector<queue_snapshot>& snapshots) {
    if (!production_ || production_->peer != peer || production_->opened.empty() ||
        production_->baseline_sequence || transfer_)
      throw std::logic_error("Production queue interval is not pending");
    if (state_->protocol.loss(peer, production_->opened))
      throw std::logic_error("Production ring overflowed or was interrupted during native cuts");
    const auto boundary = clock_();
    // Validate every source-issued cut against the same current registration.
    // Then freeze final folded state, including intervening retained events,
    // on this same dispatcher; no independent native value sample occurs.
    (void)freeze_queue_snapshots(snapshots, boundary);
    auto frozen = freeze(boundary);
    const auto cut = state_->protocol.production_baseline_sequence(peer, production_->opened);
    auto opened = production_->opened;
    opened["coverage"] = "complete";
    opened["baseline_sequence"] = std::to_string(cut);
    opened["baseline"] = {{"version", 2u}, {"boundary", std::to_string(boundary)}, {"rows", frozen.size()}};
    transfer_.emplace(transfer{std::move(frozen), opened, 0, std::nullopt, false});
    production_->opened = opened;
    production_->baseline_sequence = cut;
    return opened;
  }
  json observation_suspend_projection(std::uint64_t peer,const json& input) const {
    if (!production_ || production_->peer!=peer || !preparation_ || preparation_->peer!=peer ||
        !production_->baseline_sequence || production_->opened.empty() || transfer_ ||
        !input.is_object() || input.size()!=6 || !input.at("version").is_number_unsigned() ||
        input.at("version")!=1u || input.at("action")!="suspend_observation" ||
        input.at("incarnation")!=state_->incarnation ||
        decimal(input.at("preparation"))!=preparation_->serial ||
        input.at("lease")!=production_->opened.at("lease") ||
        input.at("baseline_sequence")!=std::to_string(*production_->baseline_sequence))
      throw std::logic_error("Observation suspend does not bind the exact acknowledged original cut");
    return {{"version",1u},{"kind","observation_suspended"},{"incarnation",state_->incarnation},
            {"preparation",std::to_string(preparation_->serial)},{"lease",production_->opened.at("lease")},
            {"baseline_sequence",std::to_string(*production_->baseline_sequence)}};
  }
  void finish_observation_suspension(std::uint64_t peer,const json& projection) {
    // Runtime supplies its preallocated projection only after native callback fences.
    auto input=projection;
    input.erase("kind"); input.erase("cohort"); input["action"]="suspend_observation";
    const auto expected=observation_suspend_projection(peer,input);
    if (projection.size()!=7 || projection.at("kind")!=expected.at("kind"))
      throw std::logic_error("Observation suspension projection changed");
    state_->protocol.request(peer,{{"version",1u},{"action","close"},
        {"incarnation",production_->opened.at("incarnation")},{"lease",production_->opened.at("lease")}});
    // Original protocol close releases its exact bounded storage owner. Unlike
    // ordinary source close, this preserves actual preparation and production peer.
    production_->opened=json{}; production_->baseline_sequence.reset();
  }
  json observation_cancel_projection(std::uint64_t peer,const json& input) const {
    if (!production_ || production_->peer!=peer || !preparation_ || preparation_->peer!=peer ||
        !production_->baseline_sequence || production_->opened.empty() || !transfer_ ||
        transfer_->opened!=production_->opened ||
        !input.is_object() || input.size()!=6 || !input.at("version").is_number_unsigned() ||
        input.at("version")!=1u || input.at("action")!="cancel_observation" ||
        input.at("incarnation")!=state_->incarnation ||
        decimal(input.at("preparation"))!=preparation_->serial ||
        input.at("lease")!=production_->opened.at("lease") ||
        input.at("baseline_sequence")!=std::to_string(*production_->baseline_sequence))
      throw std::logic_error("Observation cancellation does not bind the original pending baseline cut");
    return {{"version",1u},{"kind","observation_cancelled"},{"incarnation",state_->incarnation},
            {"preparation",std::to_string(preparation_->serial)},{"lease",production_->opened.at("lease")},
            {"baseline_sequence",std::to_string(*production_->baseline_sequence)}};
  }
  void finish_observation_cancellation(std::uint64_t peer,const json& projection) {
    // This typed source projection discards a pending metric baseline, never ACKs it.
    auto input=projection;
    input.erase("kind"); input.erase("cohort"); input["action"]="cancel_observation";
    const auto expected=observation_cancel_projection(peer,input);
    if (projection.size()!=7 || projection.at("kind")!=expected.at("kind"))
      throw std::logic_error("Observation cancellation projection changed");
    state_->protocol.request(peer,{{"version",1u},{"action","close"},
        {"incarnation",production_->opened.at("incarnation")},{"lease",production_->opened.at("lease")}});
    // Discard only this unacknowledged transfer after exact protocol ring close.
    // The prepared owner and configured native cohort remain admitted.
    transfer_.reset();
    production_->opened=json{}; production_->baseline_sequence.reset();
  }
  json production_request(std::uint64_t peer, const json& input) {
    if (!production_ || production_->peer != peer)
      throw std::invalid_argument("Installed request has no original production owner");
    const auto action = input.at("action").get<std::string>();
    if (action == "status") {
      auto status = request(peer, input);
      status["coverage"] = production_->baseline_sequence ? "complete" : "pending";
      return status;
    }
    if (!production_->baseline_sequence)
      throw std::logic_error("Installed native queue cut has not completed");
    if (action != "baseline" && action != "pull" && action != "close")
      throw std::invalid_argument("Unsupported installed lease action");
    const auto original_opened = production_->opened;
    const auto cut = *production_->baseline_sequence;
    auto response = request(peer, input);
    if (action == "baseline" && response.at("kind") == "baseline_ready")
      state_->protocol.production_baseline_acknowledge(peer, original_opened, cut);
    response["coverage"] = "complete";
    response["baseline_sequence"] = std::to_string(cut);
    if (action == "close") production_.reset();
    return response;
  }

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
