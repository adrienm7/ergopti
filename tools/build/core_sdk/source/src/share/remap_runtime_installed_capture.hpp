// tools/build/remap_runtime_installed_capture.hpp
// Fixed installed CLI custody; no caller receipt supplies production authority.
#pragma once

#include "OwnedRuntimeLifecycleContract.h"
#include "InstalledRuntimePublisher.hpp"
#include "remap_runtime_auth.hpp"
#include "InstalledRuntimeProcessIdentity.hpp"
#include <bsm/libbsm.h>
#include <sys/proc_info.h>
#include <Security/Security.h>
#include <fcntl.h>
#include <libproc.h>
#include <sys/acl.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <array>
#include <algorithm>
#include <mutex>
#include <cerrno>
#include <cstring>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace hs274_stream_protocol { class runtime; }
namespace ergoptiplus::remap::auth { class console_control_owner; }

namespace ergoptiplus::installed_capture {

// This is a predicate on a fresh native socket observation, never an owner factory.
// The Core-only friend retains the original socket/token and validation mutex.
inline bool remote_installed_peer_matches(const ergoptiplus::remap::auth::detail::peer_observation& observation) {
  using role = ergoptiplus::remap::identity::role;
  if (getuid() != 0 || geteuid() != 0 || observation.self_euid != 0 || observation.euid == 0 ||
      observation.self.role != role::core || observation.peer.role != role::cli ||
      audit_token_to_pid(observation.token) != observation.pid || audit_token_to_euid(observation.token) != observation.euid) return false;
  auto publisher = ergoptiplus::installed_publisher::owner::acquire();
  if (!publisher) return false;
  auto check = [&]() {
    const auto& approved = publisher->observed_leaf();
    if (observation.self.leaf != approved || observation.peer.leaf != approved || !publisher->permits_installed_images()) return false;
    proc_bsdinfo child{}, parent{}, self{}, final_child{}, final_parent{}, final_self{};
    if (!detail::process(observation.pid, child) || child.pbi_uid != observation.euid ||
        !detail::process(static_cast<pid_t>(child.pbi_ppid), parent) || parent.pbi_uid != observation.euid ||
        !detail::process(getpid(), self) || self.pbi_uid != 0 || !detail::headless_parent(static_cast<pid_t>(parent.pbi_pid))) return false;
    const auto actual_child = detail::live_leaf(observation.pid, "com.ergoptiplus.remap.cli",
        "/Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli");
    const auto actual_parent = detail::live_leaf(static_cast<pid_t>(parent.pbi_pid), "com.ergoptiplus.app");
    const auto actual_self = detail::live_leaf(getpid(), "com.ergoptiplus.remap.core",
        "/Library/Application Support/ErgoptiPlus/Runtime/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core");
    if (!actual_child || !actual_parent || !actual_self || *actual_child != approved || *actual_parent != approved || *actual_self != approved) return false;
    constexpr const char* lock_path = "/Library/Application Support/ErgoptiPlus/.runtime-service-lifecycle-lock";
    const int named = open(lock_path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK);
    if (named < 0) return false;
    struct stat lock{}, final_lock{};
    vnode_fdinfowithpath first{}, last{};
    auto matches = [&](const vnode_fdinfowithpath& native) {
      const auto& value = native.pvip.vip_vi.vi_stat;
      return std::memchr(native.pvip.vip_path, '\0', sizeof(native.pvip.vip_path)) &&
          std::strcmp(native.pvip.vip_path, lock_path) == 0 &&
          value.vst_dev == static_cast<std::uint32_t>(lock.st_dev) && value.vst_ino == static_cast<std::uint64_t>(lock.st_ino) &&
          value.vst_mode == lock.st_mode && value.vst_uid == lock.st_uid && value.vst_gid == lock.st_gid &&
          value.vst_nlink == lock.st_nlink && value.vst_size == static_cast<std::int64_t>(lock.st_size) &&
          value.vst_mtime == static_cast<std::uint64_t>(lock.st_mtimespec.tv_sec) &&
          value.vst_mtimensec == static_cast<std::uint64_t>(lock.st_mtimespec.tv_nsec) &&
          value.vst_ctime == static_cast<std::uint64_t>(lock.st_ctimespec.tv_sec) &&
          value.vst_ctimensec == static_cast<std::uint64_t>(lock.st_ctimespec.tv_nsec);
    };
    bool accepted = fstat(named, &lock) == 0 && S_ISREG(lock.st_mode) && lock.st_uid == 0 &&
        (lock.st_mode & 07777) == 0644 && lock.st_nlink == 1 && lock.st_size == 0 && detail::empty_acl(named) &&
        proc_pidfdinfo(observation.pid, ERGOPTI_OWNED_RUNTIME_LIFECYCLE_CHILD_DESCRIPTOR,
            PROC_PIDFDVNODEPATHINFO, &first, sizeof(first)) == static_cast<int>(sizeof(first)) && matches(first) &&
        detail::process(observation.pid, final_child) && detail::same_birth(child, final_child) && final_child.pbi_ppid == parent.pbi_pid &&
        detail::process(static_cast<pid_t>(parent.pbi_pid), final_parent) && detail::same_birth(parent, final_parent) &&
        detail::process(getpid(), final_self) && detail::same_birth(self, final_self) && publisher->permits_installed_images() &&
        proc_pidfdinfo(observation.pid, ERGOPTI_OWNED_RUNTIME_LIFECYCLE_CHILD_DESCRIPTOR,
            PROC_PIDFDVNODEPATHINFO, &last, sizeof(last)) == static_cast<int>(sizeof(last)) && matches(last) &&
        fstat(named, &final_lock) == 0 && detail::same_file(lock, final_lock) && detail::empty_acl(named);
    if (close(named) != 0) accepted = false;
    // Matching vnode does not independently prove SH/same-OFD. The signed
    // original headless inheritance code and retained native socket own that obligation.
    return accepted;
  };
  const bool accepted = check();
  const bool closed = publisher->release();
  return accepted && closed;
}

// Native observation storage is rooted before either publisher or named FD acquisition.
namespace detail {
class cleanup_probe final : public std::enable_shared_from_this<cleanup_probe> {
public:
  static std::shared_ptr<cleanup_probe> create() {
    auto result=std::shared_ptr<cleanup_probe>(new cleanup_probe);
    result->custody_=result;
    return result;
  }
  std::unique_ptr<ergoptiplus::installed_publisher::owner> publisher;
  int named=-1;
  bool release() noexcept {
    if (!attempted_) {
      attempted_=true;
      if (named>=0) { refused_descriptor_=named; if (close(named)!=0) refused_=true; named=-1; }
      if (publisher && !publisher->release()) refused_=true;
    }
    if (!refused_) custody_.reset();
    return !refused_;
  }
private:
  cleanup_probe()=default;
  std::shared_ptr<cleanup_probe> custody_;
  int refused_descriptor_=-1;
  bool attempted_=false,refused_=false;
};
} // namespace detail

// Cleanup predicate only for an already-retained original socket owner; never an owner factory.
inline bool remote_installed_cleanup_matches(const ergoptiplus::remap::auth::detail::peer_observation& observation) noexcept {
  std::shared_ptr<detail::cleanup_probe> probe;
  bool accepted=false;
  try {
  using role = ergoptiplus::remap::identity::role;
  if (getuid() != 0 || geteuid() != 0 || observation.self_euid != 0 || observation.euid == 0 ||
      observation.self.role != role::core || observation.peer.role != role::cli ||
      audit_token_to_pid(observation.token) != observation.pid || audit_token_to_euid(observation.token) != observation.euid) return false;
  probe=detail::cleanup_probe::create();
  probe->publisher=ergoptiplus::installed_publisher::owner::acquire();
  auto& publisher=probe->publisher;
  if (!publisher) { probe->release(); return false; }
  auto check = [&]() {
    const auto& approved = publisher->observed_leaf();
    if (observation.self.leaf != approved || observation.peer.leaf != approved || !publisher->custody_current()) return false;
    proc_bsdinfo child{}, parent{}, self{}, final_child{}, final_parent{}, final_self{};
    if (!detail::process(observation.pid, child) || child.pbi_uid != observation.euid ||
        !detail::process(static_cast<pid_t>(child.pbi_ppid), parent) || parent.pbi_uid != observation.euid ||
        !detail::process(getpid(), self) || self.pbi_uid != 0 || !detail::headless_parent(static_cast<pid_t>(parent.pbi_pid))) return false;
    const auto actual_child = detail::live_leaf(observation.pid, "com.ergoptiplus.remap.cli",
        "/Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli");
    const auto actual_parent = detail::live_leaf(static_cast<pid_t>(parent.pbi_pid), "com.ergoptiplus.app");
    const auto actual_self = detail::live_leaf(getpid(), "com.ergoptiplus.remap.core",
        "/Library/Application Support/ErgoptiPlus/Runtime/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core");
    if (!actual_child || !actual_parent || !actual_self || *actual_child != approved || *actual_parent != approved || *actual_self != approved) return false;
    constexpr const char* lock_path = "/Library/Application Support/ErgoptiPlus/.runtime-service-lifecycle-lock";
    probe->named = open(lock_path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK);
    const int named=probe->named;
    if (named < 0) return false;
    struct stat lock{}, final_lock{};
    vnode_fdinfowithpath first{}, last{};
    auto matches = [&](const vnode_fdinfowithpath& native) {
      const auto& value = native.pvip.vip_vi.vi_stat;
      return std::memchr(native.pvip.vip_path, '\0', sizeof(native.pvip.vip_path)) &&
          std::strcmp(native.pvip.vip_path, lock_path) == 0 &&
          value.vst_dev == static_cast<std::uint32_t>(lock.st_dev) && value.vst_ino == static_cast<std::uint64_t>(lock.st_ino) &&
          value.vst_mode == lock.st_mode && value.vst_uid == lock.st_uid && value.vst_gid == lock.st_gid &&
          value.vst_nlink == lock.st_nlink && value.vst_size == static_cast<std::int64_t>(lock.st_size) &&
          value.vst_mtime == static_cast<std::uint64_t>(lock.st_mtimespec.tv_sec) &&
          value.vst_mtimensec == static_cast<std::uint64_t>(lock.st_mtimespec.tv_nsec) &&
          value.vst_ctime == static_cast<std::uint64_t>(lock.st_ctimespec.tv_sec) &&
          value.vst_ctimensec == static_cast<std::uint64_t>(lock.st_ctimespec.tv_nsec);
    };
    bool accepted = fstat(named, &lock) == 0 && S_ISREG(lock.st_mode) && lock.st_uid == 0 &&
        (lock.st_mode & 07777) == 0644 && lock.st_nlink == 1 && lock.st_size == 0 && detail::empty_acl(named) &&
        proc_pidfdinfo(observation.pid, ERGOPTI_OWNED_RUNTIME_LIFECYCLE_CHILD_DESCRIPTOR,
            PROC_PIDFDVNODEPATHINFO, &first, sizeof(first)) == static_cast<int>(sizeof(first)) && matches(first) &&
        detail::process(observation.pid, final_child) && detail::same_birth(child, final_child) && final_child.pbi_ppid == parent.pbi_pid &&
        detail::process(static_cast<pid_t>(parent.pbi_pid), final_parent) && detail::same_birth(parent, final_parent) &&
        detail::process(getpid(), final_self) && detail::same_birth(self, final_self) && publisher->custody_current() &&
        proc_pidfdinfo(observation.pid, ERGOPTI_OWNED_RUNTIME_LIFECYCLE_CHILD_DESCRIPTOR,
            PROC_PIDFDVNODEPATHINFO, &last, sizeof(last)) == static_cast<int>(sizeof(last)) && matches(last) &&
        fstat(named, &final_lock) == 0 && detail::same_file(lock, final_lock) && detail::empty_acl(named);
    // Matching vnode does not independently prove SH/same-OFD. The signed
    // original headless inheritance code and retained native socket own that obligation.
    return accepted;
  };
  accepted = check();
  } catch (...) { accepted=false; }
  const bool closed=probe && probe->release();
  return accepted && closed;
}

// A restriction selector only: the fixed location MUST pass the private native
// publisher/Console/namespace factory. This does not mint installed authority.
inline std::optional<bool> local_fixed_core_location() noexcept {
  std::array<char, PROC_PIDPATHINFO_MAXSIZE> path{};
  const auto length = proc_pidpath(getpid(), path.data(), static_cast<std::uint32_t>(path.size()));
  if (length <= 0 || static_cast<std::size_t>(length) >= path.size() || path[0] == '\0' ||
      !std::memchr(path.data(), '\0', static_cast<std::size_t>(length) + 1)) return std::nullopt;
  return std::strcmp(path.data(), "/Library/Application Support/ErgoptiPlus/Runtime/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core") == 0;
}

inline bool remote_installed_console_matches(const ergoptiplus::remap::auth::detail::peer_observation& observation) {
  using role = ergoptiplus::remap::identity::role;
  if (getuid() != 0 || geteuid() != 0 || observation.self_euid != 0 || observation.euid == 0 ||
      observation.self.role != role::core || observation.peer.role != role::console ||
      audit_token_to_pid(observation.token) != observation.pid || audit_token_to_euid(observation.token) != observation.euid) return false;
  auto publisher = ergoptiplus::installed_publisher::owner::acquire();
  if (!publisher) return false;
  auto check = [&]() {
    const auto& approved = publisher->observed_leaf();
    if (observation.self.leaf != approved || observation.peer.leaf != approved || !publisher->permits_installed_images()) return false;
    proc_bsdinfo child{}, parent{}, self{}, final_child{}, final_parent{}, final_self{};
    if (!detail::process(observation.pid, child) || child.pbi_uid != observation.euid ||
        !detail::process(static_cast<pid_t>(child.pbi_ppid), parent) || parent.pbi_uid != observation.euid ||
        !detail::process(getpid(), self) || self.pbi_uid != 0 || !detail::headless_parent(static_cast<pid_t>(parent.pbi_pid))) return false;
    const auto actual_child = detail::live_leaf(observation.pid, "com.ergoptiplus.remap.console",
        "/Library/Application Support/ErgoptiPlus/Runtime/ErgoptiPlus-Remap-Console.app/Contents/MacOS/ErgoptiPlus-Remap-Console");
    const auto actual_parent = detail::live_leaf(static_cast<pid_t>(parent.pbi_pid), "com.ergoptiplus.app");
    const auto actual_self = detail::live_leaf(getpid(), "com.ergoptiplus.remap.core",
        "/Library/Application Support/ErgoptiPlus/Runtime/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core");
    if (!actual_child || !actual_parent || !actual_self || *actual_child != approved || *actual_parent != approved || *actual_self != approved) return false;
    constexpr const char* lock_path = "/Library/Application Support/ErgoptiPlus/.runtime-service-lifecycle-lock";
    const int named = open(lock_path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK);
    if (named < 0) return false;
    struct stat lock{}, final_lock{};
    vnode_fdinfowithpath first{}, last{};
    auto matches = [&](const vnode_fdinfowithpath& native) {
      const auto& value = native.pvip.vip_vi.vi_stat;
      return std::memchr(native.pvip.vip_path, '\0', sizeof(native.pvip.vip_path)) &&
          std::strcmp(native.pvip.vip_path, lock_path) == 0 &&
          value.vst_dev == static_cast<std::uint32_t>(lock.st_dev) && value.vst_ino == static_cast<std::uint64_t>(lock.st_ino) &&
          value.vst_mode == lock.st_mode && value.vst_uid == lock.st_uid && value.vst_gid == lock.st_gid &&
          value.vst_nlink == lock.st_nlink && value.vst_size == static_cast<std::int64_t>(lock.st_size) &&
          value.vst_mtime == static_cast<std::uint64_t>(lock.st_mtimespec.tv_sec) &&
          value.vst_mtimensec == static_cast<std::uint64_t>(lock.st_mtimespec.tv_nsec) &&
          value.vst_ctime == static_cast<std::uint64_t>(lock.st_ctimespec.tv_sec) &&
          value.vst_ctimensec == static_cast<std::uint64_t>(lock.st_ctimespec.tv_nsec);
    };
    bool accepted = fstat(named, &lock) == 0 && S_ISREG(lock.st_mode) && lock.st_uid == 0 &&
        (lock.st_mode & 07777) == 0644 && lock.st_nlink == 1 && lock.st_size == 0 && detail::empty_acl(named) &&
        proc_pidfdinfo(observation.pid, ERGOPTI_OWNED_RUNTIME_LIFECYCLE_CHILD_DESCRIPTOR,
            PROC_PIDFDVNODEPATHINFO, &first, sizeof(first)) == static_cast<int>(sizeof(first)) && matches(first) &&
        detail::process(observation.pid, final_child) && detail::same_birth(child, final_child) && final_child.pbi_ppid == parent.pbi_pid &&
        detail::process(static_cast<pid_t>(parent.pbi_pid), final_parent) && detail::same_birth(parent, final_parent) &&
        detail::process(getpid(), final_self) && detail::same_birth(self, final_self) && publisher->permits_installed_images() &&
        proc_pidfdinfo(observation.pid, ERGOPTI_OWNED_RUNTIME_LIFECYCLE_CHILD_DESCRIPTOR,
            PROC_PIDFDVNODEPATHINFO, &last, sizeof(last)) == static_cast<int>(sizeof(last)) && matches(last) &&
        fstat(named, &final_lock) == 0 && detail::same_file(lock, final_lock) && detail::empty_acl(named);
    if (close(named) != 0) accepted = false;
    // Matching vnode does not independently prove SH/same-OFD. The signed
    // original headless inheritance code and retained native socket own that obligation.
    return accepted;
  };
  const bool accepted = check();
  const bool closed = publisher->release();
  return accepted && closed;
}

// This owner is minted only by the original Core socket friend before capture
// preparation. Its independent SH survives loss of the CLI's inherited FD198.
class core_peer_owner;
class core_namespace_hold final : public std::enable_shared_from_this<core_namespace_hold> {
public:
  core_namespace_hold(const core_namespace_hold&) = delete;
  core_namespace_hold& operator=(const core_namespace_hold&) = delete;
  bool current() const noexcept {
    try {
      std::lock_guard<std::mutex> guard(mutex_);
      return !releasing_ && !close_refused_ && current_checked();
    } catch (...) { return false; }
  }
  ~core_namespace_hold() { close_owned(!retention_); }
private:
  friend class core_peer_owner;
  friend class ::ergoptiplus::remap::auth::console_control_owner;
  friend class ::hs274_stream_protocol::runtime;
  core_namespace_hold() = default;
  static constexpr const char* fixed_core =
      "/Library/Application Support/ErgoptiPlus/Runtime/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core";
  static constexpr std::array<const char*, 4> names_{
      "Library", "Application Support", "ErgoptiPlus", ".runtime-service-lifecycle-lock"};
  static bool same_directory(const struct stat& left, const struct stat& right) noexcept {
    return left.st_dev == right.st_dev && left.st_ino == right.st_ino && left.st_mode == right.st_mode &&
        left.st_uid == right.st_uid && left.st_gid == right.st_gid && left.st_nlink == right.st_nlink;
  }
  bool cleanup_ancestors_current() const {
    for (std::size_t i=0;i<descriptors_.size();++i) {
      const bool directory=i+1<descriptors_.size();struct stat held{},named{};
      const int flags=descriptors_[i]<0?-1:fcntl(descriptors_[i],F_GETFD);
      if (flags<0 || (flags&FD_CLOEXEC)==0 || fstat(descriptors_[i],&held)!=0 || !detail::empty_acl(descriptors_[i])) return false;
      const auto same=[](const struct stat& a,const struct stat& b) {
        return S_ISDIR(a.st_mode) && S_ISDIR(b.st_mode) && a.st_dev==b.st_dev && a.st_ino==b.st_ino
            && a.st_mode==b.st_mode && a.st_uid==b.st_uid && a.st_gid==b.st_gid;
      };
      const int status=i==0?lstat("/",&named):fstatat(descriptors_[i-1],names_[i-1],&named,AT_SYMLINK_NOFOLLOW);
      if (status!=0 || (directory?(!same(held,identities_[i]) || !same(named,identities_[i])):
          (!detail::same_file(held,identities_[i]) || !detail::same_file(named,identities_[i])))) return false;
    }
    return lock_current();
  }
  // Fresh observation comes only from the original socket friend under its native
  // mutex. The friend also binds its original audit/birth/preparation identity.
  bool peer_cleanup_identity(const ergoptiplus::remap::auth::detail::peer_observation& fresh) const {
    using role=ergoptiplus::remap::identity::role;
    if (!publisher_ || getuid()!=0 || geteuid()!=0 || fresh.self_euid!=0 || fresh.euid==0
        || fresh.self.role!=role::core || fresh.peer.role!=role::cli
        || audit_token_to_pid(fresh.token)!=fresh.pid || audit_token_to_euid(fresh.token)!=fresh.euid
        || audit_token_to_egid(fresh.token)!=fresh.egid) return false;
    const auto& leaf=publisher_->observed_leaf();
    if (fresh.self.leaf!=leaf || fresh.peer.leaf!=leaf) return false;
    proc_bsdinfo child{},parent{},self{},child_after{},parent_after{},self_after{};
    if (!detail::process(fresh.pid,child) || child.pbi_uid!=fresh.euid
        || !detail::process(static_cast<pid_t>(child.pbi_ppid),parent) || parent.pbi_uid!=fresh.euid
        || !detail::headless_parent(static_cast<pid_t>(parent.pbi_pid))
        || !detail::process(getpid(),self) || self.pbi_uid!=0 || !detail::same_birth(self_,self)) return false;
    const auto cli=detail::live_leaf(fresh.pid,"com.ergoptiplus.remap.cli",
        "/Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli");
    const auto launcher=detail::live_leaf(static_cast<pid_t>(parent.pbi_pid),"com.ergoptiplus.app");
    const auto core=detail::live_leaf(getpid(),"com.ergoptiplus.remap.core",fixed_core);
    if (!cli || !launcher || !core || *cli!=leaf || *launcher!=leaf || *core!=leaf) return false;
    constexpr const char* path="/Library/Application Support/ErgoptiPlus/.runtime-service-lifecycle-lock";
    const auto& expected=identities_.back();
    const auto matches=[&](const vnode_fdinfowithpath& observed) {
      const auto& value=observed.pvip.vip_vi.vi_stat;
      return std::memchr(observed.pvip.vip_path,'\0',sizeof(observed.pvip.vip_path))
          && std::strcmp(observed.pvip.vip_path,path)==0
          && value.vst_dev==static_cast<std::uint32_t>(expected.st_dev) && value.vst_ino==static_cast<std::uint64_t>(expected.st_ino)
          && value.vst_mode==expected.st_mode && value.vst_uid==expected.st_uid && value.vst_gid==expected.st_gid
          && value.vst_nlink==expected.st_nlink && value.vst_size==static_cast<std::int64_t>(expected.st_size)
          && value.vst_mtime==static_cast<std::uint64_t>(expected.st_mtimespec.tv_sec)
          && value.vst_mtimensec==static_cast<std::uint64_t>(expected.st_mtimespec.tv_nsec)
          && value.vst_ctime==static_cast<std::uint64_t>(expected.st_ctimespec.tv_sec)
          && value.vst_ctimensec==static_cast<std::uint64_t>(expected.st_ctimespec.tv_nsec);
    };
    vnode_fdinfowithpath first{},last{};
    return proc_pidfdinfo(fresh.pid,ERGOPTI_OWNED_RUNTIME_LIFECYCLE_CHILD_DESCRIPTOR,PROC_PIDFDVNODEPATHINFO,&first,sizeof(first))==static_cast<int>(sizeof(first))
        && matches(first) && detail::process(fresh.pid,child_after) && detail::same_birth(child,child_after)
        && child_after.pbi_ppid==parent.pbi_pid && detail::process(static_cast<pid_t>(parent.pbi_pid),parent_after)
        && detail::same_birth(parent,parent_after) && detail::process(getpid(),self_after) && detail::same_birth(self,self_after)
        && proc_pidfdinfo(fresh.pid,ERGOPTI_OWNED_RUNTIME_LIFECYCLE_CHILD_DESCRIPTOR,PROC_PIDFDVNODEPATHINFO,&last,sizeof(last))==static_cast<int>(sizeof(last)) && matches(last);
  }
  bool cleanup_current(const ergoptiplus::remap::auth::detail::peer_observation& fresh) const noexcept {
    try {
      std::lock_guard<std::mutex> held(mutex_);
      return retention_ && !releasing_ && !close_refused_ && publisher_ && publisher_->custody_current()
          && cleanup_ancestors_current() && peer_cleanup_identity(fresh)
          && publisher_->custody_current() && cleanup_ancestors_current();
    } catch (...) {return false;}
  }
  bool retired_peer_current(const ergoptiplus::remap::auth::detail::peer_observation& fresh) const noexcept {
    try {
      std::lock_guard<std::mutex> held(mutex_);
      return releasing_ && !close_refused_ && !retention_
          && std::all_of(descriptors_.begin(),descriptors_.end(),[](int fd){return fd<0;})
          && peer_cleanup_identity(fresh);
    } catch (...) {return false;}
  }
  class native_closed_custody final {
    friend class core_namespace_hold;
    explicit native_closed_custody(std::shared_ptr<const core_namespace_hold> owner):owner_(std::move(owner)) {}
    std::shared_ptr<const core_namespace_hold> owner_;
  public:
    bool matches(const ergoptiplus::remap::auth::detail::peer_observation& fresh) const noexcept {
      return owner_ && owner_->retired_peer_current(fresh);
    }
  };
  std::optional<native_closed_custody> closed_custody_observation() const noexcept {
    try {
      std::lock_guard<std::mutex> held(mutex_);
      if (!releasing_ || close_refused_ || retention_
          || !std::all_of(descriptors_.begin(),descriptors_.end(),[](int fd){return fd<0;})) return std::nullopt;
      return native_closed_custody(shared_from_this());
    } catch (...) {return std::nullopt;}
  }

