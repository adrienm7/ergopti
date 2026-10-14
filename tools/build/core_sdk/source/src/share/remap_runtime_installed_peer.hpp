// Original Core socket/frame capability for installed capture.
// The fixed native cohort predicate is necessary, but never mints this owner.
#pragma once
#include "remap_runtime_auth.hpp"
#include "remap_runtime_installed_capture.hpp"
#include "OwnedRuntimeMaintenanceLineage.hpp"
#include <memory>
#include <mutex>
#include <utility>

namespace hs274_stream_protocol { class runtime; }
namespace ergoptiplus::remap::auth { class console_control_owner; }
namespace ergoptiplus::installed_capture {
class core_peer_owner final {
  using socket_type = ergoptiplus::remap::auth::socket_lifetime;
  using scope_type = ergoptiplus::remap::auth::frame_scope;
  using ticket_type = ergoptiplus::remap::auth::delivery_ticket;
public:
  core_peer_owner(const core_peer_owner&) = delete;
  core_peer_owner& operator=(const core_peer_owner&) = delete;
  static std::shared_ptr<core_peer_owner> acquire(scope_type& scope) {
    if (scope.view().kind() != ergoptiplus::remap::auth::frame_kind::request ||
        !scope.permit("hs274_capture")) return nullptr;
    auto result = std::shared_ptr<core_peer_owner>(new core_peer_owner(scope.socket_));
    result->native_ = result->socket_->retain_task(socket_type::task_kind::native);
    result->dispatch_ = result->socket_->retain_task(socket_type::task_kind::dispatch);
    if (!result->native_ || !result->dispatch_ || !result->current()) return nullptr;
    const auto original = result->native_observation();
    if (!original || !result->capture_initial_cleanup_actor(*original)) return nullptr;
    result->issuer_lineage_ = ergoptiplus::installed_maintenance::issuer_lineage::capture_original(*original);
    if (!result->issuer_lineage_ || !result->current()) return nullptr;
    result->ticket_ = scope.handoff();
    if (!result->ticket_ || !result->current()) return nullptr;
    return result;
  }
  bool current() const {
    if (cleanup_only_) return false; // Original terminal custody never admits a fresh effect.
    if (!socket_->current()) return false;
    const auto observation = socket_->installed_observation();
    return observation && remote_installed_peer_matches(*observation) && socket_->current();
  }
  bool same_socket(const core_peer_owner& other) const noexcept {
    return socket_.get() == other.socket_.get();
  }
  bool deliver(const std::function<void(scope_type&)>& continuation) {
    // A request debt cannot last until peer_closed: the original socket close
    // notification itself waits for these debts. Keep only socket identity
    // after this request's native work and delivery have actually settled.
    struct request_settlement {
      core_peer_owner& owner;
      ~request_settlement() { owner.settle_request_debts(); }
    } settlement{*this};
    if (!continuation || !current()) return false;
    std::shared_ptr<ticket_type> ticket;
    {
      std::lock_guard<std::mutex> lock(delivery_mutex_);
      ticket = std::exchange(ticket_, nullptr);
    }
    if (!ticket) return false;
    bool delivered = false;
    const bool consumed = ticket->consume([&](scope_type& scope) {
      if (scope.socket_.get() == socket_.get() && current() && scope.permit("hs274_capture")) {
        continuation(scope);
        delivered = true;
      }
    });
    return consumed && delivered;
  }
private:
  friend class ::hs274_stream_protocol::runtime;
  friend class ::ergoptiplus::remap::auth::console_control_owner;
  friend class ::ergoptiplus::installed_maintenance::core_endpoint;
  std::optional<ergoptiplus::remap::auth::detail::peer_observation> native_observation() const {
    if (!current()) return std::nullopt;
    auto observed=socket_->installed_observation();
    if (!observed || !current()) return std::nullopt;
    return observed;
  }

