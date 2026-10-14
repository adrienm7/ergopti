#pragma once

#include "console_user_server_peer.hpp"
#include "constants.hpp"
#include "core_service/daemon/core_service_daemon_state_manager.hpp"
#include "device_grabber_details/device_key_code_manipulator_manager.hpp"
#include "device_grabber_details/entry.hpp"
#include "hs274-stream-runtime.hpp"
#include "device_grabber_details/fn_function_keys_manipulator_manager.hpp"
#include "device_grabber_details/simple_modifications_manipulator_manager.hpp"
#include "event_tap_utility.hpp"
#include "remap_runtime_console_control.hpp"
#include <atomic>
#include <limits>
#include <mutex>
#include <stdexcept>
#include "filesystem_utility.hpp"
#include "hid_keyboard_caps_lock_led_state_manager.hpp"
#include "iokit_utility.hpp"
#include "json_writer.hpp"
#include "keyboard_suppression.hpp"
#include "krbn_notification_center.hpp"
#include "logger.hpp"
#include "manipulator/condition_factory.hpp"
#include "manipulator/manipulator_factory.hpp"
#include "manipulator/manipulator_managers_connector.hpp"
#include "manipulator/manipulators/post_event_to_virtual_devices/post_event_to_virtual_devices.hpp"
#include "monitor/configuration_monitor.hpp"
#include "monitor/event_tap_monitor.hpp"
#include "notification_message_manager.hpp"
#include "process_lifecycle_manager.hpp"
#include "types.hpp"
#include <array>
#include <algorithm>
#include <dlfcn.h>
#include <fstream>
#include <nlohmann/json.hpp>
#include <nod/nod.hpp>
#include <pqrs/gsl.hpp>
#include <pqrs/karabiner/driverkit/virtual_hid_device_driver.hpp>
#include <pqrs/osx/hitoolbox/secure_event_input_monitor.hpp>
#include <pqrs/osx/iokit_hid_manager.hpp>
#include <pqrs/osx/system_preferences.hpp>
#include <pqrs/spdlog.hpp>
#include <ranges>
#include <string_view>
#include <thread>
#include <time.h>
#include <unistd.h>
#include <unordered_map>
#include <unordered_set>

namespace krbn::core_service::daemon {
class device_grabber final : public pqrs::dispatcher::extra::dispatcher_client {
  friend class receiver;
  friend class ::hs274_stream_protocol::runtime;
  class owned_configuration_effect;
public:
  class active_cohort final : public std::enable_shared_from_this<active_cohort> {
    friend class device_grabber;
    std::shared_ptr<device_grabber> device_;
    const std::shared_ptr<ergoptiplus::remap::auth::console_control_owner> console_;
    const std::shared_ptr<hs274_stream_protocol::runtime::capture_participant> capture_;
    const std::shared_ptr<pqrs::karabiner::driverkit::virtual_hid_device_service::client::owned_status> vhd_;
    std::vector<std::shared_ptr<hid_device_events_monitor>> monitors_;
    std::vector<std::shared_ptr<hid_device_events_monitor::owned_stop_admission>> stop_admissions_;
    std::vector<std::optional<hid_device_events_monitor::owned_stop_receipt>> stopped_;
    std::vector<bool> returned_;
    std::optional<pqrs::osx::hitoolbox::secure_event_input_monitor::owned_stop_receipt> secure_;
    std::weak_ptr<event_tap_monitor> event_tap_;
    bool event_tap_completed_=false, manager_completed_=false, requested_=false, delivered_=false;
    bool binding_admitted_=false, configuration_retiring_=false;
    std::shared_ptr<owned_configuration_effect> configuration_off_;
    std::atomic_bool failed_{false};
    std::size_t pending_=0;
    std::shared_ptr<active_cohort> custody_;
    active_cohort(std::shared_ptr<ergoptiplus::remap::auth::console_control_owner> console,
                  std::shared_ptr<hs274_stream_protocol::runtime::capture_participant> capture,
                  std::shared_ptr<pqrs::karabiner::driverkit::virtual_hid_device_service::client::owned_status> vhd)
      :console_(std::move(console)),capture_(std::move(capture)),vhd_(std::move(vhd)) {}
    bool same_owner() const {
      return device_ && device_->dispatcher_thread() && device_->owned_cohort_.lock().get()==this;
    }
    bool participants_settled() const {
      if (!same_owner() || !requested_ || failed_ || pending_ ||
          !manager_completed_ || !event_tap_completed_ || !event_tap_.expired() || !secure_ || !secure_->settled() ||
          device_->owned_work_->pending.load()!=0 || device_->owned_work_->failed.load() || !console_->retired() || !vhd_->retired()) return false;
      for (const auto& receipt:stopped_) if (!receipt || !receipt->settled()) return false;
      return capture_->receiver_->owned_capture_retired(capture_);
    }
    bool terminal_conditions() const {
      return participants_settled() && capture_->receiver_->owned_capture_terminal(capture_);
    }
    void progress() noexcept {
      try {
        const auto self=shared_from_this();
        // Defer admission until the original native callback has unwound.
        if (!device_->enqueue_to_dispatcher([self] { self->deliver_terminal(); })) failed_=true;
      } catch (...) { failed_=true; }
    }
    void deliver_terminal();
    bool retain_monitor(const std::shared_ptr<hid_device_events_monitor>& monitor) {
      if (!same_owner() || requested_ || !monitor) return false;
      for (const auto& retained:monitors_) if (retained==monitor) return true;
      try {
        auto admission=monitor->retain_owned_stop(monitor);
        if (!admission) return false;
        const auto count=monitors_.size()+1;
        monitors_.reserve(count); stop_admissions_.reserve(count);
        stopped_.reserve(count); returned_.reserve(count);
        monitors_.push_back(monitor); stop_admissions_.push_back(std::move(admission));
        stopped_.emplace_back(); returned_.push_back(false); ++pending_;
        return true;
      } catch (...) { failed_=true; device_->owned_stopping_=true; return false; }
    }
  public:
    class terminal_receipt final {
      friend class active_cohort;
      const std::shared_ptr<const active_cohort> owner_;
      explicit terminal_receipt(std::shared_ptr<const active_cohort> owner):owner_(std::move(owner)) {}
    public:
      bool current() const { return owner_ && owner_->terminal_conditions(); }
      bool same_cohort(const active_cohort& other) const noexcept { return owner_.get()==&other; }
    };
  private:
    std::function<void(terminal_receipt)> observer_;
  public:
    bool current() const {
      return binding_admitted_ && same_owner() && !requested_ && !configuration_retiring_ && console_->current() && vhd_->current() &&
             capture_->receiver_ && capture_->generation_==capture_->receiver_->installed_generation_;
    }
    std::optional<terminal_receipt> terminal() const {
      if (!terminal_conditions()) return std::nullopt;
      return terminal_receipt(shared_from_this());
    }
    bool observe_terminal(std::function<void(terminal_receipt)> observer) {
      if (!same_owner() || !observer || observer_ || delivered_) return false;
      observer_=std::move(observer);
      progress();
      return true;
    }
    bool request_retirement() {
      if (!same_owner()) return false;
      if (configuration_retiring_) return !failed_;
      configuration_retiring_=true; // Close mode admission before any native cleanup enqueue.
      if (device_->owned_input_) device_->owned_input_->native_revoked_.store(true,std::memory_order_release);
      custody_=shared_from_this();
      capture_->configuration_closed_=true;
      if (auto pending=std::move(capture_->configuration_pending_)) {
        pending->native_revoked_.store(true,std::memory_order_release);
        pending->owner_->deliver({});
      }
      if (!capture_->configuration_snapshot_) return begin_retirement_after_configuration();
      const auto self=shared_from_this();
      try {
        const bool accepted=device_->revoke_owned_configuration(self,[self](bool applied) {
          if (!applied) self->failed_=true;
          // Every original independent cleanup is still attempted on refusal.
          self->begin_retirement_after_configuration();
        });
        if (!accepted && !requested_) { failed_=true; begin_retirement_after_configuration(); }
        return accepted && !failed_;
      } catch (...) { failed_=true; begin_retirement_after_configuration(); return false; }
    }
  private:
    bool begin_retirement_after_configuration() {
      if (!same_owner()) return false;
      if (requested_) return !failed_;
      // This is cleanup of a previously admitted owner. Loss of native
      // currentness closes new admission, but cannot abandon old participants.
      requested_=true;
      custody_=shared_from_this();
      device_->owned_stopping_=true;
      device_->pending_event_tap_monitor_configuration_=std::nullopt;
      device_->configuration_monitor_=nullptr;
      const auto self=shared_from_this();
      std::weak_ptr<active_cohort> weak(self);
      {
        std::lock_guard<std::mutex> lock(device_->owned_work_->mutex);
        device_->owned_work_->owner=weak;
      }
      // Every independent participant is attempted, even after another refusal.
      try {
        if (!console_->observe_retirement([weak] { if (const auto owned=weak.lock()) owned->progress(); })) failed_=true;
        console_->request_retirement();
      } catch (...) { failed_=true; }
      try {
        if (!capture_->receiver_->observe_owned_capture_retirement(capture_,[weak] { if (const auto owned=weak.lock()) owned->progress(); }) ||
            !capture_->receiver_->request_owned_capture_retirement(capture_)) failed_=true;
      } catch (...) { failed_=true; }
      for (std::size_t i=0;i<monitors_.size();++i) {
        try {
          const bool accepted=monitors_[i]->async_owned_stop(stop_admissions_[i],
              [self,i](hid_device_events_monitor::owned_stop_receipt receipt) {
                if (self->returned_[i]) { self->failed_=true; return; }
                self->returned_[i]=true;
                self->stopped_[i]=std::move(receipt);
                --self->pending_;
                self->progress();
              });
          if (!accepted) { returned_[i]=true; --pending_; failed_=true; }
        } catch (...) { failed_=true; } // unknown native enqueue keeps this debt
      }
      try {
        if (!vhd_->observe_retirement([weak] { if (const auto owned=weak.lock()) owned->progress(); }) ||
            !vhd_->request_retirement()) failed_=true;
      } catch (...) { failed_=true; }
      try {
        if (!device_->secure_event_input_monitor_->async_owned_stop(device_,
              [self](auto receipt) { self->secure_=std::move(receipt); self->progress(); })) failed_=true;
      } catch (...) { failed_=true; }
      try {
        if (device_->event_tap_monitor_) {
          auto tap=std::shared_ptr<event_tap_monitor>(std::move(device_->event_tap_monitor_));
          event_tap_=tap;
          // The original run-loop block retains an empty callable after the
          // shared-dispatcher invocation moves out its real lifetime captures.
          auto completion=std::make_shared<std::function<void()>>([self,tap] {
            self->event_tap_completed_=true;
            self->progress();
          });
          tap->async_stop([completion] {
            auto invoke=std::exchange(*completion,{});
            if (invoke) invoke();
          });
        } else if (!device_->event_tap_ever_created_) {
          // This is actual constructor lineage, not weak-expiry evidence.
          event_tap_completed_=true;
        } else failed_=true;
      } catch (...) { failed_=true; }
      try {
        if (device_->hid_manager_) {
          // Original detach cancels delayed manager callbacks; each original
          // service destructor waits for its run-loop native cleanup fence.
          device_->hid_manager_.reset();
          manager_completed_=true;
        } else failed_=true;
      } catch (...) { failed_=true; }
      progress();
      return !failed_; // accepted/pending only; never terminal success
    }
  };
private:
  struct owned_work_state final {
    std::atomic<std::uint64_t> pending{0};
    std::atomic_bool failed{false};
    std::mutex mutex;
    std::weak_ptr<active_cohort> owner;
  };
  struct owned_work final {
    const std::shared_ptr<owned_work_state> state;
    explicit owned_work(std::shared_ptr<owned_work_state> value):state(std::move(value)) {
      auto count=state->pending.load();
      for (;;) {
        if (count==std::numeric_limits<std::uint64_t>::max()) {
          state->failed=true;
          throw std::overflow_error("Original dispatcher debt exceeds its bound");
        }
        if (state->pending.compare_exchange_weak(count,count+1)) break;
      }
    }
    ~owned_work() noexcept {
      const auto before=state->pending.fetch_sub(1);
      if (before==0) { state->failed=true; return; }
      if (before!=1) return;
      try {
        std::shared_ptr<active_cohort> owner;
        { std::lock_guard<std::mutex> lock(state->mutex); owner=state->owner.lock(); }
        if (owner) owner->progress();
      } catch (...) { state->failed=true; }
    }
  };
  using configuration_request = hs274_stream_protocol::runtime::configuration_effect_request;
  using configuration_snapshot = hs274_stream_protocol::runtime::configuration_snapshot;
  using initialized_ready = pqrs::karabiner::driverkit::virtual_hid_device_service::client::initialized_ready;
  class owned_configuration_readback;
  class owned_configuration_effect final {
    friend class device_grabber;
    friend class active_cohort;
    const std::shared_ptr<active_cohort> cohort;
    const std::shared_ptr<const configuration_snapshot> snapshot;
    const std::shared_ptr<configuration_request> request;
    std::shared_ptr<owned_work> debt;
    const bool revoke;
    const int mode;
    std::shared_ptr<const initialized_ready> keyboard,pointing;
    std::shared_ptr<const owned_configuration_readback> readback_receipt;
    unsigned pushed=0,applied=0;
    bool queued=false,readback=false,readback_applied=false,activation_started=false,terminal_off=false,finished=false;
    std::function<void(bool)> completion;
    owned_configuration_effect(std::shared_ptr<active_cohort> value,
        std::shared_ptr<const configuration_snapshot> parsed,std::shared_ptr<configuration_request> original,
        std::shared_ptr<owned_work> native_debt,bool revoked,int requested,std::function<void(bool)> callback)
      :cohort(std::move(value)),snapshot(std::move(parsed)),request(std::move(original)),
       debt(std::move(native_debt)),revoke(revoked),mode(requested),completion(std::move(callback)) {}
  public:
    ~owned_configuration_effect()=default;
  private:
    bool current() const {
      if (finished || !cohort || !cohort->same_owner() || !snapshot ||
          cohort->capture_->configuration_snapshot_!=snapshot) return false;
      if (revoke) return cohort->configuration_retiring_ && !cohort->requested_;
      if (!request || !request->current() || !cohort->binding_admitted_ || cohort->requested_ ||
          cohort->configuration_retiring_ || !snapshot->current() ||
          cohort->device_->core_configuration_->retain_owned_configuration_snapshot()!=snapshot) return false;
      return mode==0 || (keyboard && keyboard->current() &&
        (!cohort->device_->needs_prepare_virtual_hid_pointing_device() || (pointing && pointing->current())));
    }
  };
  class owned_configuration_readback final {
    friend class device_grabber;
    const std::weak_ptr<active_cohort> cohort_;
    const std::shared_ptr<const configuration_snapshot> snapshot_;
    const std::uint64_t sequence_;
    const int mode_;
    const std::shared_ptr<const initialized_ready> keyboard_,pointing_;
    owned_configuration_readback(const owned_configuration_effect& effect)
      :cohort_(effect.cohort),snapshot_(effect.snapshot),sequence_(effect.request->sequence_),mode_(effect.mode),
       keyboard_(effect.keyboard),pointing_(effect.pointing) {}
    // Variable application only. Native input owners must separately prove their
    // own completion; this receipt cannot substitute grab/stop/initializer ACKs.
    bool current() const {
      const auto cohort=cohort_.lock();
      if (!cohort || !cohort->same_owner() || !cohort->binding_admitted_ || cohort->requested_ ||
          cohort->configuration_retiring_ || cohort->capture_->configuration_closed_ ||
          !cohort->capture_->current() || cohort->capture_->configuration_sequence_!=sequence_ ||
          cohort->capture_->configuration_snapshot_!=snapshot_ || !snapshot_ || !snapshot_->current() ||
          cohort->device_->core_configuration_->retain_owned_configuration_snapshot()!=snapshot_ ||
          cohort->device_->configuration_readback_.get()!=this) return false;
      return mode_==0 || (keyboard_ && keyboard_->current() &&
        (!cohort->device_->needs_prepare_virtual_hid_pointing_device() || (pointing_ && pointing_->current())));
    }
  };
  std::shared_ptr<const owned_configuration_readback> configuration_readback_;
  std::vector<std::shared_ptr<owned_configuration_effect>> configuration_effects_;