  enum class acquisition_role { cli, console };
  static std::shared_ptr<core_namespace_hold> acquire(
      const ergoptiplus::remap::auth::detail::peer_observation& fresh) noexcept {
    return acquire_observed(fresh, acquisition_role::cli);
  }
  static std::shared_ptr<core_namespace_hold> acquire_console(
      const ergoptiplus::remap::auth::detail::peer_observation& fresh) noexcept {
    return acquire_observed(fresh, acquisition_role::console);
  }
  static std::shared_ptr<core_namespace_hold> acquire_observed(
      const ergoptiplus::remap::auth::detail::peer_observation& fresh, acquisition_role selected) noexcept {
    try {
      auto matches = [&]() { return selected == acquisition_role::cli ?
          remote_installed_peer_matches(fresh) : remote_installed_console_matches(fresh); };
      if (!matches()) return nullptr;
      // Allocate all ownership storage before the first native open. Every open
      // is immediately recorded in its fixed slot, before any throwing work.
      auto result = std::shared_ptr<core_namespace_hold>(new core_namespace_hold);
      result->publisher_ = ergoptiplus::installed_publisher::owner::acquire();
      if (!result->publisher_ || getuid() != 0 || geteuid() != 0 ||
          !detail::process(getpid(), result->self_) || result->self_.pbi_uid != 0) return nullptr;
      result->descriptors_[0] = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      if (result->descriptors_[0] < 0 || !detail::protected_directory(result->descriptors_[0]) ||
          fstat(result->descriptors_[0], &result->identities_[0]) != 0) return nullptr;
      for (std::size_t i = 1; i < result->descriptors_.size(); ++i) {
        const bool directory = i + 1 < result->descriptors_.size();
        const int flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : O_NONBLOCK);
        result->descriptors_[i] = openat(result->descriptors_[i - 1], names_[i - 1], flags);
        if (result->descriptors_[i] < 0 || fstat(result->descriptors_[i], &result->identities_[i]) != 0 ||
            (directory && !detail::protected_directory(result->descriptors_[i]))) return nullptr;
      }
      if (!result->lock_current() || flock(result->descriptors_.back(), LOCK_SH | LOCK_NB) != 0 ||
          !result->current_checked() || !matches()) return nullptr;
      // Still unpublished: if participant construction fails before effects,
      // normal destruction closes these newly acquired descriptors.
      return result;
    } catch (...) { return nullptr; }
  }
  bool lock_current() const {
    const std::size_t last = descriptors_.size() - 1;
    struct stat held{};
    return descriptors_[last] >= 0 && fstat(descriptors_[last], &held) == 0 &&
        detail::same_file(held, identities_[last]) && S_ISREG(held.st_mode) && held.st_uid == 0 &&
        (held.st_mode & 07777) == 0644 && held.st_nlink == 1 && held.st_size == 0 &&
        detail::empty_acl(descriptors_[last]);
  }
  bool journals_absent() const noexcept {
    const int parent = descriptors_[3]; // Original held protected ErgoptiPlus directory.
    if (parent < 0) return false;
    for (const char* name : {".runtime-install-journal", ".runtime-service-journal", ".runtime-bootstrap-journal", ".runtime-maintenance-journal"}) {
      struct stat observed{};
      errno = 0;
      if (fstatat(parent, name, &observed, AT_SYMLINK_NOFOLLOW) != -1 || errno != ENOENT) return false;
    }
    return true;
  }
  bool current_checked() const {
    proc_bsdinfo before{}, after{};
    if (!publisher_ || !publisher_->current() || getuid() != 0 || geteuid() != 0 ||
        !detail::process(getpid(), before) || !detail::same_birth(before, self_) || !lock_current() || !journals_absent()) return false;
    for (std::size_t i = 0; i < descriptors_.size(); ++i) {
      struct stat held{}, named{};
      const bool directory = i + 1 < descriptors_.size();
      const int descriptor_flags = descriptors_[i] < 0 ? -1 : fcntl(descriptors_[i], F_GETFD);
      if (descriptor_flags < 0 || (descriptor_flags & FD_CLOEXEC) == 0 || fstat(descriptors_[i], &held) != 0 ||
          (directory ? !same_directory(held, identities_[i]) : !detail::same_file(held, identities_[i])) ||
          (directory ? !detail::protected_directory(descriptors_[i]) : !detail::empty_acl(descriptors_[i]))) return false;
      const int observed = i == 0 ? lstat("/", &named) :
          fstatat(descriptors_[i - 1], names_[i - 1], &named, AT_SYMLINK_NOFOLLOW);
      if (observed != 0 || (directory ? !same_directory(named, identities_[i]) : !detail::same_file(named, identities_[i]))) return false;
    }
    const auto actual = detail::live_leaf(getpid(), "com.ergoptiplus.remap.core", fixed_core);
    return actual && *actual == publisher_->observed_leaf() && publisher_->current() &&
        detail::process(getpid(), after) && detail::same_birth(before, after) && lock_current() && journals_absent();
  }
  void close_owned(bool unpublished_cleanup = false) noexcept {
    // Published closure keeps the SH until publisher/ancestor close debt has
    // settled. No-effect acquisition failure still attempts all owned cleanup.
    if (publisher_ && !publisher_->release()) close_refused_ = true;
    for (std::size_t i = descriptors_.size() - 1; i > 0; --i) {
      int& value = descriptors_[i - 1];
      if (value >= 0) {
        const int descriptor = value;
        value = -1;
        if (close(descriptor) != 0) close_refused_ = true;
      }
    }
    int& lock_descriptor = descriptors_.back();
    if (lock_descriptor >= 0 && (unpublished_cleanup || !close_refused_)) {
      const int descriptor = lock_descriptor;
      lock_descriptor = -1;
      if (close(descriptor) != 0) close_refused_ = true;
    }
    // Never LOCK_UN and never retry an ambiguous native close. A prior published
    // close refusal leaves this exact lock descriptor and self-custody retained.
  }
  bool publish_before_prepare() noexcept {
    try {
      std::lock_guard<std::mutex> guard(mutex_);
      if (releasing_ || close_refused_ || retention_ || !current_checked()) return false;
      // Runtime already owns the constructor participant and calls this before
      // any preparation effect. From here, losing every external pointer cannot
      // release SH; only its exact aggregate-terminal closure can break custody.
      retention_ = shared_from_this();
      return true;
    } catch (...) { return false; }
  }
  bool release_after_retirement() noexcept {
    try {
      std::lock_guard<std::mutex> guard(mutex_);
      // Cleanup is deliberately independent of lost native currentness. Runtime
      // owns admission of this call from the exact aggregate terminal receipt.
      releasing_ = true;
      close_owned();
      const bool acknowledged = !close_refused_;
      auto keep_alive = retention_;
      if (acknowledged) retention_.reset();
      return acknowledged;
    } catch (...) { return false; }
  }
  bool retired() const noexcept {
    try {
      std::lock_guard<std::mutex> guard(mutex_);
      return releasing_ && !close_refused_ && !retention_ &&
          std::all_of(descriptors_.begin(), descriptors_.end(), [](int value) { return value < 0; });
    } catch (...) { return false; }
  }
  mutable std::mutex mutex_;
  std::array<int, 5> descriptors_{-1, -1, -1, -1, -1};
  std::array<struct stat, 5> identities_{};
  proc_bsdinfo self_{};
  std::unique_ptr<ergoptiplus::installed_publisher::owner> publisher_;
  std::shared_ptr<core_namespace_hold> retention_;
  bool releasing_ = false;
  bool close_refused_ = false;
};

