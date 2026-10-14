// tools/diagnostics/hs274-stream-runtime.hpp
// Owned native bridge; all access belongs to the shared dispatcher.
#pragma once

#include "hs274-stream-source.hpp"
#include "ergopti-owned-native-inventory.hpp"
#include "hs274-stream-native-binding.hpp"
#include "hs274-stream-baseline-probe.hpp"
#include "hs274-stream-native-boundary.hpp"
#include "remap_runtime_installed_peer.hpp"
#include "InstalledUserConfiguration.hpp"
#include "remap_runtime_console_control.hpp"
#include "remap_runtime_vhd.hpp"
#include "core_configuration/core_configuration.hpp"
#include <atomic>
#include <exception>
#include <algorithm>
#include <limits>
#include <functional>
#include <memory>
#include <vector>
#include <uuid/uuid.h>
#include <mach/mach_time.h>

namespace krbn::core_service::daemon { class device_grabber; class receiver; }
namespace ergoptiplus::installed_maintenance { class core_endpoint; }
namespace hs274_stream_protocol {
class runtime final {
  // Bound observed keyboard interfaces; exhaustion explicitly invalidates coverage.
  using source_type = source<4096, 64, ergoptiplus::remap::native_interface_capacity>;
public:
  using monitor = source_type::native_registration;
  using queue_snapshot = source_type::queue_snapshot;
  using inventory_type = ergoptiplus::remap::native_inventory<ergoptiplus::remap::native_interface_capacity>;
  using inventory_watch = inventory_type::watch;

  runtime() : source_(make_incarnation(), [] { return mach_absolute_time(); }),
      inventory_(&source_, [](void* receiver) noexcept { static_cast<source_type*>(receiver)->inventory_changed(); }) {
    if (active_) throw std::logic_error("Capture receiver already owns the native bridge");
    active_ = this;
  }
  runtime(const runtime&) = delete;
  runtime& operator=(const runtime&) = delete;
  ~runtime() { *installed_alive_=false; active_ = nullptr; }

  json request(std::uint64_t peer, const json& input) {
    if (input.is_object() && input.contains("action") && input.at("action").is_string()) {
      const auto action = input.at("action").get<std::string>();
      if (action == "status") {
        auto result = source_.request(peer, input);
        result["ready"] = result.at("ready").get<bool>() && inventory_matches(result);
        return result;
      }
      if (action == "open" && !inventory_matches(source_.request(peer, {{"version", 1u}, {"action", "status"}})))
        throw std::runtime_error("Native interface inventory has not settled to the registered monitors");
    }
    return source_.request(peer, input);
  }

  static inventory_watch watch_inventory() {
    if (!active_) throw std::logic_error("Native inventory has no receiver owner");
    return active_->inventory_.begin();
  }
  static source_type::baseline freeze_queue_snapshots(std::uint64_t peer, const std::vector<queue_snapshot>& snapshots) {
    if (!active_) throw std::logic_error("Queue cut has no native runtime owner");
    if (!active_->inventory_matches(active_->source_.request(peer, {{"version",1u},{"action","status"}})))
      throw std::logic_error("Queue cut expected native interfaces changed");
    return active_->source_.freeze_queue_snapshots(snapshots,mach_absolute_time());
  }


