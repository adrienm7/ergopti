// Original Console transport control admission and callback retirement.
// This owner never proves Console process or socket retirement.
#pragma once
#include "remap_runtime_auth.hpp"
#include "remap_runtime_installed_peer.hpp"
#include "InstalledUserConfiguration.hpp"
#include <libproc.h>
#include <sys/proc_info.h>
#include <cstring>
#include <memory>
#include <mutex>
#include <optional>
#include <pqrs/dispatcher/extra/dispatcher_client.hpp>

namespace ergoptiplus::remap::auth {
class console_control_owner final : public pqrs::dispatcher::extra::dispatcher_client,
                                    public std::enable_shared_from_this<console_control_owner> {
  friend class krbn::core_service::daemon::receiver;
  friend class ::hs274_stream_protocol::runtime;
  using socket_type = socket_lifetime;
  struct birth final {
    pid_t pid;
    std::uint64_t seconds;
    std::uint64_t microseconds;
    bool operator==(const birth&) const = default;
  };
public:
  class task final {
    friend class console_control_owner;
  public:
    task(const task&) = delete;
    task& operator=(const task&) = delete;
    ~task() { if (armed_) owner_->release(); }
    bool current() const { return owner_->current(); }
  private:
    explicit task(std::shared_ptr<console_control_owner> owner) : owner_(std::move(owner)) {}
    const std::shared_ptr<console_control_owner> owner_;
    bool armed_ = false;
  };
  console_control_owner(const console_control_owner&) = delete;
  console_control_owner& operator=(const console_control_owner&) = delete;
  ~console_control_owner() override { detach_from_dispatcher(); }
  bool matches_peer(const std::shared_ptr<pqrs::unix_domain_stream::server>& server,
                    std::uint64_t peer_id) {
    return server && server_.lock().get() == server.get() && peer_id == peer_id_ && current();
  }
  bool same_control(const console_control_owner& other) const noexcept { return this == &other; }
  bool matches_frame(frame_scope& scope) {
    return scope.socket_.get() == socket_.get() &&
           scope.view().peer_role() == identity::role::console && current();
  }
  bool current() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_ || failed_) return false;
    }
    try {
      if (!attached() || !native_current()) { refuse(); return false; }
    } catch (...) { refuse(); return false; }
    std::lock_guard<std::mutex> lock(mutex_);
    return !stopping_ && !failed_;
  }
  std::shared_ptr<task> retain_task() {
    if (!current()) return nullptr;
    auto result = std::shared_ptr<task>(new task(shared_from_this()));
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_ || failed_) return nullptr;
      if (pending_ == std::numeric_limits<std::uint64_t>::max()) {
        failed_ = true;
        stopping_ = true;
        return nullptr;
      }
      ++pending_;
      result->armed_ = true;
    }
    if (!current()) return nullptr;
    return result;
  }
  // Pending admission closure only. Existing native requests retain their task.
  void request_retirement() noexcept {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopping_ = true;
    }
    notify_retirement();
  }
  // A queued progress hint, never a native process/cohort retirement receipt.
  bool observe_retirement(std::function<void()> observer) {
    if (!observer) return false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (observer_ || notification_claimed_ || failed_) return false;
      observer_ = std::move(observer);
    }
    notify_retirement();
    std::lock_guard<std::mutex> lock(mutex_);
    return !failed_;
  }
  bool retired() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return stopping_ && !failed_ && pending_ == 0;
  }