  bool capture_initial_cleanup_actor(const ergoptiplus::remap::auth::detail::peer_observation& observation) {
    proc_bsdinfo child{},parent{},child_after{},parent_after{};
    if (!detail::process(observation.pid,child) || child.pbi_uid!=observation.euid ||
        !detail::process(static_cast<pid_t>(child.pbi_ppid),parent) || parent.pbi_uid!=observation.euid ||
        !detail::headless_parent(static_cast<pid_t>(parent.pbi_pid)) ||
        !detail::process(observation.pid,child_after) || !detail::same_birth(child,child_after) ||
        child_after.pbi_ppid!=parent.pbi_pid ||
        !detail::process(static_cast<pid_t>(parent.pbi_pid),parent_after) ||
        !detail::same_birth(parent,parent_after) || !current()) return false;
    initial_cleanup_actor_=observation;
    initial_cli_=child;
    initial_headless_=parent;
    return true;
  }
  bool same_initial_cleanup_actor(const ergoptiplus::remap::auth::detail::peer_observation& fresh) const {
    if (!initial_cleanup_actor_) return false;
    const auto& original=*initial_cleanup_actor_;
    if (fresh.pid!=original.pid || fresh.euid!=original.euid || fresh.egid!=original.egid ||
        fresh.self_euid!=original.self_euid || fresh.self_egid!=original.self_egid ||
        std::memcmp(&fresh.token,&original.token,sizeof(fresh.token))!=0 ||
        fresh.peer.role!=original.peer.role || fresh.peer.team!=original.peer.team || fresh.peer.leaf!=original.peer.leaf ||
        fresh.self.role!=original.self.role || fresh.self.team!=original.self.team || fresh.self.leaf!=original.self.leaf) return false;
    proc_bsdinfo child{},parent{};
    return detail::process(fresh.pid,child) && detail::same_birth(initial_cli_,child) &&
        child.pbi_ppid==initial_headless_.pbi_pid &&
        detail::process(static_cast<pid_t>(initial_headless_.pbi_pid),parent) &&
        detail::same_birth(initial_headless_,parent) && parent.pbi_uid==fresh.euid;
  }
  bool retain_cleanup_namespace(const std::shared_ptr<core_namespace_hold>& hold) {
    if (!hold || cleanup_namespace_ || cleanup_only_ || !current() || !hold->current()) return false;
    const auto observed=socket_->installed_observation();
    if (!observed || !same_initial_cleanup_actor(*observed) || !current() || !hold->current()) return false;
    cleanup_namespace_=hold; // The genuine constructor owns this same hold before effects.
    return true;
  }
  bool cleanup_current() const {
    if (!cleanup_namespace_ || !socket_->current()) return false;
    const auto before=socket_->installed_observation();
    if (!before || !same_initial_cleanup_actor(*before)) return false;
    const auto retained=cleanup_namespace_;
    bool matched=retained->cleanup_current(*before);
    if (!matched) {
      const auto closed=retained->closed_custody_observation();
      matched=closed && closed->matches(*before);
    }
    if (!matched || !socket_->current()) return false;
    const auto after=socket_->installed_observation();
    if (!after || !same_initial_cleanup_actor(*after)) return false;
    if (retained->cleanup_current(*after)) return socket_->current();
    const auto closed=retained->closed_custody_observation();
    return closed && closed->matches(*after) && socket_->current();
  }
  static std::shared_ptr<core_peer_owner> acquire_cleanup(scope_type& scope,
      const std::shared_ptr<core_peer_owner>& original) {
    if (!original || scope.socket_.get()!=original->socket_.get() ||
        scope.view().kind()!=ergoptiplus::remap::auth::frame_kind::request ||
        !scope.permit("hs274_capture") || !original->cleanup_current()) return nullptr;
    auto result=std::shared_ptr<core_peer_owner>(new core_peer_owner(original->socket_));
    result->cleanup_only_=true;
    result->initial_cleanup_actor_=original->initial_cleanup_actor_;
    result->initial_cli_=original->initial_cli_;
    result->initial_headless_=original->initial_headless_;
    result->cleanup_namespace_=original->cleanup_namespace_;
    result->issuer_lineage_=original->issuer_lineage_;
    result->native_=result->socket_->retain_task(socket_type::task_kind::native);
    result->dispatch_=result->socket_->retain_task(socket_type::task_kind::dispatch);
    if (!result->native_ || !result->dispatch_ || !result->cleanup_current()) return nullptr;
    result->ticket_=scope.handoff();
    if (!result->ticket_ || !result->cleanup_current()) return nullptr;
    return result;
  }
  bool deliver_cleanup(const std::function<void(scope_type&)>& continuation) {
    struct request_settlement {
      core_peer_owner& owner;
      ~request_settlement() { owner.settle_request_debts(); }
    } settlement{*this};
    if (!cleanup_only_ || !continuation || !cleanup_current()) return false;
    std::shared_ptr<ticket_type> ticket;
    {
      std::lock_guard<std::mutex> held(delivery_mutex_);
      ticket=std::exchange(ticket_,nullptr);
    }
    if (!ticket) return false;
    bool delivered=false;
    const bool consumed=ticket->consume([&](scope_type& scope) {
      if (scope.socket_.get()==socket_.get() && cleanup_current() && scope.permit("hs274_capture")) {
        continuation(scope);
        delivered=true;
      }
    });
    return consumed && delivered;
  }
  void settle_request_debts() {
    std::shared_ptr<socket_type::task_debt> native,dispatch;
    {
      std::lock_guard<std::mutex> lock(delivery_mutex_);
      native=std::exchange(native_,nullptr);
      dispatch=std::exchange(dispatch_,nullptr);
    }
    // Original debt destructors run outside our mutex: their close progress
    // may enqueue original notification work and must not deadlock reentry.
  }
  explicit core_peer_owner(std::shared_ptr<socket_type> socket) : socket_(std::move(socket)) {}
  const std::shared_ptr<socket_type> socket_;
  std::optional<ergoptiplus::remap::auth::detail::peer_observation> initial_cleanup_actor_;
  proc_bsdinfo initial_cli_{},initial_headless_{};
  std::shared_ptr<core_namespace_hold> cleanup_namespace_;
  bool cleanup_only_=false;
  std::shared_ptr<const ergoptiplus::installed_maintenance::issuer_lineage> issuer_lineage_;
  std::shared_ptr<socket_type::task_debt> native_;
  std::shared_ptr<socket_type::task_debt> dispatch_;
  std::shared_ptr<ticket_type> ticket_;
  std::mutex delivery_mutex_;
};
} // namespace ergoptiplus::installed_capture