  using installed_peer = ergoptiplus::installed_capture::core_peer_owner;
  class production_open;
  class capture_participant;
  using configuration_snapshot = ::krbn::core_configuration::core_configuration::owned_configuration_snapshot;
  class configuration_effect_request final {
    friend class runtime;
    friend class ::krbn::core_service::daemon::device_grabber;
    const std::shared_ptr<capture_participant> participant_;
    const std::shared_ptr<const configuration_snapshot> snapshot_;
    const std::shared_ptr<installed_peer> owner_;
    const std::uint64_t sequence_;
    const int mode_;
    const std::shared_ptr<ergoptiplus::remap::auth::console_control_owner> native_console_;
    const std::shared_ptr<ergoptiplus::installed_capture::core_namespace_hold> native_namespace_;
    const std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> native_broker_;
    std::atomic_bool native_revoked_{false};
    // Only the exact original Device's terminal-OFF factory can install this.
    std::shared_ptr<::krbn::core_service::daemon::device_grabber> terminal_device_;
    std::function<void(const json&)> completion_;
    configuration_effect_request(std::shared_ptr<capture_participant> participant,
        std::shared_ptr<const configuration_snapshot> snapshot,
        std::shared_ptr<installed_peer> owner,std::uint64_t sequence,int mode,
        std::function<void(const json&)> completion);
    bool current() const;
    bool native_current() const;
  };
  class capture_participant final {
    friend class ::ergoptiplus::installed_maintenance::core_endpoint;
    friend class runtime;
    friend class production_open;
    friend class configuration_effect_request;
    friend class ::krbn::core_service::daemon::device_grabber;
    friend class ::krbn::core_service::daemon::receiver;
    runtime* receiver_;
    const std::shared_ptr<runtime> runtime_retention_;
    const std::shared_ptr<ergoptiplus::remap::auth::console_control_owner> console_;
    const std::shared_ptr<ergoptiplus::installed_configuration::owner> configuration_;
    std::shared_ptr<installed_peer> preparation_owner_;
    std::shared_ptr<::krbn::core_service::daemon::device_grabber> device_retention_;
    const std::shared_ptr<ergoptiplus::installed_capture::core_namespace_hold> namespace_;
    const std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> broker_;
    bool broker_initialized_=false, constructor_refused_=false, partial_requested_=false;
    std::atomic_bool partial_failed_{false};
    std::exception_ptr constructor_exception_;
    const std::uint64_t generation_;
    std::optional<std::uint64_t> peer_; // Absent until genuine CLI preparation joins this constructor.
    std::shared_ptr<const configuration_snapshot> configuration_snapshot_;
    std::shared_ptr<configuration_effect_request> configuration_pending_;
    std::uint64_t configuration_sequence_=0;
    bool configuration_closed_=false;
    // Installed only by the same original Device's private parsed-owner join.
    std::function<bool(const std::shared_ptr<configuration_effect_request>&)> configuration_apply_;
    std::shared_ptr<production_open> opened_;
    bool published_=false, effect_started_=false, retirement_requested_=false;
    bool source_closed_=false, finalized_=false;
    std::function<void()> progress_;
    // Only Device's preallocated aggregate installs this cleanup continuation.
    std::function<bool()> request_aggregate_retirement_;
    capture_participant(std::shared_ptr<runtime> receiver,
                        std::shared_ptr<ergoptiplus::remap::auth::console_control_owner> console,
                        std::shared_ptr<ergoptiplus::installed_configuration::owner> configuration,
                        std::shared_ptr<ergoptiplus::installed_capture::core_namespace_hold> hold,
                        std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> broker,
                        std::uint64_t generation)
      :receiver_(receiver.get()), runtime_retention_(std::move(receiver)),
       console_(std::move(console)), configuration_(std::move(configuration)), namespace_(std::move(hold)), broker_(std::move(broker)), generation_(generation) {}
    bool retain_constructed_device(const std::shared_ptr<::krbn::core_service::daemon::device_grabber>& device) {
      if (!device || device_retention_ || !published_ || retirement_requested_) return false;
      device_retention_=device; // Actual receiver constructor result, not a nullable lease.
      return true;
    }
    bool current() const {
      return !retirement_requested_ && receiver_ && generation_==receiver_->installed_generation_ &&
             receiver_->installed_capture_.get()==this && console_->current() && namespace_->current() &&
             (!preparation_owner_ || preparation_owner_->current());
    }
  };
  class production_open final {
    friend class runtime;
    friend class ::krbn::core_service::daemon::device_grabber;
    friend class ::krbn::core_service::daemon::receiver;
    runtime* receiver_;
    const std::shared_ptr<capture_participant> participant_;
    std::shared_ptr<runtime> runtime_retention_;
    bool retain_runtime(const std::shared_ptr<runtime>& runtime_owner) {
      if (!runtime_owner || runtime_owner.get()!=receiver_ || settled_ ||
          receiver_->installed_pending_.get()!=this || !participant_ ||
          participant_->runtime_retention_!=runtime_owner) return false;
      if (runtime_retention_) return runtime_retention_==runtime_owner;
      runtime_retention_=runtime_owner;
      return true;
    }
    std::weak_ptr<bool> alive_;
    std::uint64_t peer_;
    std::shared_ptr<installed_peer> request_;
    std::vector<std::uint64_t> devices_;
    std::vector<bool> returned_;
    std::vector<bool> callbacks_unwound_;
    std::shared_ptr<installed_peer> suspension_owner_;
    std::function<void(const json&)> suspension_reply_;
    std::shared_ptr<const json> suspension_projection_;
    std::vector<queue_snapshot> snapshots_;
    std::shared_ptr<void> native_retention_;
    std::function<bool()> native_current_;
    std::function<void(const json&)> completion_;
    std::size_t pending_ = 0;
    bool failed_ = false, cancelled_ = false, settled_ = false;
    const std::uint64_t generation_;
    bool retirement_requested_=false, ring_closed_=false;
    std::function<void()> retirement_progress_;
    production_open(runtime& receiver, std::shared_ptr<capture_participant> participant, std::uint64_t peer,
                    std::shared_ptr<installed_peer> request,
                    std::vector<std::uint64_t> devices,
                    std::function<void(const json&)> completion)
        : receiver_(&receiver), participant_(std::move(participant)),
          runtime_retention_(participant_->runtime_retention_), alive_(receiver.installed_alive_), peer_(peer),
          request_(std::move(request)), devices_(std::move(devices)),
          returned_(devices_.size(),false), callbacks_unwound_(devices_.size(),false), snapshots_(devices_.size()),
          completion_(std::move(completion)), pending_(devices_.size()),
          generation_(receiver.installed_generation_) {}
    void returned(std::size_t index, queue_snapshot snapshot, bool valid) {
      if (index >= returned_.size() || returned_[index]) { failed_=true; return; }
      returned_[index]=true;
      if (!valid || !snapshot.current() || snapshot.device()!=devices_[index]) failed_=true;
      snapshots_[index]=std::move(snapshot);
      --pending_;
      if (!pending_) settle();
    }
    bool callbacks_unwound() const {
      return std::all_of(callbacks_unwound_.begin(),callbacks_unwound_.end(),[](bool value) { return value; });
    }
    void callback_unwound(std::size_t index) {
      if (index>=callbacks_unwound_.size() || callbacks_unwound_[index] || !returned_[index]) {
        failed_=true; return;
      }
      callbacks_unwound_[index]=true;
      const auto runtime_owner=runtime_retention_;
      if (suspension_owner_) receiver_->finish_observation_suspension(*this);
      if (participant_->retirement_requested_ && participant_->progress_) participant_->progress_();
    }
    void settle() {
      if (settled_ || pending_) return;
      settled_=true;
      // Keep the original source alive through last callback and reentrant reply.
      const auto runtime_owner=runtime_retention_;
      const auto alive=alive_.lock();
      if (!alive || !*alive) { request_->deliver({}); return; }
      receiver_->finish_production(*this);
      if (retirement_requested_ && retirement_progress_) retirement_progress_();
      if (participant_->retirement_requested_ && participant_->progress_) participant_->progress_();
    }
  };