  bool bind_owned_configuration() {
    const auto cohort=owned_cohort_.lock();
    if (!cohort || !cohort->same_owner() || !cohort->binding_admitted_ || cohort->configuration_retiring_) return false;
    const auto parsed=core_configuration_->retain_owned_configuration_snapshot();
    if (!parsed || !parsed->current() || cohort->capture_->configuration_snapshot_) return false;
    post_event_to_virtual_devices_manipulator_->bind_owned_output_scope([] { return false; });
    virtual_hid_device_service_client_->bind_owned_report_scope([] { return false; });
    cohort->capture_->configuration_snapshot_=parsed;
    std::weak_ptr<device_grabber> weak(cohort->device_);
    cohort->capture_->configuration_apply_=[weak](const std::shared_ptr<configuration_request>& request) {
      const auto device=weak.lock();
      return device && device->apply_owned_configuration_request(request);
    };
    return true;
  }
  // CI's original Device startup owner implements this typed native continuation.
  // Acceptance/queued initializer replies never invoke a mode ACK.
  std::shared_ptr<configuration_request> owned_configuration_preparation_;
  std::shared_ptr<owned_configuration_effect> retained_owned_preparation_effect() const {
    const auto request=owned_configuration_preparation_;
    if (!request || !request->current() || request->mode_==0 ||
        !owned_engine_prepared_ || !owned_configuration_current()) return nullptr;
    const auto cohort=owned_cohort_.lock();
    if (!cohort || !cohort->binding_admitted_ || cohort->requested_ ||
        cohort->configuration_retiring_ || request->participant_!=cohort->capture_ ||
        request->snapshot_!=cohort->capture_->configuration_snapshot_) return nullptr;
    for (const auto& effect:configuration_effects_)
      if (!effect->finished && effect->request==request && effect->cohort==cohort) return effect;
    return nullptr;
  }
  void refuse_owned_configuration_preparation() {
    const auto request=owned_configuration_preparation_;
    owned_configuration_preparation_.reset();
    if (request) {
      const auto effects=configuration_effects_;
      for (const auto& effect:effects)
        if (effect->request==request && !effect->finished) finish_owned_configuration_effect(effect,false);
    }
    if (const auto cohort=owned_cohort_.lock()) cohort->request_retirement();
  }
  void progress_owned_configuration_preparation() {
    if (owned_input_ && owned_input_->completed_) {
      const auto cohort=owned_input_->cohort_.lock();
      if (cohort && !cohort->capture_->configuration_pending_) { progress_owned_input(); return; }
      if (cohort && cohort->capture_->configuration_pending_ &&
          cohort->capture_->configuration_pending_->mode_==0) return;
    }
    const auto effect=retained_owned_preparation_effect();
    if (!effect) { refuse_owned_configuration_preparation(); return; }
    // Queued mode mutation is still pending; duplicate native notifications
    // cannot create a second request or substitute for its native readback.
    if (effect->queued) return;
    const auto keyboard=effect->cohort->vhd_->ready(ergoptiplus::remap::vhd::initializer_kind::keyboard);
    if (!keyboard || !keyboard->current()) return;
    if (needs_prepare_virtual_hid_pointing_device()) {
      const auto pointing=effect->cohort->vhd_->ready(ergoptiplus::remap::vhd::initializer_kind::pointing);
      if (!pointing || !pointing->current()) return;
    }
    const auto request=owned_configuration_preparation_;
    if (!request || !request->current() || !resume_owned_configuration_request(request))
      refuse_owned_configuration_preparation();
  }
  bool prepare_owned_configuration_request(const std::shared_ptr<configuration_request>& request) {
    if (!dispatcher_thread() || !request || request->mode_==0 || !request->current() ||
        !owned_engine_prepared_ || !owned_configuration_current() || owned_stopping_ ||
        (owned_configuration_preparation_ && owned_configuration_preparation_!=request &&
         owned_configuration_preparation_->current())) return false;
    owned_configuration_preparation_=request;
    const auto effect=retained_owned_preparation_effect();
    if (!effect) { owned_configuration_preparation_.reset(); return false; }
    // A prior same-configuration connection may still own authentic readiness.
    // Consume its opaque issuer receipt; never use cached signal Booleans.
    const auto keyboard=effect->cohort->vhd_->ready(ergoptiplus::remap::vhd::initializer_kind::keyboard);
    const auto pointing=needs_prepare_virtual_hid_pointing_device() ?
      effect->cohort->vhd_->ready(ergoptiplus::remap::vhd::initializer_kind::pointing) : nullptr;
    if (keyboard && keyboard->current() &&
        (!needs_prepare_virtual_hid_pointing_device() || (pointing && pointing->current()))) {
      progress_owned_configuration_preparation();
      return request->current();
    }
    const auto scope=[weak=std::weak_ptr<configuration_request>(request)] {
      const auto pending=weak.lock();
      return pending && pending->native_current();
    };
    if (!effect->cohort->capture_->broker_->bind_owned_preparation(scope)) {
      refuse_owned_configuration_preparation();
      return false;
    }
    // A connected native owner must reinitialize through the same request;
    // async_start's existing-client no-op cannot stand for initialization.
    if (effect->cohort->vhd_->connection_ && effect->cohort->vhd_->current() &&
        effect->cohort->vhd_->connection_->current()) {
      update_virtual_hid_keyboard();
      update_virtual_hid_pointing();
      return request->current();
    }
    // This return is the real native dispatch acceptance, never a ready ACK.
    if (!virtual_hid_device_service_client_->prepare_owned_start(scope)) {
      refuse_owned_configuration_preparation();
      return false;
    }
    return request->current();
  }
  // This owner retains native resources independently of the mode frame.
  // Its native gate contains immutable native holders plus one revocation bit;
  // no dispatcher-only Runtime/participant field is read on a native thread.
  class owned_input_state final {
    friend class device_grabber;
    const std::weak_ptr<active_cohort> cohort_;
    const std::shared_ptr<const configuration_snapshot> snapshot_;
    const std::shared_ptr<ergoptiplus::remap::auth::console_control_owner> console_;
    const std::shared_ptr<ergoptiplus::installed_capture::core_namespace_hold> namespace_;
    const std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> broker_;
    const std::shared_ptr<const initialized_ready> keyboard_,pointing_;
    const bool needs_pointing_;
    std::atomic<bool> native_revoked_{false};
    std::atomic<bool> output_revoked_{true};
    const std::shared_ptr<const owned_configuration_readback> readback_;
    std::shared_ptr<owned_configuration_effect> effect_;
    std::shared_ptr<const pqrs::osx::iokit_hid_manager::owned_registration> inventory_;
    std::shared_ptr<const pqrs::osx::hitoolbox::secure_event_input_monitor::owned_start_receipt> secure_;
    std::shared_ptr<const event_tap_monitor::owned_start_receipt> tap_;
    bool refused_=false,completed_=false;
    owned_input_state(const std::shared_ptr<owned_configuration_effect>& effect,bool needs_pointing)
      :cohort_(effect->cohort),snapshot_(effect->snapshot),
       console_(effect->cohort->capture_->console_),namespace_(effect->cohort->capture_->namespace_),
       broker_(effect->cohort->capture_->broker_),keyboard_(effect->keyboard),pointing_(effect->pointing),
       needs_pointing_(needs_pointing),readback_(effect->readback_receipt),effect_(effect) {}
    bool native_current() const noexcept {
      try {
        return !native_revoked_.load(std::memory_order_acquire) && snapshot_ && snapshot_->current() &&
          console_ && console_->current() && namespace_ && namespace_->current() && broker_ && broker_->current() &&
          keyboard_ && keyboard_->current() && (!needs_pointing_ || (pointing_ && pointing_->current())) &&
          !native_revoked_.load(std::memory_order_acquire);
      } catch (...) { return false; }
    }
  };
  std::shared_ptr<owned_input_state> owned_input_;