class owner final {
public:
  owner(const owner&) = delete;
  owner& operator=(const owner&) = delete;
  static std::unique_ptr<owner> acquire() {
    if (getuid() == 0 || getuid() != geteuid()) return nullptr;
    auto result = std::unique_ptr<owner>(new owner);
    result->publisher_ = ergoptiplus::installed_publisher::owner::acquire();
    if (!result->publisher_ || !detail::fixed_lock(result->lock_) || !detail::process(getpid(), result->self_) ||
        !detail::process(getppid(), result->parent_) || result->self_.pbi_ppid != result->parent_.pbi_pid ||
        result->self_.pbi_uid != getuid() || result->parent_.pbi_uid != getuid()) return nullptr;
    auto self = detail::live_leaf(getpid(), "com.ergoptiplus.remap.cli", fixed_cli);
    auto parent = detail::live_leaf(getppid(), "com.ergoptiplus.app");
    if (!self || !parent || *self != result->publisher_->observed_leaf() || *parent != *self
        || !detail::headless_parent(getppid())) return nullptr;
    result->leaf_ = std::move(*self);
    return result->current() ? std::move(result) : nullptr;
  }
  bool current() const {
    proc_bsdinfo self{}, parent{};
    struct stat lock{};
    if (!publisher_ || !publisher_->permits_installed_images() || getuid() == 0 || getuid() != geteuid() || !detail::process(getpid(), self) || !detail::process(getppid(), parent) ||
        !detail::same_birth(self, self_) || !detail::same_birth(parent, parent_) || self.pbi_ppid != parent.pbi_pid ||
        !detail::fixed_lock(lock) || !detail::same_file(lock, lock_) || !detail::headless_parent(getppid())) return false;
    const auto actual_self = detail::live_leaf(getpid(), "com.ergoptiplus.remap.cli", fixed_cli);
    const auto actual_parent = detail::live_leaf(getppid(), "com.ergoptiplus.app");
    return actual_self && actual_parent && *actual_self == leaf_ && *actual_parent == leaf_ && publisher_->permits_installed_images();
  }
  // This retained constructor can authenticate terminal cleanup across operation journals.
  bool cleanup_current() const noexcept {
    try {
    proc_bsdinfo self{}, parent{};
    struct stat lock{};
    if (!publisher_ || !publisher_->custody_current() || getuid() == 0 || getuid() != geteuid() || !detail::process(getpid(), self) || !detail::process(getppid(), parent) ||
        !detail::same_birth(self, self_) || !detail::same_birth(parent, parent_) || self.pbi_ppid != parent.pbi_pid ||
        !detail::fixed_lock(lock) || !detail::same_file(lock, lock_) || !detail::headless_parent(getppid())) return false;
    const auto actual_self = detail::live_leaf(getpid(), "com.ergoptiplus.remap.cli", fixed_cli);
    const auto actual_parent = detail::live_leaf(getppid(), "com.ergoptiplus.app");
    return actual_self && actual_parent && *actual_self == leaf_ && *actual_parent == leaf_ && publisher_->custody_current();
    } catch (...) { return false; }
  }
  // FD198 is intentionally not closed or unlocked by this object. Kernel process
  // exit closes the inherited open-file-description after all socket/frame debt.
  ~owner() = default;
private:
  owner() = default;
  static constexpr const char* fixed_cli = "/Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli";
  struct stat lock_{};
  proc_bsdinfo self_{}, parent_{};
  std::vector<unsigned char> leaf_;
  std::unique_ptr<ergoptiplus::installed_publisher::owner> publisher_;
};
} // namespace ergoptiplus::installed_capture