  bool installed(std::uint64_t peer) const noexcept {
    return installed_peer_ && installed_peer_id_==peer;
  }
  // Installed Console admission, not CLI preparation, is the first native
  // effect boundary. These private Console ports derive actual original peer
  // custody; a PID, JSON leaf or caller flag cannot construct this participant.
  std::shared_ptr<capture_participant> retain_constructor(
      const std::shared_ptr<runtime>& runtime_owner,
      const std::shared_ptr<ergoptiplus::remap::auth::console_control_owner>& console) {
    if (!runtime_owner || runtime_owner.get()!=this || installed_stopping_ || installed_capture_ ||
        installed_peer_ || !console || !console->current() ||
        installed_generation_==std::numeric_limits<std::uint64_t>::max()) return nullptr;
    auto configuration=console->retain_configuration_namespace();
    if (!configuration || !configuration->namespace_current() ||
        !configuration->capture_publication() || !configuration->file_current()) return nullptr;
    auto hold=console->retain_core_namespace();
    if (!hold || !hold->current() || !configuration->file_current()) return nullptr;
    if (!maintenance_before_constructor()) return nullptr;
    const auto generation=installed_generation_+1;
    auto broker=ergoptiplus::remap::vhd::broker_owner::allocate_owned_constructor();
    auto participant=std::shared_ptr<capture_participant>(new capture_participant(
        runtime_owner,console,std::move(configuration),std::move(hold),std::move(broker),generation));
    installed_terminal_.reset(); // A new genuine constructor supersedes old terminal observations.
    installed_generation_=generation;
    installed_capture_=participant;
    return participant;
  }
  bool publish_constructor(const std::shared_ptr<capture_participant>& participant) {
    if (!participant || participant!=installed_capture_ || !participant->current() || participant->published_) return false;
    if (!participant->configuration_ || !participant->configuration_->file_current() ||
        !participant->namespace_->publish_before_prepare()) return false;
    participant->published_=true;
    participant->effect_started_=true; // Before native reference/device construction.
    try { participant->broker_initialized_=participant->broker_->initialize_owned_constructor(); }
    catch (...) { participant->constructor_exception_=std::current_exception(); }
    if (!participant->broker_initialized_) participant->constructor_refused_=true;
    return participant->broker_initialized_;
  }
  std::shared_ptr<capture_participant> retain_preparation(
      std::uint64_t peer, const std::shared_ptr<installed_peer>& owner,
      const std::shared_ptr<runtime>& runtime_owner) {
    const auto participant=installed_capture_;
    if (!runtime_owner || runtime_owner.get()!=this || installed_stopping_ || !participant ||
        !participant->published_ || !participant->device_retention_ || !participant->current() ||
        participant->preparation_owner_ || installed_peer_ || !owner || !owner->current() ||
        !participant->console_->matches_installed_peer(*owner)) return nullptr;
    if (!owner->retain_cleanup_namespace(participant->namespace_)) return nullptr;
    participant->preparation_owner_=owner;
    participant->peer_=peer;
    return participant;
  }
  bool discard_unpublished_preparation(const std::shared_ptr<capture_participant>& participant) {
    if (!participant || participant!=installed_capture_ || participant->published_ ||
        participant->effect_started_ || participant->opened_) return false;
    // Empty broker construction has no native acquisition; still use its
    // original actual close path and refuse any observed close failure.
    participant->broker_->retire();
    if (!participant->broker_->retired()) return false;
    installed_capture_.reset(); // Unpublished hold closes through its actual destructor.
    return true;
  }
  enum class constructor_failure_status { pending, retired, native_cleanup_refused };
  bool request_constructor_retirement(const std::shared_ptr<capture_participant>& participant,
                                      std::exception_ptr original_failure) {
    if (!participant || participant!=installed_capture_ || !participant->published_ ||
        participant->device_retention_ || participant->opened_ || participant->peer_ ||
        (!original_failure && !participant->constructor_refused_)) return false;
    if (participant->partial_requested_) return !participant->partial_failed_;
    participant->partial_requested_=true;
    participant->retirement_requested_=true;
    installed_stopping_=true;
    if (original_failure) participant->constructor_exception_=original_failure;
    // No IOHID manager, secure-input timer or EventTap async_start has happened:
    // the receiver calls this only after the real device constructor unwound.
    const auto progress=[participant] {
      try {
        if (!participant->console_->enqueue_to_dispatcher([participant] {
              participant->receiver_->finish_constructor_retirement(participant);
            })) participant->partial_failed_=true;
      } catch (...) { participant->partial_failed_=true; }
    };
    try {
      if (!participant->console_->observe_retirement(progress)) participant->partial_failed_=true;
      participant->console_->request_retirement();
    } catch (...) { participant->partial_failed_=true; }
    try {
      if (!participant->broker_->observe_owned_constructor_retirement(progress)) participant->partial_failed_=true;
      participant->broker_->retire();
    } catch (...) { participant->partial_failed_=true; }
    progress();
    return !participant->partial_failed_; // Pending admission only.
  }
  constructor_failure_status constructor_retirement_status(const std::shared_ptr<capture_participant>& participant) const {
    if (!participant || participant->receiver_!=this || !participant->partial_requested_ ||
        participant->partial_failed_ || participant->broker_->owned_constructor_cleanup_failed())
      return constructor_failure_status::native_cleanup_refused;
    if (participant->finalized_ && participant->console_->retired() && participant->broker_->retired() &&
        participant->namespace_->retired()) return constructor_failure_status::retired;
    return constructor_failure_status::pending;
  }
  json prepare_production(const std::shared_ptr<capture_participant>& participant, const json& input) {
    if (!participant || participant!=installed_capture_ || !participant->current() || !participant->published_ ||
        !participant->peer_ || !participant->preparation_owner_ || installed_peer_)
      throw std::logic_error("Installed preparation has no admitted Console constructor participant");
    installed_peer_=participant->preparation_owner_;
    installed_peer_id_=*participant->peer_;
    try {
      auto prepared=source_.prepare_production(*participant->peer_,input);
      // Allocate projections while the original preparation is still current,
      // before requesting any native retirement or closing namespace custody.
      json success={{"version",1u},{"kind","cohort_retired"},
                    {"incarnation",prepared.at("incarnation")},{"preparation",prepared.at("preparation")},
                    {"cohort",std::to_string(participant->generation_)}};
      auto refused=success;
      refused["kind"]="cohort_retirement_refused";
      installed_terminal_.emplace(installed_terminal_record{*participant->peer_,participant->generation_,
          participant->preparation_owner_,std::make_shared<const installed_terminal_projection>(
              installed_terminal_projection{std::move(success),std::move(refused)}),false});
      if (!maintenance_enroll_prepared(participant,prepared))
        throw std::logic_error("Prepared maintenance lineage enrollment refused");
      return prepared;
    } catch (...) {
      // Partial source preparation cannot abandon the already constructed cohort.
      try { if (participant->request_aggregate_retirement_) participant->request_aggregate_retirement_(); } catch (...) {}
      throw;
    }
  }
  json configuration_status(std::uint64_t peer,const json& input,
                            const std::shared_ptr<installed_peer>& owner) {
    const auto participant=require_configuration_request(peer,input,owner,"configuration_status",4);
    return configuration_projection(participant);
  }
  void configuration_mode(std::uint64_t peer,const json& input,
      const std::shared_ptr<installed_peer>& owner,std::function<void(const json&)> completion) {
    const auto participant=require_configuration_request(peer,input,owner,"configuration_mode",7);
    const auto snapshot=participant->configuration_snapshot_;
    if (!completion || !snapshot || !snapshot->current() || !participant->configuration_apply_ ||
        participant->configuration_pending_ || participant->configuration_closed_ ||
        !input.at("configuration_generation").is_string() ||
        input.at("configuration_generation")!=snapshot->generation() ||
        !input.at("configuration_sha256").is_string() || input.at("configuration_sha256")!=snapshot->sha256() ||
        !input.at("mode").is_number_integer() || input.at("mode").is_boolean() ||
        input.at("mode")<0 || input.at("mode")>2 ||
        participant->configuration_sequence_==std::numeric_limits<std::uint64_t>::max())
      throw std::logic_error("Installed configuration mode has no exact parsed request owner");
    auto request=std::shared_ptr<configuration_effect_request>(new configuration_effect_request(
        participant,snapshot,owner,++participant->configuration_sequence_,input.at("mode").get<int>(),std::move(completion)));
    participant->configuration_pending_=request; // Before genuine native preparation/mutation.
    bool admitted=false;
    try { admitted=participant->configuration_apply_(request); }
    catch (...) { expire_configuration_mode(owner); throw; }
    if (!admitted) {
      expire_configuration_mode(owner);
      throw std::logic_error("Original configuration effect dispatcher refused the request");
    }
  }
  bool expire_configuration_mode(const std::shared_ptr<installed_peer>& owner) {
    const auto participant=installed_capture_;
    if (!participant || !participant->configuration_pending_ ||
        participant->configuration_pending_->owner_!=owner) return false;
    auto request=std::move(participant->configuration_pending_);
    request->native_revoked_.store(true,std::memory_order_release);
    request->owner_->deliver({}); // Original request debt; never native cleanup credit.
    if (participant->request_aggregate_retirement_) participant->request_aggregate_retirement_();
    return true;
  }