  void refuse_owned_input(const std::shared_ptr<owned_input_state>& state) {
    if (!state || state->refused_) return;
    state->refused_=true;
    state->native_revoked_.store(true,std::memory_order_release);
    auto effect=std::move(state->effect_);
    if (effect && !effect->finished) finish_owned_configuration_effect(effect,false);
    if (const auto cohort=state->cohort_.lock()) cohort->request_retirement();
  }
  void progress_owned_input() {
    const auto state=owned_input_;
    if (!state || state->refused_ || state->native_revoked_.load(std::memory_order_acquire)) return;
    const auto cohort=state->cohort_.lock();
    if (!dispatcher_thread() || !cohort || !cohort->same_owner() || cohort->requested_ ||
        cohort->configuration_retiring_ || !state->native_current()) { refuse_owned_input(state); return; }
    // A new pending mode owns mutation; an old callback cannot acknowledge it.
    if (!state->readback_ || !state->readback_->current()) {
      if (cohort->capture_->configuration_pending_) return;
      refuse_owned_input(state); return;
    }
    if (!state->inventory_ || !state->secure_ || !state->tap_) return;
    if (!state->inventory_->current() || !secure_event_input_monitor_ ||
        !secure_event_input_monitor_->owned_started(state->secure_) || !event_tap_monitor_ ||
        !event_tap_monitor_->owned_started(state->tap_)) { refuse_owned_input(state); return; }
    for (const auto& [id,entry]:entries_) {
      if (make_grabbable_state(*entry)==grabbable_state::state::grabbable) {
        const auto opened=entry->get_hid_device_events_monitor()->retain_owned_open();
        if (!hid_device_events_monitor::owned_open_current(opened)) return;
      }
    }
    if (!state->completed_) {
      const auto effect=state->effect_;
      if (!effect || !effect->current() || !effect->readback_applied ||
          effect->readback_receipt!=state->readback_) { refuse_owned_input(state); return; }
      std::weak_ptr<device_grabber> weak(cohort->device_);
      post_event_to_virtual_devices_manipulator_->bind_owned_output_scope([weak,state] {
        const auto device=weak.lock();
        return device && device->owned_input_==state && state->completed_ &&
          device->owned_input_effects_current();
      });
      virtual_hid_device_service_client_->bind_owned_report_scope([state] {
        return !state->output_revoked_.load(std::memory_order_acquire) && state->native_current();
      });
      state->output_revoked_.store(false,std::memory_order_release);
      state->completed_=true;
      state->effect_.reset();
      finish_owned_configuration_effect(effect,true);
    }
  }
  bool complete_owned_configuration_input_effects(const std::shared_ptr<owned_configuration_effect>& effect) {
    if (!dispatcher_thread() || !effect || !effect->current() || !effect->readback_applied ||
        !effect->readback_receipt || !effect->readback_receipt->current()) return false;
    if (effect->mode==0) {
      if (owned_input_) return retire_owned_configuration_off(effect);
      // Constructor/start is inert; absence of this once-installed input owner
      // is the original never-acquired lineage, not a generic zero counter.
      finish_owned_configuration_effect(effect,true);
      return true;
    }
    const auto previous=owned_input_;
    if (previous) previous->native_revoked_.store(true,std::memory_order_release);
    auto state=std::shared_ptr<owned_input_state>(new owned_input_state(effect,needs_prepare_virtual_hid_pointing_device()));
    owned_input_=state; // Strong custody precedes every native start operation.
    const auto scope=[state] { return state->native_current(); };
    if (!scope()) { refuse_owned_input(state); return false; }
    virtual_hid_devices_state_.set_virtual_hid_keyboard_ready(true);
    virtual_hid_devices_state_.set_virtual_hid_pointing_ready(
      state->pointing_ && state->pointing_->current());
    std::weak_ptr<device_grabber> weak(effect->cohort->device_);
    if (previous) {
      state->inventory_=previous->inventory_;
      if (!hid_manager_ || !hid_manager_->rebind_owned_input_scope(scope)) { refuse_owned_input(state); return false; }
      state->secure_=previous->secure_;
      state->tap_=previous->tap_;
      if (!state->inventory_ || !state->inventory_->current() || !secure_event_input_monitor_ ||
          !secure_event_input_monitor_->owned_started(state->secure_) || !event_tap_monitor_ ||
          !event_tap_monitor_->owned_started(state->tap_)) { refuse_owned_input(state); return false; }
    } else {
      if (!hid_manager_ || !secure_event_input_monitor_) { refuse_owned_input(state); return false; }
      hid_manager_->async_set_device_matched_delay(
        core_configuration_->get_selected_profile().get_parameters()->get_delay_milliseconds_before_open_device());
      if (!hid_manager_->async_owned_start(scope,[weak,state](auto receipt) {
        if (const auto device=weak.lock()) {
          if (device->owned_input_!=state) { device->refuse_owned_input(state); return; }
          if (!receipt) { device->refuse_owned_input(state); return; }
          state->inventory_=std::move(receipt);
          device->async_grab_devices();
          device->progress_owned_input();
        }
      })) { refuse_owned_input(state); return false; }
      if (!secure_event_input_monitor_->async_owned_start(scope,[weak,state](auto receipt) {
        if (const auto device=weak.lock()) {
          if (device->owned_input_!=state || !receipt) { device->refuse_owned_input(state); return; }
          state->secure_=std::move(receipt);
          device->progress_owned_input();
        }
      })) { refuse_owned_input(state); return false; }
      const bool desired=core_configuration_->get_global_configuration().get_enable_cgeventtap_fallback();
      // Initial OFF deferred the ordinary setup(false). An unchanged setting
      // still needs its first actual EventTap creation under this input owner.
      if (desired==cgeventtap_fallback_enabled_) setup_event_tap_monitor(desired);
      else set_cgeventtap_fallback_enabled(desired);
    }
    update_devices_disabled();
    async_grab_devices();
    enqueue_to_dispatcher([weak,state] {
      if (const auto device=weak.lock()) {
        if (device->owned_input_==state) device->progress_owned_input();
      }
    });
    return !state->refused_; // Pending only until actual source callbacks join.
  }

  bool apply_owned_configuration_request(const std::shared_ptr<configuration_request>& request) {
    const auto cohort=owned_cohort_.lock();
    if (!dispatcher_thread() || !cohort || !request || request->participant_!=cohort->capture_ ||
        !request->current() || !cohort->binding_admitted_ || cohort->requested_ ||
        cohort->configuration_retiring_ || configuration_effects_.size()>=2) return false;
    const auto revoked=complex_modifications_applied_event_queue_->get_manipulator_environment().get_variable(
        "ergopti_revoked_"+request->snapshot_->generation());
    const auto bit=revoked.get_if<int64_t>();
    if (!bit || *bit!=0) return false; // Permanent revocation is never written back to zero.
    auto effect=std::shared_ptr<owned_configuration_effect>(new owned_configuration_effect(cohort,request->snapshot_,request,
      std::make_shared<owned_work>(owned_work_),false,request->mode_,std::function<void(bool)>{}));
    configuration_effects_.push_back(effect);
    if (request->mode_==0) return resume_owned_configuration_request(request);
    bool admitted=false;
    try { admitted=prepare_owned_configuration_request(request); }
    catch (...) { finish_owned_configuration_effect(effect,false); throw; }
    if (!admitted) finish_owned_configuration_effect(effect,false);
    return admitted;
  }
  bool resume_owned_configuration_request(const std::shared_ptr<configuration_request>& request) {
    if (!dispatcher_thread() || !request || !request->current()) return false;
    std::shared_ptr<owned_configuration_effect> effect;
    for (const auto& candidate:configuration_effects_) if (candidate->request==request) effect=candidate;
    if (!effect || effect->queued || effect->finished) return false;
    if (effect->mode!=0) {
      effect->keyboard=effect->cohort->vhd_->ready(ergoptiplus::remap::vhd::initializer_kind::keyboard);
      if (needs_prepare_virtual_hid_pointing_device())
        effect->pointing=effect->cohort->vhd_->ready(ergoptiplus::remap::vhd::initializer_kind::pointing);
    }
    if (!effect->current()) { finish_owned_configuration_effect(effect,false); return false; }
    return queue_owned_configuration_effect(effect);
  }
  bool revoke_owned_configuration(const std::shared_ptr<active_cohort>& cohort,std::function<void(bool)> completion) {
    if (!dispatcher_thread() || !cohort || !cohort->same_owner() || !cohort->configuration_retiring_ ||
        !cohort->capture_->configuration_snapshot_ || !completion) return false;
    auto effect=std::shared_ptr<owned_configuration_effect>(new owned_configuration_effect(cohort,cohort->capture_->configuration_snapshot_,nullptr,
      std::make_shared<owned_work>(owned_work_),true,0,std::move(completion)));
    configuration_effects_.push_back(effect);
    return queue_owned_configuration_effect(effect);
  }
  bool queue_owned_configuration_effect(const std::shared_ptr<owned_configuration_effect>& effect) {
    if (!effect->current() || effect->queued) return false;
    if (owned_input_) owned_input_->output_revoked_.store(true,std::memory_order_release);
    virtual_hid_device_service_client_->bind_owned_report_scope([] { return false; });
    // Retain native resource owners, but close old output before any variable
    // mutation. The replacement opens only from actual input completion.
    post_event_to_virtual_devices_manipulator_->bind_owned_output_scope([] { return false; });
    effect->queued=true;
    bool accepted=true;
    const auto post=[this,effect](const std::string& name,int64_t value,unsigned bit) {
      manipulator_environment_variable_set_variable variable;
      variable.set_name(name);
      variable.set_value(manipulator_environment_variable_value(value));
      return async_post_set_variable_event(variable,effect,bit);
    };
    try {
      accepted=post("ergopti_mode_"+effect->snapshot->generation(),effect->mode,1);
      if (effect->revoke) accepted=post("ergopti_revoked_"+effect->snapshot->generation(),1,2) && accepted;
    } catch (...) { finish_owned_configuration_effect(effect,false); throw; }
    if (!accepted) finish_owned_configuration_effect(effect,false);
    return accepted;
  }
  bool retire_owned_configuration_off(const std::shared_ptr<owned_configuration_effect>& effect) {
    if (!dispatcher_thread() || !effect || effect->revoke || effect->mode!=0 || !effect->request ||
        !effect->readback_applied || !effect->activation_started || !effect->readback_receipt ||
        !effect->readback_receipt->current() || !effect->current() || effect->terminal_off) return false;
    const auto cohort=effect->cohort;
    if (cohort->configuration_retiring_ || cohort->configuration_off_) return false;
    cohort->configuration_retiring_=true;
    cohort->custody_=cohort;
    cohort->configuration_off_=effect;
    effect->terminal_off=true;
    effect->request->terminal_device_=cohort->device_; // Same genuine factory/participant.
    effect->request->native_revoked_.store(true,std::memory_order_release);
    cohort->capture_->configuration_closed_=true;
    // All mutation/readback work is finished. The actual readback callback's
    // local debt still lives until its body unwinds; frame custody is separate.
    effect->debt.reset();
    try {
      const bool accepted=revoke_owned_configuration(cohort,[cohort](bool applied) {
        if (!applied) cohort->failed_=true;
        cohort->begin_retirement_after_configuration();
      });
      if (!accepted && !cohort->requested_) { cohort->failed_=true; cohort->begin_retirement_after_configuration(); }
      return accepted && !cohort->failed_;
    } catch (...) {
      cohort->failed_=true;
      cohort->begin_retirement_after_configuration();
      return false;
    }
  }
  std::optional<active_cohort::terminal_receipt> owned_configuration_off_terminal(
      const std::shared_ptr<configuration_request>& request) const {
    const auto cohort=owned_cohort_.lock();
    if (!dispatcher_thread() || !cohort || !request || request->mode_!=0 ||
        !cohort->configuration_off_ || cohort->configuration_off_->request!=request ||
        !cohort->configuration_off_->terminal_off || !cohort->configuration_off_->readback_applied ||
        request->terminal_device_.get()!=this || request->participant_!=cohort->capture_ ||
        request->snapshot_!=cohort->capture_->configuration_snapshot_) return std::nullopt;
    return cohort->terminal(); // Genuine existing every-participant terminal predicate.
  }
  bool complete_owned_configuration_off(std::shared_ptr<owned_configuration_effect> effect,
                                        const active_cohort::terminal_receipt& terminal) {
    if (!effect || !effect->terminal_off || effect->finished || !terminal.current() ||
        !terminal.same_cohort(*effect->cohort) || effect->debt) return false;
    // Expired/refused sender custody is not a cleanup success for that mode
    // frame. It also cannot undo already-proved native participant retirement.
    effect->cohort->capture_->receiver_->finish_configuration_off(effect->request);
    effect->finished=true;
    configuration_effects_.erase(std::remove(configuration_effects_.begin(),configuration_effects_.end(),effect),configuration_effects_.end());
    effect->cohort->configuration_off_.reset();
    effect->request->terminal_device_.reset();
    return true;
  }
  void finish_owned_configuration_effect(const std::shared_ptr<owned_configuration_effect>& effect,bool applied) {
    if (effect->finished) return;
    const bool admitted=applied && effect->readback_applied && effect->current();
    effect->finished=true;
    auto completion=std::move(effect->completion);
    configuration_effects_.erase(std::remove(configuration_effects_.begin(),configuration_effects_.end(),effect),configuration_effects_.end());
    if (effect->revoke) {
      if (completion) completion(admitted);
    } else effect->cohort->capture_->receiver_->finish_configuration_effect(effect->request,admitted);
  }
  void observe_owned_configuration_effects() {
    const auto effects=configuration_effects_; // Callbacks may retire or replace the original pending request.
    for (const auto& effect:effects) {
      if (effect->finished || effect->readback || !effect->queued) continue;
      if (!effect->current()) { finish_owned_configuration_effect(effect,false); continue; }
      const unsigned expected=effect->revoke ? 3 : 1;
      if (effect->pushed!=expected || effect->applied!=expected) continue;
      effect->readback=true;
      try {
        const bool accepted=async_invoke_with_manipulator_environment([this,effect](const auto& environment) {
          const auto callback_debt=effect->debt;
          try {
            const auto mode=environment.get_variable("ergopti_mode_"+effect->snapshot->generation());
            const auto revoked=environment.get_variable("ergopti_revoked_"+effect->snapshot->generation());
            const auto actual_mode=mode.template get_if<int64_t>();
            const auto actual_revoked=revoked.template get_if<int64_t>();
            effect->readback_applied=effect->current() && actual_mode && *actual_mode==effect->mode &&
              actual_revoked && *actual_revoked==(effect->revoke ? 1 : 0);
            if (!effect->readback_applied || effect->revoke) {
              finish_owned_configuration_effect(effect,effect->readback_applied);
              return;
            }
            effect->readback_receipt=std::shared_ptr<const owned_configuration_readback>(new owned_configuration_readback(*effect));
            configuration_readback_=effect->readback_receipt;
            effect->activation_started=true;
            if (!complete_owned_configuration_input_effects(effect)) finish_owned_configuration_effect(effect,false);
          } catch (...) {
            owned_work_->failed=true;
            try { finish_owned_configuration_effect(effect,false); } catch (...) {}
          }
        });
        if (!accepted) finish_owned_configuration_effect(effect,false);
      } catch (...) {
        owned_work_->failed=true;
        try { finish_owned_configuration_effect(effect,false); } catch (...) {}
      }
    }
  }
  std::shared_ptr<owned_work_state> owned_work_=std::make_shared<owned_work_state>();
  std::weak_ptr<active_cohort> owned_cohort_;
  std::weak_ptr<hs274_stream_protocol::runtime::capture_participant> owned_constructor_participant_;
  bool owned_stopping_=false;
  const std::shared_ptr<const core_configuration::core_configuration::owned_configuration_snapshot> owned_configuration_snapshot_;
  bool owned_engine_prepared_=false, owned_engine_failed_=false;
  std::exception_ptr owned_engine_exception_;
  bool owned_configuration_current() const {
    if (!owned_configuration_snapshot_) return true;
    const auto participant=owned_constructor_participant_.lock();
    if (participant && participant->current() && owned_configuration_snapshot_->current() && !owned_engine_failed_)
      return true;
    if (const auto cohort=owned_cohort_.lock()) cohort->request_retirement();
    return false;
  }
  void prepare_owned_configuration_engine() {
    if (!owned_configuration_snapshot_ || owned_engine_prepared_ || owned_engine_failed_ ||
        !owned_configuration_current()) return;
    try {
      auto& profile=core_configuration_->get_selected_profile();
      manipulator_managers_connector_.set_manipulator_environment_core_configuration(core_configuration_);
      device_key_code_manipulator_manager_->update(profile);
      simple_modifications_manipulator_manager_->update(profile);
      fn_function_keys_manipulator_manager_->update(profile,system_preferences_properties_);
      complex_modifications_manipulator_manager_->invalidate_manipulators();
      for (const auto& rule:profile.get_complex_modifications()->get_rules()) {
        if (!rule->get_enabled()) continue;
        for (const auto& spec:rule->get_manipulators()) {
          auto manipulator=manipulator::manipulator_factory::make_manipulator(spec->to_json(),spec->get_parameters());
          for (const auto& condition:spec->get_conditions())
            manipulator->push_back_condition(manipulator::condition_factory::make_condition(condition.get_json()));
          complex_modifications_manipulator_manager_->push_back_manipulator(manipulator);
        }
      }
      if (!owned_configuration_current()) return;
      // Native variable callbacks and official readiness remain separate gates.
      owned_engine_prepared_=true;
    } catch (...) {
      owned_engine_failed_=true;
      owned_engine_exception_=std::current_exception();
      if (const auto cohort=owned_cohort_.lock()) cohort->request_retirement();
    }
  }
  static std::shared_ptr<active_cohort> preallocate_owned_cohort(
      const std::shared_ptr<ergoptiplus::remap::auth::console_control_owner>& console,
      const std::shared_ptr<hs274_stream_protocol::runtime::capture_participant>& capture) {
    if (!console || !capture || capture->published_ || capture->device_retention_ ||
        !capture->current() || !capture->console_->same_control(*console)) return nullptr;
    auto status=pqrs::karabiner::driverkit::virtual_hid_device_service::client::allocate_owned_status_slot(capture->broker_);
    if (!status) return nullptr;
    auto storage=std::shared_ptr<active_cohort>(new active_cohort(console,capture,std::move(status)));
    std::weak_ptr<active_cohort> weak(storage);
    // Function storage is allocated BEFORE publish/native construction; only
    // this private source factory lends the same aggregate's cleanup port.
    capture->request_aggregate_retirement_=[weak] {
      const auto original=weak.lock();
      return original && original->request_retirement();
    };
    return storage;
  }
  static bool bind_owned_cohort(const std::shared_ptr<active_cohort>& storage,
                                const std::shared_ptr<device_grabber>& device,
                                const std::shared_ptr<hs274_stream_protocol::runtime::capture_participant>& capture) noexcept {
    if (!storage || !device || !capture || storage->capture_!=capture ||
        device->owned_constructor_participant_.lock()!=capture) return false;
    if (storage->device_) return storage->device_==device && storage->binding_admitted_;
    if (capture->device_retention_ && capture->device_retention_!=device) return false;
    // These shared-pointer assignments do not allocate. Capture actual cleanup
    // custody before any validation; refusal must never orphan this constructor.
    storage->device_=device;
    capture->device_retention_=device;
    device->owned_cohort_=storage;
    storage->custody_=storage;
    try {
      if (!device->virtual_hid_device_service_client_->bind_owned_status_slot(
            device->virtual_hid_device_service_client_,storage->vhd_)) return false;
      if (!device->dispatcher_thread() || device->owned_stopping_ || !device->entries_.empty() ||
          !capture->published_ || !capture->current() || !storage->console_->current()) return false;
      const auto peer=device->weak_console_user_server_peer_.lock();
      if (!peer || !peer->owned_control() || !peer->owned_control()->same_control(*storage->console_)) return false;
      storage->binding_admitted_=true;
      return device->bind_owned_configuration();
    } catch (...) { return false; }
  }
public:

public:
  // Signals (invoked from the shared dispatcher thread)