private:
  // Private constructor admission only. The original runtime must own and
  // publish this exact hold before any installed device constructor effect.
  std::shared_ptr<ergoptiplus::installed_capture::core_namespace_hold> retain_core_namespace() {
    try {
      if (!current()) return nullptr;
      auto frame = socket_->retain_task(socket_type::task_kind::native);
      const auto observed = socket_->installed_observation();
      if (!frame || !observed || !native_current()) return nullptr;
      auto hold = ergoptiplus::installed_capture::core_namespace_hold::acquire_console(*observed);
      return hold && hold->current() && current() ? hold : nullptr;
    } catch (...) { return nullptr; }
  }
  // Constructor-only native namespace loan. The original runtime owns this
  // same holder before parsing or enabling any device/engine effect.
  std::shared_ptr<ergoptiplus::installed_configuration::owner> retain_configuration_namespace() {
    try {
      if (!current()) return nullptr;
      auto frame = socket_->retain_task(socket_type::task_kind::native);
      const auto observed = socket_->installed_observation();
      if (!frame || !observed || !native_current()
          || !ergoptiplus::installed_capture::remote_installed_console_matches(*observed)) return nullptr;
      if (configuration_owner_) {
        return configuration_owner_->namespace_current() && native_current() && current() ? configuration_owner_ : nullptr;
      }
      auto holder = ergoptiplus::installed_configuration::owner::acquire_peer(observed->euid);
      if (!holder) return nullptr;
      if (!holder->namespace_current() || !native_current() || !current()) {
        // No effects or borrower have been published. Refused close stays
        // self-custodied in the original native holder, never a cleanup ACK.
        holder->release(); return nullptr;
      }
      configuration_owner_ = holder;
      return holder;
    } catch (...) { return nullptr; }
  }
  bool matches_installed_peer(const ergoptiplus::installed_capture::core_peer_owner& peer) {
    try {
      namespace installed = ergoptiplus::installed_capture;
      if (!current() || !peer.current()) return false;
      auto frame = socket_->retain_task(socket_type::task_kind::native);
      const auto console = socket_->installed_observation();
      const auto cli = peer.native_observation();
      if (!frame || !console || !cli || !installed::remote_installed_console_matches(*console) ||
          !installed::remote_installed_peer_matches(*cli)) return false;
      proc_bsdinfo console_child{}, cli_child{}, console_parent{}, cli_parent{};
      proc_bsdinfo final_console{}, final_cli{}, final_parent{};
      if (!installed::detail::process(console->pid, console_child) ||
          !installed::detail::process(cli->pid, cli_child) ||
          console_child.pbi_ppid != cli_child.pbi_ppid || console->euid != cli->euid ||
          !installed::detail::process(static_cast<pid_t>(console_child.pbi_ppid), console_parent) ||
          !installed::detail::process(static_cast<pid_t>(cli_child.pbi_ppid), cli_parent) ||
          !installed::detail::same_birth(console_parent, cli_parent) ||
          !installed::detail::process(console->pid, final_console) ||
          !installed::detail::same_birth(console_child, final_console) ||
          !installed::detail::process(cli->pid, final_cli) ||
          !installed::detail::same_birth(cli_child, final_cli) ||
          final_console.pbi_ppid != console_parent.pbi_pid || final_cli.pbi_ppid != console_parent.pbi_pid ||
          !installed::detail::process(static_cast<pid_t>(console_parent.pbi_pid), final_parent) ||
          !installed::detail::same_birth(console_parent, final_parent)) return false;
      return native_current() && current() && peer.current();
    } catch (...) { return false; }
  }
  static std::optional<birth> observe_birth(pid_t pid) noexcept {
    proc_bsdinfo information{};
    if (pid <= 1 || ::proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, sizeof(information)) != sizeof(information) ||
        information.pbi_pid != static_cast<std::uint32_t>(pid)) return std::nullopt;
    return birth{pid, information.pbi_start_tvsec, information.pbi_start_tvusec};
  }
  // Called only by the actual receiver while its authorized frame is alive.
  static std::shared_ptr<console_control_owner> acquire(
      frame_scope& scope, const std::shared_ptr<pqrs::unix_domain_stream::server>& server,
      std::uint64_t peer_id, std::weak_ptr<pqrs::dispatcher::dispatcher> dispatcher) {
    if (scope.view().kind() != frame_kind::request ||
        scope.view().peer_role() != identity::role::console ||
        !server || !scope.permit("start_device_grabber")) return nullptr;
    const auto socket = scope.socket_;
    if (!socket) return nullptr;
    auto debt = socket->retain_task(socket_type::task_kind::native);
    if (!debt || !socket->current()) return nullptr;
    const auto before = socket->installed_observation();
    if (!before || before->self.role != identity::role::core || before->self_euid != 0 ||
        before->peer.role != identity::role::console || before->euid == 0 ||
        before->euid != scope.view().peer_uid()) return nullptr;
    const auto process = observe_birth(before->pid);
    if (!process) return nullptr;
    auto result = std::shared_ptr<console_control_owner>(
        new console_control_owner(socket, *before, *process, server, peer_id, std::move(dispatcher)));
    return result->current() ? result : nullptr;
  }
  bool native_current() {
    auto debt = socket_->retain_task(socket_type::task_kind::native);
    if (!debt || !socket_->current()) return false;
    const auto before = observe_birth(birth_.pid);
    const auto observation = socket_->installed_observation();
    const auto after = observe_birth(birth_.pid);
    return before && after && *before == birth_ && *after == birth_ && observation &&
           observation->pid == native_.pid && observation->euid == native_.euid &&
           observation->egid == native_.egid && observation->peer.role == native_.peer.role &&
           observation->self.role == native_.self.role && observation->self_euid == native_.self_euid &&
           observation->peer.leaf == native_.peer.leaf && observation->self.leaf == native_.self.leaf &&
           std::memcmp(&observation->token, &native_.token, sizeof(native_.token)) == 0 && socket_->current();
  }
  console_control_owner(std::shared_ptr<socket_type> socket, detail::peer_observation native, birth process,
                        std::weak_ptr<pqrs::unix_domain_stream::server> server, std::uint64_t peer_id,
                        std::weak_ptr<pqrs::dispatcher::dispatcher> dispatcher)
      : dispatcher_client(std::move(dispatcher)),
        socket_(std::move(socket)), native_(std::move(native)), birth_(process),
        server_(std::move(server)), peer_id_(peer_id) {}
  void refuse() noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
  }
  void release() noexcept {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (pending_ == 0) failed_ = true;
      else --pending_;
    }
    notify_retirement();
  }
  void notify_retirement() noexcept {
    try {
      std::function<void()> observer;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!stopping_ || failed_ || pending_ != 0 || !observer_ || notification_claimed_) return;
        observer = std::move(observer_);
        notification_claimed_ = true;
      }
      auto self = shared_from_this();
      if (!enqueue_to_dispatcher([self, observer = std::move(observer)] {
            try { if (self->retired()) observer(); }
            catch (...) { std::lock_guard<std::mutex> lock(self->mutex_); self->failed_ = true; }
          })) {
        std::lock_guard<std::mutex> lock(mutex_);
        failed_ = true;
      }
    } catch (...) {
      std::lock_guard<std::mutex> lock(mutex_);
      failed_ = true;
    }
  }
  std::shared_ptr<ergoptiplus::installed_configuration::owner> configuration_owner_;
  const std::shared_ptr<socket_type> socket_;
  const detail::peer_observation native_;
  const birth birth_;
  const std::weak_ptr<pqrs::unix_domain_stream::server> server_;
  const std::uint64_t peer_id_;
  mutable std::mutex mutex_;
  std::uint64_t pending_ = 0;
  bool stopping_ = false;
  bool failed_ = false;
  std::function<void()> observer_;
  bool notification_claimed_ = false;
};
} // namespace ergoptiplus::remap::auth