  std::shared_ptr<production_open> open_production(
      std::uint64_t peer, const json& input, const std::shared_ptr<installed_peer>& owner,
      std::function<void(const json&)> completion) {
    require_installed(peer,owner);
    if (!installed_capture_ || !installed_capture_->current() || !installed_capture_->published_ ||
        installed_capture_->opened_ || installed_pending_ || !completion)
      throw std::logic_error("Installed native cut is already pending");
    const auto status=request(peer,{{"version",1u},{"action","status"}});
    if (!status.at("ready").get<bool>() || !inventory_matches(status))
      throw std::logic_error("Installed native inventory is not fully started");
    std::vector<std::uint64_t> devices;
    for (const auto& row:status.at("monitors")) devices.push_back(decimal(row.at("device")));
    std::sort(devices.begin(),devices.end());
    if (devices.empty() || std::adjacent_find(devices.begin(),devices.end())!=devices.end())
      throw std::logic_error("Installed native inventory is empty or duplicated");
    // All holder allocations precede the original bounded ring acquisition.
    auto pending=std::shared_ptr<production_open>(new production_open(
        *this,installed_capture_,peer,owner,std::move(devices),std::move(completion)));
    try { source_.begin_production(peer,input); }
    catch (...) { source_.peer_closed(peer); throw; }
    installed_capture_->opened_=pending;
    installed_pending_=std::move(pending);
    return installed_pending_;
  }
  std::shared_ptr<installed_peer> acquire_retirement_owner(std::uint64_t peer,const json& input,
      ergoptiplus::remap::auth::frame_scope& scope) {
    if (!installed_terminal_ || installed_terminal_->peer!=peer ||
        installed_terminal_->generation!=installed_generation_ || !installed_terminal_->preparation_owner ||
        input.size()!=4 || !input.at("version").is_number_unsigned() || input.at("version")!=1u ||
        input.at("action")!="retire_installed" ||
        input.at("incarnation")!=installed_terminal_->projection->success.at("incarnation") ||
        input.at("preparation")!=installed_terminal_->projection->success.at("preparation")) return nullptr;
    return installed_peer::acquire_cleanup(scope,installed_terminal_->preparation_owner);
  }
  void retire_installed(std::uint64_t peer, const json& input,
                        const std::shared_ptr<installed_peer>& owner,
                        std::function<void(const json&)> completion) {
    if (!owner || !completion || !installed_terminal_ || installed_terminal_->peer!=peer ||
        installed_terminal_->generation!=installed_generation_ ||
        !owner->cleanup_current() || !installed_terminal_->preparation_owner->same_socket(*owner) ||
        input.size()!=4 || !input.at("version").is_number_unsigned() || input.at("version")!=1u ||
        input.at("action")!="retire_installed" ||
        input.at("incarnation")!=installed_terminal_->projection->success.at("incarnation") ||
        input.at("preparation")!=installed_terminal_->projection->success.at("preparation"))
      throw std::logic_error("Retirement does not belong to the original installed preparation");
    if (installed_retirement_owner_)
      throw std::logic_error("Original installed retirement request is already pending");
    const auto participant=installed_capture_;
    if (!installed_terminal_->acknowledged &&
        (!participant || participant->generation_!=installed_terminal_->generation ||
         !participant->request_aggregate_retirement_))
      throw std::logic_error("Installed constructor aggregate is not retained");
    installed_retirement_owner_=owner;
    installed_retirement_reply_=std::move(completion);
    if (installed_terminal_->acknowledged) {
      deliver_installed_terminal(true);
      return;
    }
    bool accepted=false;
    try { accepted=participant->request_aggregate_retirement_(); } catch (...) {}
    // An actual cleanup refusal never grants terminal, even if some siblings
    // closed. All their native custody remains owned by the same aggregate.
    if (!accepted && installed_retirement_owner_==owner) deliver_installed_terminal(false);
  }
  bool expire_installed_retirement(const std::shared_ptr<installed_peer>& owner) {
    if (!owner || installed_retirement_owner_!=owner) return false;
    auto expired=std::move(installed_retirement_owner_);
    installed_retirement_reply_={};
    expired->deliver_cleanup({}); // Settle this frame, not native cleanup or namespace debt.
    return true;
  }
  void refuse_unlaunched_production(const std::shared_ptr<production_open>& request) {
    if (request!=installed_pending_) throw std::logic_error("Another queue aggregate owns the request");
    for (std::size_t i=0;i<request->returned_.size();++i)
      if (!request->returned_[i]) {
        request->returned(i,{},false);
        request->callback_unwound(i); // This slot was never launched by the actual caller.
      }
  }
  json installed_request(std::uint64_t peer, const json& input,
                         const std::shared_ptr<installed_peer>& owner) {
    require_installed(peer,owner);
    if (installed_pending_) throw std::logic_error("Native queue callbacks remain unsettled");
    const auto action=input.at("action").get<std::string>();
    if (installed_capture_ && installed_capture_->opened_ && installed_capture_->opened_->suspension_owner_)
      throw std::logic_error("Original observation suspension request remains pending");
    auto result=source_.production_request(peer,input);
    if (action=="status") result["ready"]=result.at("ready").get<bool>() && inventory_matches(result);
    if (action=="close") { installed_peer_.reset(); installed_peer_id_=0; }
    return result;
  }
  void suspend_production_observation(std::uint64_t peer,const json& input,
      const std::shared_ptr<installed_peer>& owner,std::function<void(const json&)> completion) {
    require_installed(peer,owner);
    const auto participant=installed_capture_;
    const auto opened=participant ? participant->opened_ : nullptr;
    if (!participant || !participant->current() || participant->configuration_closed_ ||
        !opened || opened->participant_!=participant || opened->retirement_requested_ ||
        opened->failed_ || !opened->settled_ || installed_pending_ || opened->suspension_owner_ || !completion)
      throw std::logic_error("Observation suspension has no current original completed cut");
    auto projection=source_.observation_suspend_projection(peer,input);
    projection["cohort"]=std::to_string(participant->generation_);
    auto held=std::make_shared<const json>(std::move(projection)); // Allocate before any ring effect.
    opened->suspension_projection_=std::move(held);
    opened->suspension_owner_=owner;
    opened->suspension_reply_=std::move(completion);
    finish_observation_suspension(*opened); // Pending until actual native callbacks have unwound.
  }
  void cancel_production_observation(std::uint64_t peer,const json& input,
      const std::shared_ptr<installed_peer>& owner,std::function<void(const json&)> completion) {
    require_installed(peer,owner);
    const auto participant=installed_capture_;
    const auto opened=participant ? participant->opened_ : nullptr;
    if (!participant || !participant->current() || participant->configuration_closed_ ||
        !opened || opened->participant_!=participant || opened->retirement_requested_ ||
        opened->failed_ || !opened->settled_ || installed_pending_ || opened->suspension_owner_ || !completion)
      throw std::logic_error("Observation cancellation has no current original baseline opening");
    auto projection=source_.observation_cancel_projection(peer,input);
    projection["cohort"]=std::to_string(participant->generation_);
    auto held=std::make_shared<const json>(std::move(projection)); // Allocate before any ring effect.
    opened->suspension_projection_=std::move(held);
    opened->suspension_owner_=owner;
    opened->suspension_reply_=std::move(completion);
    finish_observation_suspension(*opened); // Pending until actual native callbacks have unwound.
  }
  bool expire_observation_suspension(const std::shared_ptr<installed_peer>& owner) {
    const auto participant=installed_capture_;
    const auto opened=participant ? participant->opened_ : nullptr;
    if (!opened || !owner || opened->suspension_owner_!=owner) return false;
    auto expired=std::move(opened->suspension_owner_);
    opened->suspension_reply_={}; opened->suspension_projection_.reset();
    expired->deliver({}); // Frame settlement only; no ring/callback or full cohort ACK.
    return true;
  }
  void cancel_production(std::uint64_t peer, const json& input,
                         const std::shared_ptr<installed_peer>& owner,
                         std::function<void(const json&)> completion) {
    require_installed(peer,owner);
    auto result=source_.request(peer,input); // Original strict preparation cancel.
    if (installed_pending_) {
      installed_pending_->cancelled_=true;
      installed_cancel_=owner;
      installed_cancel_reply_=[completion=std::move(completion),result] { completion(result); };
      // No terminal projection until the original callbacks have all returned.
    } else {
      installed_peer_.reset(); installed_peer_id_=0;
      owner->deliver([&](auto&) { completion(result); });
    }
  }