  nod::signal<void()> connected_devices_changed;
  nod::signal<void(const std::string&)> notification_message_changed;

  device_grabber(const device_grabber&) = delete;

  device_grabber(std::weak_ptr<console_user_server_peer> weak_console_user_server_peer,
                 std::weak_ptr<core_service_daemon_state_manager> weak_core_service_daemon_state_manager)
      : device_grabber(weak_console_user_server_peer,weak_core_service_daemon_state_manager,
          [] { return ergoptiplus::remap::vhd::broker_owner::acquire(); }) {}

private:
  class owned_constructor_key final {
    friend class device_grabber;
    const std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> broker_;
    const std::shared_ptr<core_configuration::core_configuration> configuration_;
    const std::shared_ptr<const core_configuration::core_configuration::owned_configuration_snapshot> snapshot_;
    owned_constructor_key(std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> broker,
                          std::shared_ptr<core_configuration::core_configuration> configuration,
                          std::shared_ptr<const core_configuration::core_configuration::owned_configuration_snapshot> snapshot)
      :broker_(std::move(broker)),configuration_(std::move(configuration)),snapshot_(std::move(snapshot)) {}
  public:
    owned_constructor_key(const owned_constructor_key&)=delete;
    ~owned_constructor_key()=default;
  };
public:
  // The public signature is required by make_shared. Its key is private and
  // can only be minted by the original participant's private factory.
  device_grabber(const owned_constructor_key& key,
                 std::weak_ptr<console_user_server_peer> peer,
                 std::weak_ptr<core_service_daemon_state_manager> state)
    :device_grabber(peer,state,[broker=key.broker_] { return broker; },
                   [configuration=key.configuration_] { return configuration; },key.snapshot_) {}
private:
  static std::shared_ptr<device_grabber> construct_owned_device(
      std::weak_ptr<console_user_server_peer> peer,
      std::weak_ptr<core_service_daemon_state_manager> state,
      const std::shared_ptr<hs274_stream_protocol::runtime::capture_participant>& participant,
      const std::shared_ptr<active_cohort>& storage) {
    if (!storage || storage->capture_!=participant || storage->device_ ||
        !participant || !participant->current() || !participant->published_ ||
        !participant->broker_initialized_ || !participant->broker_ || participant->device_retention_)
      throw std::logic_error("Device construction lacks original retained native lineage");
    const auto broker=participant->broker_;
    if (!participant->configuration_ || !participant->configuration_->file_current())
      throw std::logic_error("Device construction lacks native configuration custody");
    const core_configuration::core_configuration::owned_snapshot_key configuration_key(participant->configuration_);
    auto configuration=std::make_shared<core_configuration::core_configuration>(configuration_key);
    auto snapshot=configuration->retain_owned_configuration_snapshot();
    if (!snapshot || !snapshot->current())
      throw std::logic_error("Device construction lacks genuine parsed native configuration");
    const owned_constructor_key key(broker,std::move(configuration),std::move(snapshot));
    // make_shared allocates the object and its control block BEFORE invoking
    // any native constructor. A control-block refusal cannot delete an
    // unretained successfully constructed native participant.
    auto device=std::make_shared<device_grabber>(key,peer,state);
    device->owned_constructor_participant_=participant;
    // Even refused admission retains the constructed object for real cleanup.
    // No allocation or exception can escape this binding step.
    (void)bind_owned_cohort(storage,device,participant);
    return device;
  }
  device_grabber(std::weak_ptr<console_user_server_peer> weak_console_user_server_peer,
                 std::weak_ptr<core_service_daemon_state_manager> weak_core_service_daemon_state_manager,
                 std::function<std::shared_ptr<ergoptiplus::remap::vhd::broker_owner>()> constructor_broker)
      : device_grabber(weak_console_user_server_peer,weak_core_service_daemon_state_manager,
                       std::move(constructor_broker),
                       [] { return std::make_shared<core_configuration::core_configuration>(); },nullptr) {}
  device_grabber(std::weak_ptr<console_user_server_peer> weak_console_user_server_peer,
                 std::weak_ptr<core_service_daemon_state_manager> weak_core_service_daemon_state_manager,
                 std::function<std::shared_ptr<ergoptiplus::remap::vhd::broker_owner>()> constructor_broker,
                 std::function<std::shared_ptr<core_configuration::core_configuration>()> constructor_configuration,
                 std::shared_ptr<const core_configuration::core_configuration::owned_configuration_snapshot> snapshot)
      : dispatcher_client(),
        owned_configuration_snapshot_(std::move(snapshot)),
        weak_console_user_server_peer_(weak_console_user_server_peer),
        weak_core_service_daemon_state_manager_(weak_core_service_daemon_state_manager),
        core_configuration_(constructor_configuration()),
        logger_unique_filter_(logger::get_logger()) {
    notification_message_manager_ = std::make_shared<notification_message_manager>();

    notification_message_manager_->notification_message_changed.connect(
        [this](const auto& notification_message) {
          notification_message_changed(notification_message);
        });

    // Apply per-device key-code swaps through basic manipulators rather than
    // rewriting events when they are added to the queue. A basic manipulator
    // retains the mapping selected at key_down until the corresponding key_up,
    // even if the configuration is updated while the key is held.
    device_key_code_manipulator_manager_ = std::make_shared<device_grabber_details::device_key_code_manipulator_manager>();
    simple_modifications_manipulator_manager_ = std::make_shared<device_grabber_details::simple_modifications_manipulator_manager>();
    complex_modifications_manipulator_manager_ = std::make_shared<manipulator::manipulator_manager>();
    fn_function_keys_manipulator_manager_ = std::make_shared<device_grabber_details::fn_function_keys_manipulator_manager>();
    post_event_to_virtual_devices_manipulator_manager_ = std::make_shared<manipulator::manipulator_manager>();

    merged_input_event_queue_ = std::make_shared<event_queue::queue>();
    device_key_code_manipulated_event_queue_ = std::make_shared<event_queue::queue>();
    simple_modifications_applied_event_queue_ = std::make_shared<event_queue::queue>();
    complex_modifications_applied_event_queue_ = std::make_shared<event_queue::queue>();
    fn_function_keys_applied_event_queue_ = std::make_shared<event_queue::queue>();
    posted_event_queue_ = std::make_shared<event_queue::queue>();

    //
    // virtual_hid_device_service_client_
    //

    virtual_hid_device_service_client_ = std::make_shared<pqrs::karabiner::driverkit::virtual_hid_device_service::client>(constructor_broker());

    virtual_hid_device_service_client_->connected.connect([this, weak_core_service_daemon_state_manager] {
      logger::get_logger()->debug("virtual_hid_device_service_client_ connected");

      if (auto m = weak_core_service_daemon_state_manager.lock()) {
        m->set_virtual_hid_device_service_client_connected(true);
      }

      if (owned_configuration_snapshot_) {
        if (!retained_owned_preparation_effect()) { refuse_owned_configuration_preparation(); return; }
        update_virtual_hid_keyboard();
        update_virtual_hid_pointing();
        progress_owned_configuration_preparation();
        return;
      }
      update_virtual_hid_keyboard();
      update_virtual_hid_pointing();

      update_devices_disabled();
      async_grab_devices();
    });

    virtual_hid_device_service_client_->connect_failed.connect([weak_core_service_daemon_state_manager](auto&& error_code) {
      logger::get_logger()->debug("virtual_hid_device_service_client_ connect_failed: {0}", error_code.message());

      if (auto m = weak_core_service_daemon_state_manager.lock()) {
        m->set_virtual_hid_device_service_client_connected(false);
      }
    });

    virtual_hid_device_service_client_->closed.connect([weak_core_service_daemon_state_manager] {
      logger::get_logger()->debug("virtual_hid_device_service_client_ closed");

      if (auto m = weak_core_service_daemon_state_manager.lock()) {
        m->set_virtual_hid_device_service_client_connected(false);
      }

      // Wait automatic reconnection.
      //
      // Note:
      // The following callback will be signaled by virtual_hid_device_service::client.
      // - `virtual_hid_keyboard_ready_response(false)`
      // - `virtual_hid_pointing_ready_response(false)`
    });

    virtual_hid_device_service_client_->error_occurred.connect([](auto&& error_code) {
      logger::get_logger()->debug("virtual_hid_device_service_client_ error_occurred: {0}", error_code.message());
    });

    virtual_hid_device_service_client_->driver_activated.connect([weak_core_service_daemon_state_manager](auto&& driver_activated) {
      if (auto m = weak_core_service_daemon_state_manager.lock()) {
        m->set_driver_activated(driver_activated);
      }
    });

    virtual_hid_device_service_client_->driver_connected.connect([weak_core_service_daemon_state_manager](auto&& driver_connected) {
      if (auto m = weak_core_service_daemon_state_manager.lock()) {
        m->set_driver_connected(driver_connected);
      }
    });

    virtual_hid_device_service_client_->driver_version_mismatched.connect([weak_core_service_daemon_state_manager](auto&& driver_version_mismatched) {
      if (auto m = weak_core_service_daemon_state_manager.lock()) {
        m->set_driver_version_mismatched(driver_version_mismatched);
      }
    });

    virtual_hid_device_service_client_->virtual_hid_keyboard_ready.connect([this, weak_core_service_daemon_state_manager](auto&& ready) {
      if (owned_configuration_snapshot_) {
        progress_owned_configuration_preparation();
        return;
      }
      if (virtual_hid_devices_state_.get_virtual_hid_keyboard_ready() != ready) {
        logger::get_logger()->info("virtual_hid_device_service_client_ virtual_hid_keyboard_ready_response: {0}", ready);

        virtual_hid_devices_state_.set_virtual_hid_keyboard_ready(ready);
        async_post_virtual_hid_devices_state_changed_event();

        if (auto m = weak_core_service_daemon_state_manager.lock()) {
          m->set_virtual_hid_keyboard_ready(ready);
        }

        // The virtual_hid_keyboard might have been terminated or become unavailable.
        // We try to reinitialize the device.
        if (!ready) {
          if (post_event_to_virtual_devices_manipulator_) {
            post_event_to_virtual_devices_manipulator_->clear_virtual_hid_keyboard_pressed_keys();
          }
          virtual_hid_device_service_client_->async_virtual_hid_keyboard_terminate();
          update_virtual_hid_keyboard();
        }

        update_devices_disabled();
        async_grab_devices();
      }
    });

    virtual_hid_device_service_client_->virtual_hid_pointing_ready.connect([this](auto&& ready) {
      if (owned_configuration_snapshot_) {
        progress_owned_configuration_preparation();
        return;
      }
      if (virtual_hid_devices_state_.get_virtual_hid_pointing_ready() != ready) {
        logger::get_logger()->info("virtual_hid_device_service_client_ virtual_hid_pointing_ready_response: {0}", ready);

        virtual_hid_devices_state_.set_virtual_hid_pointing_ready(ready);
        async_post_virtual_hid_devices_state_changed_event();

        // The virtual_hid_pointing might have been terminated or become unavailable.
        // We try to reinitialize the device.
        if (!ready) {
          virtual_hid_device_service_client_->async_virtual_hid_pointing_terminate();
          update_virtual_hid_pointing();
        }

        update_devices_disabled();
        async_grab_devices();
      }
    });

    post_event_to_virtual_devices_manipulator_ =
        std::make_shared<manipulator::manipulators::post_event_to_virtual_devices::post_event_to_virtual_devices>(
            weak_console_user_server_peer_,
            notification_message_manager_);
    post_event_to_virtual_devices_manipulator_->set_cgeventtap_fallback_enabled(cgeventtap_fallback_enabled_);
    post_event_to_virtual_devices_manipulator_->set_sleep_shortcut_delay(
        std::chrono::milliseconds(core_configuration_->get_global_configuration().get_delay_milliseconds_before_sleep_shortcut()));
    post_event_to_virtual_devices_manipulator_manager_->push_back_manipulator(std::shared_ptr<manipulator::manipulators::base>(post_event_to_virtual_devices_manipulator_));

    // Connect manipulator_managers

    manipulator_managers_connector_.emplace_back_connection(pqrs::make_weak(device_key_code_manipulator_manager_->get_manipulator_manager()),
                                                            merged_input_event_queue_,
                                                            device_key_code_manipulated_event_queue_);
    manipulator_managers_connector_.emplace_back_connection(pqrs::make_weak(simple_modifications_manipulator_manager_->get_manipulator_manager()),
                                                            simple_modifications_applied_event_queue_);
    manipulator_managers_connector_.emplace_back_connection(complex_modifications_manipulator_manager_,
                                                            complex_modifications_applied_event_queue_);
    manipulator_managers_connector_.emplace_back_connection(pqrs::make_weak(fn_function_keys_manipulator_manager_->get_manipulator_manager()),
                                                            fn_function_keys_applied_event_queue_);
    manipulator_managers_connector_.emplace_back_connection(post_event_to_virtual_devices_manipulator_manager_,
                                                            posted_event_queue_);

    external_signal_connections_.emplace_back(
        krbn_notification_center::get_instance().input_event_arrived.connect([this] {
          manipulate(pqrs::osx::chrono::mach_absolute_time_point());
        }));

    // hid_manager_

    std::vector<pqrs::cf::cf_ptr<CFDictionaryRef>> matching_dictionaries{
        pqrs::osx::iokit_hid_manager::make_matching_dictionary(
            pqrs::hid::usage_page::generic_desktop,
            pqrs::hid::usage::generic_desktop::keyboard),

        pqrs::osx::iokit_hid_manager::make_matching_dictionary(
            pqrs::hid::usage_page::generic_desktop,
            pqrs::hid::usage::generic_desktop::mouse),

        pqrs::osx::iokit_hid_manager::make_matching_dictionary(
            pqrs::hid::usage_page::generic_desktop,
            pqrs::hid::usage::generic_desktop::pointer),

        pqrs::osx::iokit_hid_manager::make_matching_dictionary(
            pqrs::hid::usage_page::generic_desktop,
            pqrs::hid::usage::generic_desktop::joystick),

        pqrs::osx::iokit_hid_manager::make_matching_dictionary(
            pqrs::hid::usage_page::generic_desktop,
            pqrs::hid::usage::generic_desktop::game_pad),

        // Headset
        pqrs::osx::iokit_hid_manager::make_matching_dictionary(
            pqrs::hid::usage_page::consumer,
            pqrs::hid::usage::consumer::consumer_control),

        // Special devices (e.g., VEC USB Footpedal INFINITY USB-3)
        pqrs::osx::iokit_hid_manager::make_matching_dictionary(
            pqrs::hid::usage_page::consumer,
            pqrs::hid::usage::consumer::programmable_buttons),
    };

    hid_manager_ = std::make_unique<pqrs::osx::iokit_hid_manager>(weak_dispatcher_,
                                                                  pqrs::cf::run_loop_thread::extra::get_shared_run_loop_thread(),
                                                                  matching_dictionaries,
                                                                  std::chrono::milliseconds(1000));

    hid_manager_->ergopti_inventory_changed.connect([this](const auto& native_ids, bool settled, bool failed) {
      std::vector<std::uint64_t> selected;
      try {
        if (settled && !failed) {
          for (auto identity : native_ids) {
          const auto it = entries_.find(make_device_id(identity));
          if (it == entries_.end()) { failed = true; break; }
          if (type_safe::get(it->second->get_device_properties()->get_device_id()) != type_safe::get(identity)) { failed = true; break; }
          if (!it->second->get_device_properties()->get_device_identifiers().get_is_virtual_device())
            selected.push_back(type_safe::get(it->second->get_device_properties()->get_device_id()));
          }
        }
      } catch (...) { failed = true; }
      hs274_inventory_.publish(selected, settled, failed);
    });

    hid_manager_->device_matched.connect([this](auto&& registry_entry_id, auto&& device_ptr) {
      if (owned_stopping_) return;
      if (device_ptr) {
        auto device_id = make_device_id(registry_entry_id);

        //
        // entries_
        //

        pqrs::not_null_shared_ptr_t<device_grabber_details::entry> entry =
            std::make_shared<device_grabber_details::entry>(device_id,
                                                            *device_ptr,
                                                            core_configuration_);
        entries_.insert_or_assign(device_id,
                                  entry);
        if (const auto owned=owned_cohort_.lock()) {
          if (!owned->retain_monitor(entry->get_hid_device_events_monitor())) {
            owned->failed_=true;
            owned_stopping_=true;
            owned->request_retirement();
            return;
          }
        }

        connected_devices_changed();

        entry->set_temporarily_ignore(
            temporarily_ignored_device_ids_.contains(device_id));

        entry->hid_values_arrived.connect([this](auto&& entry,
                                                 auto&& event_queue_entries) {
          hid_values_arrived(entry,
                             event_queue_entries);
        });

        entry->get_hid_device_events_monitor()->started.connect([this, device_id] {
          if (auto it = entries_.find(device_id);
              it != entries_.end()) {
            logger::get_logger()->info("{0} hid device events monitor is started ({1}).",
                                       it->second->get_device_name(),
                                       it->second->seized() ? "grabbed" : "observed");
            logger_unique_filter_.reset();

            post_device_grabbed_event(it->second->get_device_properties());

            update_caps_lock_led();

            update_virtual_hid_pointing();
            if (owned_configuration_snapshot_) progress_owned_input();
          }
        });

        entry->get_hid_device_events_monitor()->stopped.connect([this, device_id] {
          if (auto it = entries_.find(device_id);
              it != entries_.end()) {
            logger::get_logger()->info("{0} hid device events monitor is stopped.",
                                       it->second->get_device_name());
            logger_unique_filter_.reset();

            physical_pressed_momentary_switch_events_.erase(device_id);
            post_device_ungrabbed_event(device_id);

            update_virtual_hid_pointing();
          }
        });

        entry->get_hid_device_events_monitor()->error_occurred.connect([](auto&& message, auto&& kr) {
          if (kr.not_permitted()) {
            logger::get_logger()->warn("hid_device_events_monitor not_permitted error");
            process_lifecycle_manager::async_request_termination();
          }
        });

        // ----------------------------------------

        update_virtual_hid_pointing();

        // ----------------------------------------

        update_devices_disabled();
        async_grab_devices();
      }
    });

    hid_manager_->device_terminated.connect([this](auto&& registry_entry_id) {
      auto device_id = make_device_id(registry_entry_id);

      // entries_

      {
        if (auto it = entries_.find(device_id);
            it != entries_.end()) {
          logger::get_logger()->info("{0} is terminated.",
                                     it->second->get_device_name());
          logger_unique_filter_.reset();

          entries_.erase(it);
          connected_devices_changed();
        }
      }

      //
      // Unregister device
      //

      physical_pressed_momentary_switch_events_.erase(device_id);
      hat_switch_converter::get_global_hat_switch_converter()->erase_device(device_id);

      // ----------------------------------------

      post_device_ungrabbed_event(device_id);

      update_virtual_hid_pointing();

      // ----------------------------------------
      update_devices_disabled();
      async_grab_devices();
    });

    hid_manager_->error_occurred.connect([this](auto&& message, auto&& kern_return) {
      logger::get_logger()->error("{0}: {1}", message, kern_return.to_string());
      logger_unique_filter_.reset();
      if (owned_input_) refuse_owned_input(owned_input_);
    });

    //
    // secure_event_input_monitor_
    //

    secure_event_input_monitor_ = std::make_unique<pqrs::osx::hitoolbox::secure_event_input_monitor>(weak_dispatcher_,
                                                                                                     std::chrono::milliseconds(50));
    secure_event_input_monitor_->secure_event_input_enabled_changed.connect([this](auto&& enabled) {
      // For devices opened via IOHIDDeviceOpen, we can still receive events even when secure event input is enabled
      // (for example, when sudo or System Settings is prompting for a password).
      //
      // With CGEventTap, however, we cannot receive events while secure event input is active.
      // As a result, for keys that were pressed before entering secure event input, we cannot receive key_up,
      // and key repeat can continue unexpectedly.
      //
      // Therefore, when using CGEventTap, we must release all keys pressed on the virtual device
      // when secure event input becomes enabled.

      if (!cgeventtap_fallback_enabled_) {
        return;
      }

      if (enabled) {
        logger::get_logger()->info("secure event input is enabled: release all pressed keys");
        post_device_keys_and_pointing_buttons_are_released_event();
        physical_pressed_momentary_switch_events_.clear();

        if (post_event_to_virtual_devices_manipulator_) {
          post_event_to_virtual_devices_manipulator_->get_key_event_dispatcher().clear_pressed_modifier_flags();

          post_event_to_virtual_devices_manipulator_->async_release_virtual_hid_keyboard_pressed_keys(
              virtual_hid_device_service_client_);
        }
      }
    });
  }

public:
  ~device_grabber() override {
    detach_from_dispatcher([this] {
      // Invalidate callbacks from an event_tap_monitor that is still stopping.
      event_tap_monitor_lifetime_ = nullptr;
      pending_event_tap_monitor_configuration_ = std::nullopt;

      stop();

      hs274_inventory_.retire();
      hid_manager_ = nullptr;

      external_signal_connections_.clear();

      post_event_to_virtual_devices_manipulator_ = nullptr;

      device_key_code_manipulator_manager_ = nullptr;
      simple_modifications_manipulator_manager_ = nullptr;
      complex_modifications_manipulator_manager_ = nullptr;
      fn_function_keys_manipulator_manager_ = nullptr;
      post_event_to_virtual_devices_manipulator_manager_ = nullptr;
      virtual_hid_device_service_client_ = nullptr;
      secure_event_input_monitor_ = nullptr;

      notification_message_manager_ = nullptr;

      hat_switch_converter::get_global_hat_switch_converter()->clear();
    });
  }