  void peer_closed(std::uint64_t peer) {
    if (installed_capture_ && installed_capture_->peer_ && *installed_capture_->peer_==peer) {
      try { if (installed_capture_->request_aggregate_retirement_) installed_capture_->request_aggregate_retirement_(); } catch (...) {}
    }
    if (installed_retirement_owner_ && installed_terminal_ && installed_terminal_->peer==peer)
      expire_installed_retirement(installed_retirement_owner_);
    if (installed_capture_ && installed_capture_->opened_ && installed_capture_->opened_->suspension_owner_ &&
        installed_capture_->peer_ && *installed_capture_->peer_==peer)
      expire_observation_suspension(installed_capture_->opened_->suspension_owner_);
    if (installed(peer)) {
      if (installed_pending_) installed_pending_->cancelled_=true;
      installed_peer_.reset(); installed_peer_id_=0;
    }
    source_.peer_closed(peer);
  }
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
      const auto inventory = hs274_baseline_probe::capture_inventory(device);
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

  static void append(monitor& owner, const value& input) noexcept {
    owner.append(input);
  }

private:

  friend class ::ergoptiplus::installed_maintenance::core_endpoint;
  std::weak_ptr<::ergoptiplus::installed_maintenance::core_endpoint> maintenance_endpoint_;
  bool maintenance_before_constructor();
  bool maintenance_enroll_prepared(const std::shared_ptr<capture_participant>& participant,const json& prepared);
  std::uint64_t installed_generation_=0;
  bool installed_stopping_=false;
  std::shared_ptr<bool> installed_alive_=std::make_shared<bool>(true);
  std::shared_ptr<installed_peer> installed_peer_,installed_cancel_;
  std::uint64_t installed_peer_id_=0;
  std::shared_ptr<production_open> installed_pending_;
  std::shared_ptr<capture_participant> installed_capture_;
  std::function<void()> installed_cancel_reply_;
  struct installed_terminal_projection { json success, refused; };
  struct installed_terminal_record {
    std::uint64_t peer, generation;
    std::shared_ptr<installed_peer> preparation_owner;
    std::shared_ptr<const installed_terminal_projection> projection;
    bool acknowledged;
  };
  std::optional<installed_terminal_record> installed_terminal_;
  std::shared_ptr<installed_peer> installed_retirement_owner_;
  std::function<void(const json&)> installed_retirement_reply_;

  void deliver_installed_terminal(bool success) {
    if (!installed_terminal_ || !installed_retirement_owner_ ||
        (success && !installed_terminal_->acknowledged)) return;
    auto owner=std::move(installed_retirement_owner_);
    auto reply=std::move(installed_retirement_reply_);
    // Move the original frame/reply out before callback reentry. The frozen
    // record persists without retaining a participant/runtime strong cycle.
    const auto generation=installed_terminal_->generation;
    const auto projection=installed_terminal_->projection; // Survives sender callback reentry.
    owner->deliver_cleanup([&](auto&) {
      if (reply && installed_terminal_ && installed_terminal_->generation==generation &&
          generation==installed_generation_ && (!success || installed_terminal_->acknowledged))
        reply(success ? projection->success : projection->refused);
    });
  }
  bool finish_owned_terminal_delivery(const std::shared_ptr<capture_participant>& participant) {
    if (!owned_capture_terminal(participant)) return false;
    if (installed_terminal_ && installed_terminal_->generation==participant->generation_ &&
        participant->peer_ && installed_terminal_->peer==*participant->peer_) {
      if (!installed_terminal_->acknowledged) return false;
      deliver_installed_terminal(true);
    }
    return true;
  }


  friend class ::krbn::core_service::daemon::device_grabber;
  bool observe_owned_capture_retirement(const std::shared_ptr<capture_participant>& participant,
                                          std::function<void()> progress) {
    if (!participant || participant->receiver_!=this || participant->generation_!=installed_generation_ ||
        !progress || participant->progress_) return false;
    participant->progress_=std::move(progress);
    return true;
  }
  bool request_owned_capture_retirement(const std::shared_ptr<capture_participant>& participant) {
    if (!participant || participant->receiver_!=this || participant->generation_!=installed_generation_ ||
        installed_capture_!=participant) return false;
    if (participant->retirement_requested_) return true;
    installed_stopping_=true;
    participant->retirement_requested_=true;
    // Constructor identity, not a nullable lease, closes the authentic source
    // preparation and any REAL ring it subsequently acquired.
    if (participant->peer_) source_.peer_closed(*participant->peer_);
    participant->source_closed_=true;
    if (const auto opened=participant->opened_) {
      opened->retirement_requested_=true;
      opened->cancelled_=true;
      opened->ring_closed_=true;
      if (!opened->pending_) installed_pending_.reset();
    }
    installed_peer_.reset(); installed_peer_id_=0;
    if (participant->progress_) participant->progress_();
    return true;
  }
  bool owned_capture_retired(const std::shared_ptr<capture_participant>& participant) const {
    if (!participant || participant->receiver_!=this || participant->generation_!=installed_generation_ ||
        !participant->retirement_requested_ || !participant->source_closed_ || installed_pending_) return false;
    if (const auto opened=participant->opened_)
      if (!opened->ring_closed_ || opened->pending_ || !opened->settled_ || !opened->callbacks_unwound()) return false;
    return participant->runtime_retention_.get()==this;
  }
  bool owned_capture_terminal(const std::shared_ptr<capture_participant>& participant) const {
    return owned_capture_retired(participant) && participant->published_ && participant->finalized_ &&
      participant->configuration_->retired() && participant->namespace_->retired();
  }
  bool complete_owned_capture_retirement(const std::shared_ptr<capture_participant>& participant) {
    if (!owned_capture_retired(participant)) return false;
    // Called only after the real aggregate proves every participant callback
    // settled. The actual captured configuration's native debts precede SH.
    if (!participant->configuration_->release() || !participant->configuration_->retired()) return false;
    // Namespace SH is the last resource released, with actual ACK.
    if (participant->published_ && !participant->namespace_->release_after_retirement()) return false;
    if (participant->published_ && !participant->namespace_->retired()) return false;
    participant->finalized_=true;
    // This private method is called only by Device after all actual participant
    // fences; the SH close ACK above is mandatory before publishing this bit.
    if (installed_terminal_ && installed_terminal_->generation==participant->generation_ &&
        participant->peer_ && installed_terminal_->peer==*participant->peer_)
      installed_terminal_->acknowledged=true;
    participant->opened_.reset();
    // Device destruction may still have actual callback work. The aggregate
    // continues to retain it while delivering its native terminal receipt.
    participant->device_retention_.reset();
    installed_capture_.reset();
    installed_stopping_=false;
    return true;
  }