  void async_start(const std::optional<std::string>& user_core_configuration_file_path,
                   std::optional<uid_t> expected_user_core_configuration_file_owner) {
    if (owned_configuration_snapshot_) {
      enqueue_to_dispatcher([this] { prepare_owned_configuration_engine(); });
      return;
    }
    enqueue_to_dispatcher([this,
                           user_core_configuration_file_path,
                           expected_user_core_configuration_file_owner] {
      // We should call CGEventTapCreate after user is logged in.
      // So, we create event_tap_monitor here.
      setup_event_tap_monitor(false);

      configuration_monitor_ = std::make_unique<configuration_monitor>(user_core_configuration_file_path,
                                                                       expected_user_core_configuration_file_owner.value_or(uid_t(0)),
                                                                       krbn::core_configuration::error_handling::loose);

      configuration_monitor_->parse_error_message_changed.connect([this](auto&& parse_error_message) {
        if (auto m = weak_core_service_daemon_state_manager_.lock()) {
          m->set_karabiner_json_parse_error_message(parse_error_message);
        }
      });

      configuration_monitor_->load_state_changed.connect([this](auto load_state) {
        if (auto m = weak_core_service_daemon_state_manager_.lock()) {
          m->set_karabiner_json_permission_error(
              load_state == core_configuration::core_configuration::load_state::permission_error);
        }
      });

      configuration_monitor_->core_configuration_updated.connect([this](auto&& weak_core_configuration) {
        if (auto core_configuration = weak_core_configuration.lock()) {
          core_configuration_ = core_configuration;

          auto using_system_core_configuration =
              core_configuration_->get_source() == core_configuration::core_configuration::source::system_file;

          // If an old core_configuration is stored in system_file,
          // Settings is opened to show an alert when the user logs in.
          // However, the configuration is then loaded from user_file in the new format, and the alert disappears.
          // From the user's perspective, Settings opens unnecessarily after login in this case,
          // so configuration errors in system_file should not be reflected in settings_window_guidance or trigger opening Settings.
          if (auto m = weak_core_service_daemon_state_manager_.lock()) {
            m->set_virtual_hid_keyboard_type_not_set(
                !using_system_core_configuration &&
                core_configuration_->get_selected_profile().get_virtual_hid_keyboard()->get_keyboard_type_v2().empty());
          }

          for (auto&& entry : entries_ | std::views::values) {
            entry->set_core_configuration(core_configuration);
          }

          manipulator_managers_connector_.set_manipulator_environment_core_configuration(core_configuration);

          logger_unique_filter_.reset();

          if (auto console_user_server_peer = weak_console_user_server_peer_.lock()) {
            //
            // Check for updates
            //

            console_user_server_peer->async_check_for_updates(
                core_configuration_->get_global_configuration().get_check_for_updates());
          }

          //
          // Reflect profile changes
          //

          auto& profile = core_configuration_->get_selected_profile();

          set_cgeventtap_fallback_enabled(core_configuration_->get_global_configuration().get_enable_cgeventtap_fallback());

          if (post_event_to_virtual_devices_manipulator_) {
            post_event_to_virtual_devices_manipulator_->set_sleep_shortcut_delay(
                std::chrono::milliseconds(core_configuration_->get_global_configuration().get_delay_milliseconds_before_sleep_shortcut()));
          }

          if (hid_manager_) {
            hid_manager_->async_set_device_matched_delay(
                profile.get_parameters()->get_delay_milliseconds_before_open_device());
            hid_manager_->async_start();
          }

          device_key_code_manipulator_manager_->update(profile);
          simple_modifications_manipulator_manager_->update(profile);
          fn_function_keys_manipulator_manager_->update(profile,
                                                        system_preferences_properties_);
          update_complex_modifications_manipulators();

          update_virtual_hid_keyboard();
          update_virtual_hid_pointing();

          update_devices_disabled();
          async_grab_devices();
          async_post_system_preferences_properties_changed_event();
        }
      });

      configuration_monitor_->async_start();

      virtual_hid_device_service_client_->async_start();

      secure_event_input_monitor_->async_start();
    });
  }