  void finish_constructor_retirement(const std::shared_ptr<capture_participant>& participant) {
    if (!participant || participant->receiver_!=this || participant->generation_!=installed_generation_ ||
        !participant->partial_requested_ || participant->partial_failed_ || participant->device_retention_ ||
        participant->opened_ || participant->peer_ || participant->finalized_) return;
    if (!participant->console_->retired() || !participant->broker_->retired()) return;
    if (!participant->configuration_->release() || !participant->configuration_->retired()) {
      participant->partial_failed_=true;
      return;
    }
    if (!participant->namespace_->release_after_retirement() || !participant->namespace_->retired()) {
      participant->partial_failed_=true;
      return;
    }
    participant->source_closed_=true;
    participant->finalized_=true;
    installed_capture_.reset();
    installed_stopping_=false;
  }

  std::shared_ptr<capture_participant> require_configuration_request(std::uint64_t peer,
      const json& input,const std::shared_ptr<installed_peer>& owner,const char* action,std::size_t fields) const {
    require_installed(peer,owner);
    const auto participant=installed_capture_;
    if (!input.is_object() || input.size()!=fields || !input.contains("version") ||
        !input.at("version").is_number_unsigned() || input.at("version")!=1u ||
        !input.contains("action") || input.at("action")!=action ||
        !input.contains("incarnation") || !input.contains("preparation") ||
        !installed_terminal_ || installed_terminal_->peer!=peer || !participant ||
        !participant->current() || participant->configuration_closed_ ||
        input.at("incarnation")!=installed_terminal_->projection->success.at("incarnation") ||
        input.at("preparation")!=installed_terminal_->projection->success.at("preparation"))
      throw std::logic_error("Configuration request has no same installed preparation");
    if (fields==7 && (!input.contains("configuration_generation") || !input.contains("configuration_sha256") ||
                     !input.contains("mode")))
      throw std::logic_error("Configuration request fields differ from the owned mode contract");
    return participant;
  }
  json configuration_projection(const std::shared_ptr<capture_participant>& participant) const {
    auto result=json{{"version",1u},{"kind","configuration_pending"},
      {"incarnation",installed_terminal_->projection->success.at("incarnation")},
      {"preparation",installed_terminal_->projection->success.at("preparation")}};
    const auto snapshot=participant->configuration_snapshot_;
    if (snapshot && snapshot->current()) {
      result["kind"]="configuration_consumed";
      result["configuration_generation"]=snapshot->generation();
      result["configuration_sha256"]=snapshot->sha256();
      result["cohort"]=std::to_string(participant->generation_);
    }
    return result;
  }
  // Defined beside the original Device, where the actual opaque terminal type
  // is complete. No caller Boolean or projection substitutes that receipt.
  bool finish_configuration_off(const std::shared_ptr<configuration_effect_request>& request);
  void finish_configuration_effect(const std::shared_ptr<configuration_effect_request>& request,bool applied) {
    const auto participant=request->participant_;
    if (participant->configuration_pending_!=request) return;
    const bool valid=applied && request->current();
    request->native_revoked_.store(true,std::memory_order_release);
    participant->configuration_pending_.reset(); // Before original sender callback reentry.
    if (!valid) {
      request->owner_->deliver({});
      if (participant->request_aggregate_retirement_) participant->request_aggregate_retirement_();
      return;
    }
    const auto projection=configuration_projection(participant);
    const auto reply=request->completion_;
    request->owner_->deliver([participant,request,projection,reply](auto&) {
      if (!participant->configuration_closed_ && participant->current() && request->snapshot_->current() &&
          participant->configuration_sequence_==request->sequence_ && reply) reply(projection);
    });
  }
  void require_installed(std::uint64_t peer,const std::shared_ptr<installed_peer>& owner) const {
    if (!installed(peer) || !owner || !installed_peer_->same_socket(*owner) ||
        !installed_peer_->current() || !owner->current())
      throw std::logic_error("Installed request belongs to another native socket cohort");
  }
  void finish_observation_suspension(production_open& pending) {
    if (!pending.suspension_owner_ || !pending.callbacks_unwound()) return;
    const auto participant=pending.participant_;
    const auto runtime_owner=pending.runtime_retention_;
    const auto projection=pending.suspension_projection_;
    auto owner=std::move(pending.suspension_owner_);
    auto reply=std::move(pending.suspension_reply_);
    if (!participant || participant!=installed_capture_ || participant->opened_.get()!=&pending ||
        participant->retirement_requested_ || !participant->current() || pending.failed_ ||
        !projection || !owner->current() || !installed_peer_ || !installed_peer_->same_socket(*owner)) {
      owner->deliver({});
      if (participant && participant->request_aggregate_retirement_) participant->request_aggregate_retirement_();
      return;
    }
    try {
      if (projection->at("kind")=="observation_cancelled")
        source_.finish_observation_cancellation(pending.peer_,*projection);
      else
        source_.finish_observation_suspension(pending.peer_,*projection);
      pending.ring_closed_=true;
      pending.snapshots_.clear(); pending.native_current_={}; pending.native_retention_.reset();
      pending.suspension_projection_.reset();
      participant->opened_.reset(); // Same preparation/cohort remains. New open must acquire a fresh ring.
      if (!owner->deliver([participant,projection,reply](auto&) {
            if (participant->current() && !participant->configuration_closed_ && reply) reply(*projection);
          }) && participant->request_aggregate_retirement_) participant->request_aggregate_retirement_();
    } catch (...) {
      owner->deliver({});
      if (participant->request_aggregate_retirement_) participant->request_aggregate_retirement_();
    }
  }
  void finish_production(production_open& pending) {
    if (installed_pending_.get()!=&pending) { pending.request_->deliver({}); return; }
    if (pending.cancelled_) {
      pending.request_->deliver({});
      auto cancel=std::move(installed_cancel_);
      auto reply=std::move(installed_cancel_reply_);
      installed_pending_.reset(); installed_peer_.reset(); installed_peer_id_=0;
      if (cancel && reply) cancel->deliver([reply](auto&) { reply(); });
      return;
    }
    if (pending.failed_ || !pending.native_current_ || !pending.native_current_() ||
        !pending.request_->current() || !inventory_matches(source_.request(pending.peer_,{{"version",1u},{"action","status"}}))) {
      source_.peer_closed(pending.peer_);
      pending.request_->deliver({});
      installed_pending_.reset(); installed_peer_.reset(); installed_peer_id_=0;
      return;
    }
    const auto expected_peer=installed_peer_;
    try {
      const auto response=source_.finish_production(pending.peer_,pending.snapshots_);
      if (!pending.native_current_() || !pending.request_->current())
        throw std::logic_error("Native cohort changed before installed publication");
      auto reply=pending.completion_;
      // Clear pending only after all actual native returns. Reentry cannot
      // operate on an unfinished interval or finish a later aggregate.
      installed_pending_.reset();
      if (!pending.request_->deliver([&](auto&) { reply(response); }) && installed_peer_==expected_peer) {
        source_.peer_closed(pending.peer_);
        installed_peer_.reset(); installed_peer_id_=0;
      }
    } catch (...) {
      // The original reply may reenter and create a successor interval.
      if (installed_peer_==expected_peer) {
        source_.peer_closed(pending.peer_);
        installed_pending_.reset(); installed_peer_.reset(); installed_peer_id_=0;
      }
      pending.request_->deliver({});
      // Refuse in the original callback; never throw across its native signal
      // boundary or manufacture an installed response after a failed send.
    }
  }