  void async_grab_devices() {
    enqueue_to_dispatcher([this] {
      if (owned_stopping_ || !owned_configuration_current()) return;
      for (auto&& entry : entries_ | std::views::values) {
        grab_device(*entry);
      }
    });
  }

  void async_set_temporarily_ignored_device_ids(const std::unordered_set<device_id>& device_ids) {
    enqueue_to_dispatcher([this, device_ids] {
      temporarily_ignored_device_ids_ = device_ids;

      for (const auto& [device_id, entry] : entries_) {
        entry->set_temporarily_ignore(device_ids.contains(device_id));
      }

      async_grab_devices();
    });
  }

  void async_set_system_preferences_properties(const pqrs::osx::system_preferences::properties& value) {
    enqueue_to_dispatcher([this, value] {
      system_preferences_properties_ = value;

      fn_function_keys_manipulator_manager_->update(core_configuration_->get_selected_profile(),
                                                    system_preferences_properties_);
      async_post_system_preferences_properties_changed_event();
    });
  }

  bool async_post_set_variable_event(const manipulator_environment_variable_set_variable& value,
      const std::shared_ptr<owned_configuration_effect>& effect={},unsigned effect_bit=0) {
    return enqueue_to_dispatcher([this, value, effect, effect_bit] {
      if (effect && !effect->current()) { finish_owned_configuration_effect(effect,false); return; }
      auto event = event_queue::event::make_set_variable_event(value);
      if (effect) {
        std::weak_ptr<owned_configuration_effect> weak(effect);
        event.owned_variable_application_=std::shared_ptr<event_queue::event::owned_variable_application>(
          new event_queue::event::owned_variable_application(complex_modifications_applied_event_queue_.get(),[weak,effect_bit] {
            if (const auto original=weak.lock()) original->applied|=effect_bit;
          },[weak] {
            const auto original=weak.lock();
            return original && original->current();
          }));
      }

      for (const auto& t : {event_type::key_down, event_type::key_up}) {
        event_queue::entry entry(device_id(0),
                                 event_queue::event_time_stamp(pqrs::osx::chrono::mach_absolute_time_point()),
                                 event,
                                 t,
                                 std::nullopt,
                                 event,
                                 event_queue::state::virtual_event);
        merged_input_event_queue_->push_back_entry(entry);
      }

      if (effect) effect->pushed|=effect_bit;
      krbn_notification_center::get_instance().enqueue_input_event_arrived(*this);
    });
  }

  void async_post_frontmost_application_changed_event(const application& application) {
    enqueue_to_dispatcher([this, application] {
      auto event = event_queue::event::make_frontmost_application_changed_event(application);
      event_queue::entry entry(device_id(0),
                               event_queue::event_time_stamp(pqrs::osx::chrono::mach_absolute_time_point()),
                               event,
                               event_type::single,
                               std::nullopt,
                               event,
                               event_queue::state::virtual_event);

      merged_input_event_queue_->push_back_entry(entry);

      krbn_notification_center::get_instance().enqueue_input_event_arrived(*this);
    });
  }

  void async_post_input_source_changed_event(const pqrs::osx::input_source::properties& properties) {
    enqueue_to_dispatcher([this, properties] {
      auto event = event_queue::event::make_input_source_changed_event(properties);
      event_queue::entry entry(device_id(0),
                               event_queue::event_time_stamp(pqrs::osx::chrono::mach_absolute_time_point()),
                               event,
                               event_type::single,
                               std::nullopt,
                               event,
                               event_queue::state::virtual_event);

      merged_input_event_queue_->push_back_entry(entry);

      krbn_notification_center::get_instance().enqueue_input_event_arrived(*this);
    });
  }

  void async_post_system_preferences_properties_changed_event() {
    enqueue_to_dispatcher([this] {
      auto event = event_queue::event::make_system_preferences_properties_changed_event(
          system_preferences_properties_);
      event_queue::entry entry(device_id(0),
                               event_queue::event_time_stamp(pqrs::osx::chrono::mach_absolute_time_point()),
                               event,
                               event_type::single,
                               std::nullopt,
                               event,
                               event_queue::state::virtual_event);

      merged_input_event_queue_->push_back_entry(entry);

      krbn_notification_center::get_instance().enqueue_input_event_arrived(*this);
    });
  }

  void async_post_virtual_hid_devices_state_changed_event() {
    enqueue_to_dispatcher([this] {
      auto event = event_queue::event::make_virtual_hid_devices_state_changed_event(virtual_hid_devices_state_);
      event_queue::entry entry(device_id(0),
                               event_queue::event_time_stamp(pqrs::osx::chrono::mach_absolute_time_point()),
                               event,
                               event_type::single,
                               std::nullopt,
                               event,
                               event_queue::state::virtual_event);

      merged_input_event_queue_->push_back_entry(entry);

      krbn_notification_center::get_instance().enqueue_input_event_arrived(*this);
    });
  }

  bool async_invoke_with_manipulator_environment(std::function<void(const manipulator::manipulator_environment&)> function) const {
    return enqueue_to_dispatcher([this, function] {
      function(complex_modifications_applied_event_queue_->get_manipulator_environment());
    });
  }

  void async_invoke_with_connected_devices(std::function<void(const nlohmann::json&)> function) const {
    enqueue_to_dispatcher([this, function] {
      connected_devices connected_devices;
      for (const auto& entry : entries_ | std::views::values) {
        connected_devices.push_back_device(entry->get_device_properties());
      }

      function(nlohmann::json(connected_devices));
    });
  }

  void async_invoke_with_notification_message(std::function<void(const std::string&)> function) const {
    enqueue_to_dispatcher([this, function] {
      function(notification_message_manager_->get_full_message());
    });
  }

private:
  void stop() {
    configuration_monitor_ = nullptr;

    enqueue_to_dispatcher([this] {
      for (auto&& entry : entries_ | std::views::values) {
        entry->get_hid_device_events_monitor()->async_stop();
      }

      logger::get_logger()->info("Connected devices are ungrabbed");
    });

    async_stop_event_tap_monitor();

    virtual_hid_device_service_client_->async_stop();

    secure_event_input_monitor_->async_stop();
  }

  bool owned_input_effects_current() const {
    const auto state=owned_input_;
    const auto cohort=owned_cohort_.lock();
    return dispatcher_thread() && !owned_stopping_ && state && state->completed_ &&
      !state->refused_ && cohort && cohort->same_owner() && !cohort->requested_ &&
      !cohort->configuration_retiring_ && !cohort->capture_->configuration_pending_ &&
      state->native_current() && state->readback_ && state->readback_->current();
  }
  void retain_owned_configuration_inputs() {
    const auto target=complex_modifications_applied_event_queue_.get();
    for (const auto& queue : {merged_input_event_queue_,device_key_code_manipulated_event_queue_,
          simple_modifications_applied_event_queue_,complex_modifications_applied_event_queue_,
          fn_function_keys_applied_event_queue_,posted_event_queue_})
      queue->retain_owned_variable_inputs_for(target);
  }
  // This method is executed in the shared dispatcher thread.
  void manipulate(absolute_time_point now) {
    if (owned_stopping_) return;
    if (owned_configuration_snapshot_ && !owned_input_effects_current()) {
      retain_owned_configuration_inputs();
      post_event_to_virtual_devices_manipulator_->bind_owned_output_scope([] { return false; });
    }
    manipulator_managers_connector_.manipulate(now,
                                               core_configuration_);
    observe_owned_configuration_effects();

    posted_event_queue_->clear_events();
    if (!owned_configuration_snapshot_ || owned_input_effects_current())
      post_event_to_virtual_devices_manipulator_->async_post_events(virtual_hid_device_service_client_);

    if (auto min = manipulator_managers_connector_.min_input_event_time_stamp()) {
      auto when = when_now();
      if (now < *min) {
        when += pqrs::osx::chrono::make_milliseconds(*min - now);
      }

      enqueue_to_dispatcher(
          [this, min, debt=std::make_shared<owned_work>(owned_work_)] {
            manipulate(*min);
          },
          when);
    }
  }

  // This method is executed in the shared dispatcher thread.
  void hid_values_arrived(device_grabber_details::entry& entry,
                          event_queue::not_null_entries_ptr_t event_queue_entries) {
    if (entry.get_device_properties()->get_device_identifiers().get_is_virtual_device()) {
      // Handle caps_lock_state_changed event only if the hid is Karabiner-DriverKit-VirtualHIDDevice.
      for (const auto& e : *event_queue_entries) {
        if (e->get_event().get_type() == event_queue::event::type::caps_lock_state_changed) {
          if (auto state = e->get_event().get_integer_value()) {
            last_caps_lock_state_ = *state;
            post_caps_lock_state_changed_event(*state);
            update_caps_lock_led();
          }
        }
      }
    } else {
      // Manipulate events

      bool notify = false;

      for (const auto& e : *event_queue_entries) {
        if (!entry.get_disabled() && entry.seized()) {
          if (unbalanced_momentary_switch_event(e->get_device_id(),
                                                e->get_event(),
                                                e->get_event_type())) {
            continue;
          }

          event_queue::entry qe(e->get_device_id(),
                                e->get_event_time_stamp(),
                                e->get_event(),
                                e->get_event_type(),
                                e->get_event_integer_value(),
                                e->get_original_event(),
                                e->get_state());

          merged_input_event_queue_->push_back_entry(qe);

          notify = true;
        }
      }

      if (core_configuration_->get_global_configuration().get_reorder_same_timestamp_input_events_to_prioritize_modifiers()) {
        merged_input_event_queue_->sort_events();
      }

      if (notify) {
        krbn_notification_center::get_instance().enqueue_input_event_arrived(*this);
      }
    }
  }

  void event_tap_keyboard_event_arrived(event_type event_type, const event_queue::event& event) {
    if (unbalanced_momentary_switch_event(device_id(0),
                                          event,
                                          event_type)) {
      return;
    }

    event_queue::entry entry(device_id(0),
                             event_queue::event_time_stamp(pqrs::osx::chrono::mach_absolute_time_point()),
                             event,
                             event_type,
                             std::nullopt,
                             event,
                             event_queue::state::original);

    merged_input_event_queue_->push_back_entry(entry);

    krbn_notification_center::get_instance().enqueue_input_event_arrived(*this);
  }

  void post_device_grabbed_event(pqrs::not_null_shared_ptr_t<device_properties> device_properties) {
    auto event = event_queue::event::make_device_grabbed_event(device_properties);
    event_queue::entry entry(device_properties->get_device_id(),
                             event_queue::event_time_stamp(pqrs::osx::chrono::mach_absolute_time_point()),
                             event,
                             event_type::single,
                             std::nullopt,
                             event,
                             event_queue::state::virtual_event);

    merged_input_event_queue_->push_back_entry(entry);

    krbn_notification_center::get_instance().enqueue_input_event_arrived(*this);
  }

  void post_device_ungrabbed_event(device_id device_id) {
    auto event = event_queue::event::make_device_ungrabbed_event();
    event_queue::entry entry(device_id,
                             event_queue::event_time_stamp(pqrs::osx::chrono::mach_absolute_time_point()),
                             event,
                             event_type::single,
                             std::nullopt,
                             event,
                             event_queue::state::virtual_event);

    merged_input_event_queue_->push_back_entry(entry);

    krbn_notification_center::get_instance().enqueue_input_event_arrived(*this);
  }

  void post_device_keys_and_pointing_buttons_are_released_event() {
    auto event = event_queue::event::make_device_keys_and_pointing_buttons_are_released_event();
    event_queue::entry entry(device_id(0),
                             event_queue::event_time_stamp(pqrs::osx::chrono::mach_absolute_time_point()),
                             event,
                             event_type::single,
                             std::nullopt,
                             event,
                             event_queue::state::virtual_event);

    merged_input_event_queue_->push_back_entry(entry);

    krbn_notification_center::get_instance().enqueue_input_event_arrived(*this);
  }

  void post_caps_lock_state_changed_event(bool caps_lock_state) {
    auto event = event_queue::event::make_caps_lock_state_changed_event(caps_lock_state);
    event_queue::entry entry(device_id(0),
                             event_queue::event_time_stamp(pqrs::osx::chrono::mach_absolute_time_point()),
                             event,
                             event_type::single,
                             std::nullopt,
                             event,
                             event_queue::state::virtual_event);

    merged_input_event_queue_->push_back_entry(entry);

    krbn_notification_center::get_instance().enqueue_input_event_arrived(*this);
  }

  // This method is executed in the shared dispatcher thread.
  void grab_device(device_grabber_details::entry& entry) const {
    if (!owned_configuration_current()) return;
    auto state = make_grabbable_state(entry);
    if (owned_configuration_snapshot_ && state==grabbable_state::state::grabbable) {
      const auto input=owned_input_;
      if (!input || !input->native_current() || !entry.get_hid_device_events_monitor()->bind_owned_input_scope(
          [input] { return input->native_current(); })) return;
    }
    switch (state) {
      case grabbable_state::state::grabbable:
        entry.async_start_hid_device_events_monitor(state);
        break;

      case grabbable_state::state::ungrabbable:
      case grabbable_state::state::none:
      case grabbable_state::state::end_:
        entry.async_stop_hid_device_events_monitor();
        break;
    }
  }

  // This method is executed in the shared dispatcher thread.
  void grab_device(device_id device_id) const {
    if (!owned_configuration_current()) return;
    if (auto it = entries_.find(device_id);
        it != entries_.end()) {
      grab_device(*(it->second));
    }
  }

  // This method is executed in the shared dispatcher thread.
  grabbable_state::state make_grabbable_state(const device_grabber_details::entry& entry) const {
    //
    // The device is always grabbable if it is observed device.
    // Because Karabiner-Core-Service never takes exclusive control of a device,
    // It doesn't cause side effects such as interfering with key input processing in hidd.
    //

    if (entry.needs_to_observe_device()) {
      return grabbable_state::state::grabbable;
    }

    //
    // From here, we determine whether it's safe to take exclusive control of the device.
    // If we take control before the virtual device is ready,
    // input events will have nowhere to go and be dropped,
    // so we must not grab the device until we're ready to send input events.
    //

    if (!entry.needs_to_seize_device()) {
      return grabbable_state::state::ungrabbable;
    }

    //
    // Ungrabbable while virtual_hid_device_service_client_ is not ready.
    //

    if (!virtual_hid_devices_state_.get_virtual_hid_keyboard_ready()) {
      std::string message = "virtual_hid_keyboard is not ready. Please wait for a while.";
      logger_unique_filter_.debug(message);
      return grabbable_state::state::ungrabbable;
    }

    if (needs_prepare_virtual_hid_pointing_device()) {
      if (!virtual_hid_devices_state_.get_virtual_hid_pointing_ready()) {
        std::string message = "virtual_hid_pointing is not ready. Please wait for a while.";
        logger_unique_filter_.debug(message);
        return grabbable_state::state::ungrabbable;
      }
    }

    //
    // It's okay to take exclusive control of the device.
    //

    return grabbable_state::state::grabbable;
  }

  void update_caps_lock_led() {
    std::optional<led_state> state;
    if (last_caps_lock_state_) {
      state = *last_caps_lock_state_ ? led_state::on : led_state::off;
    }

    for (auto&& entry : entries_ | std::views::values) {
      entry->set_caps_lock_led_state(state);
    }
  }

  [[nodiscard]] bool needs_prepare_virtual_hid_pointing_device() const {
    //
    // Check if there is a pointing device to grab
    // (The game pad also sends mouse events, so a virtual pointing device should be prepared as well.)
    //

    for (const auto& entry : entries_ | std::views::values) {
      if (entry->needs_to_seize_device()) {
        auto device_properties = entry->get_device_properties();
        if (device_properties->get_device_identifiers().get_is_pointing_device() ||
            device_properties->get_device_identifiers().get_is_game_pad()) {
          return true;
        }
      }
    }

    //
    // Check if a setting exists that would fire pointing device events
    //

    if (manipulator_managers_connector_.needs_virtual_hid_pointing()) {
      return true;
    }

    return false;
  }

  void update_virtual_hid_keyboard() {
    if (!owned_configuration_current()) return;
    if (owned_stopping_) return;
    pqrs::karabiner::driverkit::virtual_hid_device_service::virtual_hid_keyboard_parameters parameters;

    auto t = core_configuration_->get_selected_profile().get_virtual_hid_keyboard()->get_iokit_keyboard_type();
    if (t == pqrs::osx::iokit_keyboard_type::ansi) {
      // Apple Aluminum USB Keyboard (A1243) (ANSI)
      parameters.set_vendor_id(pqrs::hid::vendor_id::value_t(0x05ac));
      parameters.set_product_id(pqrs::hid::product_id::value_t(0x024f));
    } else if (t == pqrs::osx::iokit_keyboard_type::iso) {
      // Apple Aluminum USB Keyboard (A1243) (ISO)
      parameters.set_vendor_id(pqrs::hid::vendor_id::value_t(0x05ac));
      parameters.set_product_id(pqrs::hid::product_id::value_t(0x0250));
    } else if (t == pqrs::osx::iokit_keyboard_type::jis) {
      // Apple Aluminum USB Keyboard (A1243) (JIS)
      parameters.set_vendor_id(pqrs::hid::vendor_id::value_t(0x05ac));
      parameters.set_product_id(pqrs::hid::product_id::value_t(0x0251));
    } else {
      logger::get_logger()->warn("unknown virtual_hid_keyboard keyboard_type: {0}", type_safe::get(t));
    }

    if (owned_configuration_snapshot_) {
      if (owned_input_) {
        const auto cohort=owned_input_->cohort_.lock();
        const auto pending=cohort ? cohort->capture_->configuration_pending_ : nullptr;
        if (!pending || (owned_input_->readback_ && pending->sequence_==owned_input_->readback_->sequence_)) {
          if (!owned_input_->native_current() || (needs_prepare_virtual_hid_pointing_device() &&
              (!owned_input_->pointing_ || !owned_input_->pointing_->current()))) refuse_owned_input(owned_input_);
          return;
        }
      }
      const auto effect=retained_owned_preparation_effect();
      if (!effect) { refuse_owned_configuration_preparation(); return; }
      const auto scope=[weak=std::weak_ptr<configuration_request>(effect->request)] {
        const auto pending=weak.lock();
        return pending && pending->native_current();
      };
      if (!virtual_hid_device_service_client_->prepare_owned_keyboard(parameters,scope))
        refuse_owned_configuration_preparation();
      return;
    }
    virtual_hid_device_service_client_->async_virtual_hid_keyboard_initialize(parameters);
  }

  void update_virtual_hid_pointing() {
    if (!owned_configuration_current()) return;
    if (owned_stopping_) return;
    if (owned_configuration_snapshot_) {
      if (owned_input_) {
        const auto cohort=owned_input_->cohort_.lock();
        const auto pending=cohort ? cohort->capture_->configuration_pending_ : nullptr;
        if (!pending || (owned_input_->readback_ && pending->sequence_==owned_input_->readback_->sequence_)) {
          if (!owned_input_->native_current() || (needs_prepare_virtual_hid_pointing_device() &&
              (!owned_input_->pointing_ || !owned_input_->pointing_->current()))) refuse_owned_input(owned_input_);
          return;
        }
      }
      const auto effect=retained_owned_preparation_effect();
      if (!effect) { refuse_owned_configuration_preparation(); return; }
      if (needs_prepare_virtual_hid_pointing_device()) {
        const auto scope=[weak=std::weak_ptr<configuration_request>(effect->request)] {
          const auto pending=weak.lock();
          return pending && pending->native_current();
        };
        if (!virtual_hid_device_service_client_->prepare_owned_pointing(scope))
          refuse_owned_configuration_preparation();
      }
      return;
    }
    if (needs_prepare_virtual_hid_pointing_device()) {
      virtual_hid_device_service_client_->async_virtual_hid_pointing_initialize();
      return;
    }

    virtual_hid_device_service_client_->async_virtual_hid_pointing_terminate();
  }

  [[nodiscard]] bool need_to_disable_built_in_keyboard() const {
    for (const auto& entry : entries_ | std::views::values) {
      if (entry->is_disable_built_in_keyboard_if_exists()) {
        return true;
      }
    }
    return false;
  }

  void update_devices_disabled() {
    for (const auto& entry : entries_ | std::views::values) {
      if (entry->determine_is_built_in_keyboard() &&
          need_to_disable_built_in_keyboard()) {
        entry->set_disabled(true);
      } else {
        entry->set_disabled(false);
      }
    }
  }

  void update_complex_modifications_manipulators() {
    complex_modifications_manipulator_manager_->invalidate_manipulators();

    for (const auto& rule : core_configuration_->get_selected_profile().get_complex_modifications()->get_rules()) {
      if (!rule->get_enabled()) {
        continue;
      }

      for (const auto& manipulator : rule->get_manipulators()) {
        try {
          auto m = manipulator::manipulator_factory::make_manipulator(manipulator->to_json(),
                                                                      manipulator->get_parameters());
          for (const auto& c : manipulator->get_conditions()) {
            m->push_back_condition(manipulator::condition_factory::make_condition(c.get_json()));
          }
          complex_modifications_manipulator_manager_->push_back_manipulator(m);

        } catch (const pqrs::json::unmarshal_error& e) {
          logger::get_logger()->error(fmt::format("karabiner.json error: {0}", e.what()));

        } catch (const std::exception& e) {
          logger::get_logger()->error(e.what());
        }
      }
    }
  }