  bool inventory_matches(const json& status) const {
    std::vector<std::uint64_t> registrations;
    for (const auto& monitor : status.at("monitors")) registrations.push_back(decimal(monitor.at("device")));
    return inventory_.matches(registrations);
  }

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

  // Bound producer backlog and per-response work independently of diagnostic fixtures;
  // actual wire size must additionally pass the receiver's message-size gate.
  source_type source_;
  inventory_type inventory_;
  inline static runtime* active_ = nullptr;
};
inline runtime::configuration_effect_request::configuration_effect_request(
    std::shared_ptr<capture_participant> participant,std::shared_ptr<const configuration_snapshot> snapshot,
    std::shared_ptr<installed_peer> owner,std::uint64_t sequence,int mode,std::function<void(const json&)> completion)
  :participant_(std::move(participant)),snapshot_(std::move(snapshot)),owner_(std::move(owner)),
   sequence_(sequence),mode_(mode),native_console_(participant_->console_),
   native_namespace_(participant_->namespace_),native_broker_(participant_->broker_),completion_(std::move(completion)) {}
inline bool runtime::configuration_effect_request::native_current() const {
  if (native_revoked_.load(std::memory_order_acquire) || !snapshot_ || !snapshot_->current() ||
      !owner_ || !owner_->current() || !native_console_ || !native_console_->current() ||
      !native_namespace_ || !native_namespace_->current() || !native_broker_) return false;
  // The original VHD initializer separately retains the exact native connected
  // generation. This immutable request gate cannot replace that issuer.
  return (mode_==0 || native_broker_->current()) && !native_revoked_.load(std::memory_order_acquire);
}
inline bool runtime::configuration_effect_request::current() const {
  return !native_revoked_.load(std::memory_order_acquire) && participant_ &&
    participant_->configuration_pending_.get()==this &&
    participant_->configuration_sequence_==sequence_ && !participant_->configuration_closed_ &&
    participant_->current() && participant_->configuration_snapshot_==snapshot_ &&
    snapshot_ && snapshot_->current() && owner_ && owner_->current();
}
} // namespace hs274_stream_protocol