  void set_cgeventtap_fallback_enabled(bool value) {
    if (cgeventtap_fallback_enabled_ == value) {
      logger::get_logger()->debug("enable_cgeventtap_fallback unchanged: effective={0}",
                                  cgeventtap_fallback_enabled_);
      return;
    }

    cgeventtap_fallback_enabled_ = value;

    logger::get_logger()->debug("enable_cgeventtap_fallback changed: effective={0}",
                                cgeventtap_fallback_enabled_);

    if (post_event_to_virtual_devices_manipulator_) {
      post_event_to_virtual_devices_manipulator_->set_cgeventtap_fallback_enabled(cgeventtap_fallback_enabled_);
    }

    setup_event_tap_monitor(cgeventtap_fallback_enabled_);

    async_grab_devices();
  }

  void setup_event_tap_monitor(bool cgeventtap_fallback_enabled) {
    if (!owned_configuration_current()) return;
    if (owned_stopping_) return;
    logger::get_logger()->debug("setup_event_tap_monitor (enable_cgeventtap_fallback={0})",
                                cgeventtap_fallback_enabled);

    // Keep only the latest requested configuration while the previous monitor
    // is stopping. This prevents old and new EventTaps from being active at the
    // same time when configuration changes arrive in quick succession.
    pending_event_tap_monitor_configuration_ = cgeventtap_fallback_enabled;

    if (event_tap_monitor_stopping_) {
      return;
    }

    if (event_tap_monitor_) {
      event_tap_monitor_stopping_ = true;

      std::weak_ptr<bool> weak_lifetime(event_tap_monitor_lifetime_);
      async_stop_event_tap_monitor([this, weak_lifetime] {
        // Both invalidation and this completion run on the shared dispatcher,
        // so a valid token guarantees that device_grabber is still alive here.
        if (!weak_lifetime.lock()) {
          return;
        }

        event_tap_monitor_stopping_ = false;
        create_pending_event_tap_monitor();
      });

      return;
    }

    create_pending_event_tap_monitor();
  }

  void create_pending_event_tap_monitor() {
    if (owned_stopping_) return;
    if (!pending_event_tap_monitor_configuration_) {
      return;
    }

    auto cgeventtap_fallback_enabled = *pending_event_tap_monitor_configuration_;
    pending_event_tap_monitor_configuration_ = std::nullopt;

    if (owned_configuration_snapshot_ && (!owned_input_ || !owned_input_->native_current())) {
      if (owned_input_) refuse_owned_input(owned_input_);
      return;
    }
    event_tap_monitor_ = std::make_unique<event_tap_monitor>(
        cgeventtap_fallback_enabled,
        post_event_to_virtual_devices_manipulator_->get_virtual_hid_keyboard_pressed_keys_manager(),
        post_event_to_virtual_devices_manipulator_->get_keyboard_suppression());
    event_tap_ever_created_=true;

    event_tap_monitor_->pointing_device_event_arrived.connect([this](auto&& event_type, auto&& event) {
      auto e = event_queue::event::make_pointing_device_event_from_event_tap_event();
      event_queue::entry entry(device_id(0),
                               event_queue::event_time_stamp(pqrs::osx::chrono::mach_absolute_time_point()),
                               e,
                               event_type,
                               std::nullopt,
                               event,
                               event_queue::state::virtual_event);

      merged_input_event_queue_->push_back_entry(entry);

      krbn_notification_center::get_instance().enqueue_input_event_arrived(*this);
    });

    event_tap_monitor_->keyboard_event_arrived.connect([this](auto&& event_type, auto&& event) {
      event_tap_keyboard_event_arrived(event_type, event);
    });

    if (owned_configuration_snapshot_) {
      const auto state=owned_input_;
      const auto cohort=owned_cohort_.lock();
      if (!state || !cohort) { if (state) refuse_owned_input(state); return; }
      std::weak_ptr<device_grabber> weak(cohort->device_);
      if (!event_tap_monitor_->async_owned_start([state] { return state->native_current(); },[weak,state](auto receipt) {
        if (const auto device=weak.lock()) {
          if (device->owned_input_!=state || !receipt) { device->refuse_owned_input(state); return; }
          state->tap_=std::move(receipt);
          device->progress_owned_input();
        }
      })) refuse_owned_input(state);
      return;
    }
    event_tap_monitor_->async_start();
  }

  void async_stop_event_tap_monitor(std::function<void()> completion = nullptr) {
    if (!event_tap_monitor_) {
      if (completion) {
        completion();
      }
      return;
    }

    // Remove the monitor from device_grabber immediately so shutdown or a new
    // setup can continue without waiting for its run-loop thread. Keep it alive
    // through the completion until EventTap cleanup has finished on that thread.
    std::shared_ptr<event_tap_monitor> event_tap_monitor(std::move(event_tap_monitor_));
    event_tap_monitor->async_stop([event_tap_monitor, completion] {
      // Keep event_tap_monitor alive until its run loop has stopped, then
      // continue a pending replacement if the owner is still alive.
      if (completion) {
        completion();
      }
    });
  }

  // Some input paths (for example around secure event input transitions or CGEventTap fallback re-entry)
  // can deliver a key_up without a corresponding key_down, or repeated key_down while the same key is
  // still treated as pressed. If we push such unbalanced events into merged_input_event_queue_,
  // downstream state can become inconsistent and cause stuck keys or re-entry loops.
  // Therefore we have to drop unbalanced momentary switch events before queue insertion.
  bool unbalanced_momentary_switch_event(device_id device_id,
                                         const event_queue::event& event,
                                         event_type event_type) {
    auto& pressed_momentary_switch_events = physical_pressed_momentary_switch_events_[device_id];

    if (auto mse = event.template get_if<momentary_switch_event>()) {
      if (!mse->valid()) {
        return false;
      }

      switch (event_type) {
        case event_type::key_down:
          if (pressed_momentary_switch_events.contains(*mse)) {
            logger::get_logger()->warn("drop duplicated momentary switch key_down before merged_input_event_queue insertion");
            return true;
          }
          pressed_momentary_switch_events.insert(*mse);
          break;

        case event_type::key_up:
          if (!pressed_momentary_switch_events.contains(*mse)) {
            logger::get_logger()->warn("drop unmatched momentary switch key_up before merged_input_event_queue insertion");
            return true;
          }
          pressed_momentary_switch_events.erase(*mse);
          break;

        case event_type::single:
          break;
      }
    }

    return false;
  }

  std::weak_ptr<console_user_server_peer> weak_console_user_server_peer_;
  std::weak_ptr<core_service_daemon_state_manager> weak_core_service_daemon_state_manager_;

  std::shared_ptr<pqrs::karabiner::driverkit::virtual_hid_device_service::client> virtual_hid_device_service_client_;

  virtual_hid_devices_state virtual_hid_devices_state_;

  // Connections to signals owned by objects that may outlive device_grabber.
  // Keep them here to ensure that callbacks referencing this are disconnected
  // before device_grabber is destroyed.
  std::vector<nod::scoped_connection> external_signal_connections_;

  std::unique_ptr<configuration_monitor> configuration_monitor_;
  pqrs::not_null_shared_ptr_t<const core_configuration::core_configuration> core_configuration_;

  std::unique_ptr<event_tap_monitor> event_tap_monitor_;
  bool event_tap_ever_created_=false;
  std::shared_ptr<bool> event_tap_monitor_lifetime_ = std::make_shared<bool>();
  std::optional<bool> pending_event_tap_monitor_configuration_;
  bool event_tap_monitor_stopping_ = false;
  std::optional<bool> last_caps_lock_state_;
  hs274_stream_protocol::runtime::inventory_watch hs274_inventory_ = hs274_stream_protocol::runtime::watch_inventory();
  std::unique_ptr<pqrs::osx::iokit_hid_manager> hid_manager_;
  std::unordered_map<device_id, pqrs::not_null_shared_ptr_t<device_grabber_details::entry>> entries_;
  std::unordered_set<device_id> temporarily_ignored_device_ids_;

  std::unique_ptr<pqrs::osx::hitoolbox::secure_event_input_monitor> secure_event_input_monitor_;

  pqrs::osx::system_preferences::properties system_preferences_properties_;

  manipulator::manipulator_managers_connector manipulator_managers_connector_;

  std::shared_ptr<notification_message_manager> notification_message_manager_;

  std::shared_ptr<event_queue::queue> merged_input_event_queue_;

  std::shared_ptr<device_grabber_details::device_key_code_manipulator_manager> device_key_code_manipulator_manager_;
  std::shared_ptr<event_queue::queue> device_key_code_manipulated_event_queue_;

  std::shared_ptr<device_grabber_details::simple_modifications_manipulator_manager> simple_modifications_manipulator_manager_;
  std::shared_ptr<event_queue::queue> simple_modifications_applied_event_queue_;

  std::shared_ptr<manipulator::manipulator_manager> complex_modifications_manipulator_manager_;
  std::shared_ptr<event_queue::queue> complex_modifications_applied_event_queue_;

  std::shared_ptr<device_grabber_details::fn_function_keys_manipulator_manager> fn_function_keys_manipulator_manager_;
  std::shared_ptr<event_queue::queue> fn_function_keys_applied_event_queue_;

  std::shared_ptr<manipulator::manipulators::post_event_to_virtual_devices::post_event_to_virtual_devices> post_event_to_virtual_devices_manipulator_;
  std::shared_ptr<manipulator::manipulator_manager> post_event_to_virtual_devices_manipulator_manager_;
  std::shared_ptr<event_queue::queue> posted_event_queue_;
  std::unordered_map<device_id, std::unordered_set<momentary_switch_event>> physical_pressed_momentary_switch_events_;

  bool cgeventtap_fallback_enabled_ = false;

  mutable pqrs::spdlog::unique_filter logger_unique_filter_;
};

inline void device_grabber::active_cohort::deliver_terminal() {
  if (delivered_ || !participants_settled()) return;
  // No terminal receipt is observable before native namespace closure ACK.
  if (!capture_->receiver_->complete_owned_capture_retirement(capture_) || !terminal_conditions()) {
    failed_=true;
    return;
  }
  // The executable CLI reply is delivered on the same original Core socket
  // only after terminal_conditions includes all native participants and SH ACK.
  if (!capture_->receiver_->finish_owned_terminal_delivery(capture_)) {
    failed_=true;
    return;
  }
  auto observer=std::move(observer_);
  auto receipt=terminal_receipt(shared_from_this());
  if (configuration_off_ && !device_->complete_owned_configuration_off(configuration_off_,receipt)) {
    failed_=true;
    return;
  }
  // Receiver destruction cannot abandon native cleanup, and no consumer is
  // required to dispose a genuinely completed original participant cohort.
  try {
    if (observer) observer(std::move(receipt));
  } catch (...) { failed_=true; return; }
  delivered_=true;
  custody_.reset();
}
} // namespace krbn::core_service::daemon

namespace hs274_stream_protocol {
inline bool runtime::finish_configuration_off(const std::shared_ptr<configuration_effect_request>& request) {
  if (!request || request->mode_!=0 || !request->terminal_device_ || !request->snapshot_) return false;
  const auto participant=request->participant_;
  const auto device=request->terminal_device_;
  const auto terminal=device->owned_configuration_off_terminal(request);
  if (!terminal || !terminal->current() || participant->configuration_pending_!=request ||
      !participant->configuration_closed_ || !participant->retirement_requested_ ||
      participant->configuration_sequence_!=request->sequence_ || participant->generation_!=installed_generation_ ||
      !installed_terminal_ || installed_terminal_->generation!=participant->generation_ ||
      !installed_terminal_->acknowledged || !owned_capture_terminal(participant)) return false;
  auto projection=json{{"version",1u},{"kind","configuration_consumed"},
    {"incarnation",installed_terminal_->projection->success.at("incarnation")},
    {"preparation",installed_terminal_->projection->success.at("preparation")},
    {"configuration_generation",request->snapshot_->generation()},
    {"configuration_sha256",request->snapshot_->sha256()},
    {"cohort",std::to_string(participant->generation_)}};
  request->native_revoked_.store(true,std::memory_order_release);
  participant->configuration_pending_.reset(); // Before exact sender callback reentry.
  const auto reply=request->completion_;
  return request->owner_->deliver([this,device,participant,request,projection,reply](auto&) {
    const auto still_terminal=device->owned_configuration_off_terminal(request);
    if (still_terminal && still_terminal->current() && installed_generation_==participant->generation_ &&
        participant->configuration_sequence_==request->sequence_ && participant->configuration_closed_ && reply)
      reply(projection);
  });
}
} // namespace hs274_stream_protocol
