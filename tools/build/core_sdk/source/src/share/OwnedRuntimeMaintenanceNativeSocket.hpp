// Actual retained native maintenance socket and fresh kernel/code observations.
#pragma once
#include "InstalledRuntimeMaintenanceObservation.hpp"
#include "InstalledRuntimePublisher.hpp"
#include "OwnedRuntimeMaintenanceFraming.hpp"
#include "OwnedRuntimeMaintenanceResponseBoundary.hpp"
#include <Security/Security.h>
#include <bsm/libbsm.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <mutex>
#include <optional>
#include <poll.h>
#include <utility>

namespace ergoptiplus::installed_maintenance {
class core_endpoint;
class maintenance_client;
namespace detail {
namespace publisher = ergoptiplus::installed_publisher;
struct native_birth final {
  pid_t pid = -1;
  std::uint64_t seconds = 0, microseconds = 0;
  bool operator==(const native_birth& other) const noexcept {
    return pid == other.pid && seconds == other.seconds && microseconds == other.microseconds;
  }
  static std::optional<native_birth> observe(pid_t pid) noexcept {
    proc_bsdinfo information{};
    if (pid <= 1 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, sizeof(information)) != sizeof(information) ||
        information.pbi_pid != static_cast<std::uint32_t>(pid) || information.pbi_start_tvsec == 0 ||
        information.pbi_start_tvusec >= 1000000) return std::nullopt;
    return native_birth{pid, information.pbi_start_tvsec, information.pbi_start_tvusec};
  }
};

inline std::optional<std::string> exact_native_string(CFTypeRef value) {
  if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return std::nullopt;
  const auto string = static_cast<CFStringRef>(value);
  const auto length = CFStringGetLength(string);
  if (length <= 0 || length > 256) return std::nullopt;
  std::array<char, 1025> bytes{};
  if (!CFStringGetCString(string, bytes.data(), bytes.size(), kCFStringEncodingUTF8)) return std::nullopt;
  const std::string result(bytes.data());
  publisher::detail::cf<CFStringRef> roundtrip;
  roundtrip.value = CFStringCreateWithBytes(nullptr, reinterpret_cast<const UInt8*>(result.data()),
      static_cast<CFIndex>(result.size()), kCFStringEncodingUTF8, false);
  if (!roundtrip.value || !CFEqual(string, roundtrip.value)) return std::nullopt;
  return result;
}

// This sampler is distinct from the ordinary remap authentication policy. It
// never reclassifies its roles or widens its equal-leaf admission. Both actors
// are freshly derived here; the stable/approved-update owner subsequently
// applies its own exact protected image, publisher and native actor predicate.
inline std::optional<native_code_observation> native_identity(SecCodeRef live) {
  if (!live || SecCodeCheckValidity(live, kSecCSStrictValidate, nullptr) != errSecSuccess) return std::nullopt;
  publisher::detail::cf<SecStaticCodeRef> code;
  publisher::detail::cf<CFDictionaryRef> fields;
  if (SecCodeCopyStaticCode(live, kSecCSDefaultFlags, &code.value) != errSecSuccess || !code.value ||
      SecCodeCopySigningInformation(code.value, kSecCSSigningInformation, &fields.value) != errSecSuccess || !fields.value)
    return std::nullopt;
  const auto identifier = exact_native_string(CFDictionaryGetValue(fields.value, kSecCodeInfoIdentifier));
  const auto role = identifier ? publisher::closed_role(identifier->c_str()) : std::nullopt;
  const auto leaf = role ? publisher::detail::leaf(code.value, *role) : std::nullopt;
  if (!identifier || !role || !leaf || leaf->empty() ||
      SecCodeCheckValidity(live, kSecCSStrictValidate, nullptr) != errSecSuccess) return std::nullopt;
  return native_code_observation{*identifier, *leaf};
}
} // namespace detail

// No exported factory accepts a descriptor, PID or caller observation. The
// Core friend alone adopts a descriptor returned by its original acceptor.
// Callers can connect only to the one fixed protected endpoint.
class native_socket final : public std::enable_shared_from_this<native_socket> {
public:
  native_socket(const native_socket&) = delete;
  native_socket& operator=(const native_socket&) = delete;
  static std::shared_ptr<native_socket> connect_fixed() noexcept {
    if (outstanding_close_debt_) return nullptr;
    std::shared_ptr<native_socket> result;
    try {
      result = std::shared_ptr<native_socket>(new native_socket);
      result->custody_ = result;
      if (!result->anchor_parent() || !result->connect_named() || !result->observe()) {
        result->close(); return nullptr;
      }
      return result;
    } catch (...) { if (result) result->close(); return nullptr; }
  }
  std::optional<detail::native_peer_observation> observe() noexcept {
    try {
      std::lock_guard<std::recursive_mutex> held(mutex_);
      return observe_locked();
    } catch (...) { refused_ = true; return std::nullopt; }
  }
  std::optional<detail::native_birth> original_peer_birth() const noexcept {
    std::lock_guard<std::recursive_mutex> held(mutex_);
    return original_peer_;
  }
  // Serial helper-worker operations use a fixed two-second transport bound.
  // This transport bound is not a cohort-retirement allowance or a retry.
  std::optional<wire_frame> exchange(const wire_frame& request) noexcept {
    try {
      std::lock_guard<std::recursive_mutex> held(mutex_);
      if (request.status() != ERGOPTI_MAINTENANCE_WIRE_REQUEST || !observe_locked()) return std::nullopt;
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
      auto bytes = request.bytes();
      if (!transfer_locked(bytes.data(), bytes.size(), true, deadline)) return std::nullopt;
      bytes.fill(0);
      if (!transfer_locked(bytes.data(), bytes.size(), false, deadline)) return std::nullopt;
      const auto response = wire_frame::decode(bytes);
      if (!response || response->status() == ERGOPTI_MAINTENANCE_WIRE_REQUEST ||
          response->operation() != request.operation() || !observe_locked() ||
          !detail::response_boundary(socket_)) { refused_ = true; return std::nullopt; }
      return response;
    } catch (...) { refused_ = true; return std::nullopt; }
  }
  bool peer_eof_observed() const noexcept {
    std::lock_guard<std::recursive_mutex> held(mutex_);
    return peer_eof_;
  }
  // No destructor retries an ambiguous native close or drops retained debt.
  bool close() noexcept {
    try {
      std::lock_guard<std::recursive_mutex> held(mutex_);
      if (!close_attempted_) {
        close_attempted_ = true;
        if (socket_ >= 0) {
          const int descriptor = std::exchange(socket_, -1);
          if (::close(descriptor) != 0) close_refused_ = true;
        }
        for (std::size_t index = parent_count_; index != 0; --index) {
          const int descriptor = std::exchange(parent_[index - 1], -1);
          if (descriptor >= 0 && ::close(descriptor) != 0) close_refused_ = true;
        }
      }
      if (!close_refused_) custody_.reset();
      else outstanding_close_debt_ = true;
      return !close_refused_;
    } catch (...) { close_refused_ = true; outstanding_close_debt_ = true; return false; }
  }

private:
  friend class core_endpoint;
  friend class maintenance_client;
  // Only the original acquisition's loss observer may consume this check.
  // Kernel EOF alone is not a terminal or a NOTE_EXIT observation.
  bool same_original_peer_eof() noexcept {
    try {
      std::lock_guard<std::recursive_mutex> held(mutex_);
      if (socket_<0 || refused_ || close_attempted_ || close_refused_ || !token_ ||
          !original_identity_ || !original_peer_ || !original_self_ || !parent_current()) return false;
      audit_token_t token{};pid_t pid=-1;uid_t uid=static_cast<uid_t>(-1);gid_t gid=static_cast<gid_t>(-1);
      const auto self=detail::native_birth::observe(getpid());
      const auto peer=detail::native_birth::observe(original_peer_->pid);
      const int flags=::fcntl(socket_,F_GETFD);
      if (!kernel_token(token,pid,uid,gid) || std::memcmp(&token,&*token_,sizeof(token))!=0 ||
          pid!=original_peer_->pid || uid!=original_identity_->euid || gid!=original_identity_->egid ||
          !self || !(*self==*original_self_) || (peer && !(*peer==*original_peer_)) ||
          geteuid()!=original_identity_->self_euid || getegid()!=original_identity_->self_egid ||
          flags<0 || !(flags&FD_CLOEXEC)) return false;
      std::uint8_t byte=0;
      ssize_t count;
      do { count=::recv(socket_,&byte,1,MSG_PEEK|MSG_DONTWAIT); } while (count<0 && errno==EINTR);
      if (count!=0) return false;
      peer_eof_=true;
      return parent_current();
    } catch (...) { refused_=true;return false; }
  }
  native_socket() = default;
  inline static std::atomic_bool outstanding_close_debt_{false};
  mutable std::recursive_mutex mutex_;
  int socket_ = -1;
  std::array<int, 4> parent_{{-1, -1, -1, -1}};
  std::array<struct stat, 4> parent_identity_{};
  std::size_t parent_count_ = 0;
  std::optional<audit_token_t> token_;
  std::optional<detail::native_birth> original_peer_, original_self_;
  std::optional<detail::native_peer_observation> original_identity_;
  bool peer_eof_ = false, close_attempted_ = false;
  std::atomic_bool refused_{false}, close_refused_{false};
  std::shared_ptr<native_socket> custody_;

  bool anchor_parent() {
    constexpr std::array<const char*, 4> names{{"/", "Library", "Application Support", "ErgoptiPlus"}};
    for (std::size_t index = 0; index < names.size(); ++index) {
      parent_[index] = index == 0 ? ::open(names[index], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
          : ::openat(parent_[index - 1], names[index], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      if (parent_[index] < 0) return false;
      parent_count_ = index + 1;
      const auto& identity = parent_identity_[index];
      if (::fstat(parent_[index], &parent_identity_[index]) != 0 || !S_ISDIR(identity.st_mode) ||
          identity.st_uid != 0 || (identity.st_mode & 06022) != 0 || !detail::publisher::detail::empty_acl(parent_[index])) return false;
    }
    return parent_current();
  }
  bool parent_current() const {
    constexpr std::array<const char*, 4> names{{"/", "Library", "Application Support", "ErgoptiPlus"}};
    if (parent_count_ != names.size()) return false;
    for (std::size_t index = 0; index < names.size(); ++index) {
      struct stat held{}, named{};
      const auto& original = parent_identity_[index];
      if (parent_[index] < 0 || ::fstat(parent_[index], &held) != 0 ||
          (index == 0 ? ::lstat(names[index], &named)
                      : ::fstatat(parent_[index - 1], names[index], &named, AT_SYMLINK_NOFOLLOW)) != 0 ||
          !S_ISDIR(held.st_mode) || held.st_dev != original.st_dev || held.st_ino != original.st_ino ||
          held.st_mode != original.st_mode || held.st_uid != original.st_uid || held.st_gid != original.st_gid ||
          named.st_dev != held.st_dev || named.st_ino != held.st_ino || named.st_mode != held.st_mode ||
          named.st_uid != held.st_uid || named.st_gid != held.st_gid || !detail::publisher::detail::empty_acl(parent_[index])) return false;
    }
    return true;
  }
  bool connect_named() {
    struct stat named{};
    if (!parent_current() || ::fstatat(parent_.back(), ".runtime-maintenance.sock", &named, AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISSOCK(named.st_mode) || (named.st_mode & 07777) != 0600 || named.st_gid != 0 ||
        (getuid() != 0 && named.st_uid != getuid())) return false;
    socket_ = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (socket_ < 0 || ::fcntl(socket_, F_SETFD, FD_CLOEXEC) != 0) return false;
    const int flags = ::fcntl(socket_, F_GETFL);
    if (flags < 0 || ::fcntl(socket_, F_SETFL, flags | O_NONBLOCK) != 0) return false;
    int enabled = 1;
    if (::setsockopt(socket_, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) != 0) return false;
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    constexpr auto length = sizeof(ERGOPTI_OWNED_MAINTENANCE_SOCKET) - 1;
    static_assert(length < sizeof(address.sun_path));
    std::memcpy(address.sun_path, ERGOPTI_OWNED_MAINTENANCE_SOCKET, length + 1);
    address.sun_len = static_cast<std::uint8_t>(offsetof(sockaddr_un, sun_path) + length + 1);
    if (::connect(socket_, reinterpret_cast<sockaddr*>(&address), address.sun_len) != 0) {
      if (errno != EINPROGRESS) return false;
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
      while (true) {
        const auto now = std::chrono::steady_clock::now();
        if (now >= deadline) return false;
        const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count();
        pollfd pending{socket_, POLLOUT, 0};
        const int ready = ::poll(&pending, 1, static_cast<int>(std::max<std::int64_t>(1, remaining)));
        if (ready < 0 && errno == EINTR) continue;
        int failure = 0;
        socklen_t failure_size = sizeof(failure);
        if (ready <= 0 || (pending.revents & (POLLERR | POLLNVAL)) ||
            ::getsockopt(socket_, SOL_SOCKET, SO_ERROR, &failure, &failure_size) != 0 ||
            failure_size != sizeof(failure) || failure != 0) return false;
        break;
      }
    }
    return parent_current();
  }
  bool kernel_token(audit_token_t& token, pid_t& pid, uid_t& uid, gid_t& gid) const {
    socklen_t token_length = sizeof(token), pid_length = sizeof(pid);
    return ::getsockopt(socket_, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &token_length) == 0 && token_length == sizeof(token) &&
        ::getsockopt(socket_, SOL_LOCAL, LOCAL_PEERPID, &pid, &pid_length) == 0 && pid_length == sizeof(pid) &&
        ::getpeereid(socket_, &uid, &gid) == 0;
  }
  std::optional<detail::native_peer_observation> observe_locked() {
    if (socket_ < 0 || refused_ || peer_eof_ || close_attempted_ || close_refused_ || !parent_current()) return std::nullopt;
    detail::native_peer_observation result{};
    pid_t peer_pid = -1;
    uid_t uid = static_cast<uid_t>(-1);
    gid_t gid = static_cast<gid_t>(-1);
    if (!kernel_token(result.token, peer_pid, uid, gid) ||
        (token_ && std::memcmp(&*token_, &result.token, sizeof(result.token)) != 0)) return fail_observation();
    audit_token_to_au32(result.token, nullptr, &result.euid, &result.egid, nullptr, nullptr, &result.pid, nullptr, nullptr);
    const auto self = detail::native_birth::observe(getpid()), peer = detail::native_birth::observe(peer_pid);
    if (peer_pid <= 1 || peer_pid != result.pid || uid != result.euid || gid != result.egid || !self || !peer ||
        (original_self_ && !(*original_self_ == *self)) || (original_peer_ && !(*original_peer_ == *peer))) return fail_observation();
    result.self_euid = geteuid(); result.self_egid = getegid();
    detail::publisher::detail::cf<SecCodeRef> self_code, peer_code;
    detail::publisher::detail::cf<CFDataRef> audit;
    detail::publisher::detail::cf<CFDictionaryRef> attributes;
    audit.value = CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(&result.token), sizeof(result.token));
    const void* key = kSecGuestAttributeAudit;
    const void* value = audit.value;
    if (!audit.value) return fail_observation();
    attributes.value = CFDictionaryCreate(nullptr, &key, &value, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!attributes.value || SecCodeCopySelf(kSecCSDefaultFlags, &self_code.value) != errSecSuccess ||
        SecCodeCopyGuestWithAttributes(nullptr, attributes.value, kSecCSDefaultFlags, &peer_code.value) != errSecSuccess)
      return fail_observation();
    const auto self_identity = detail::native_identity(self_code.value), peer_identity = detail::native_identity(peer_code.value);
    if (!self_identity || !peer_identity) return fail_observation();
    result.self = *self_identity; result.peer = *peer_identity;
    // A fresh valid signature alone does not preserve the original actor.
    // Retain both original identities and credentials independently; an exec,
    // certificate change or credential change cannot inherit this stream.
    if (original_identity_ &&
        (result.self.identifier != original_identity_->self.identifier ||
         result.self.leaf != original_identity_->self.leaf ||
         result.peer.identifier != original_identity_->peer.identifier ||
         result.peer.leaf != original_identity_->peer.leaf ||
         result.self_euid != original_identity_->self_euid ||
         result.self_egid != original_identity_->self_egid ||
         result.euid != original_identity_->euid ||
         result.egid != original_identity_->egid)) return fail_observation();
    audit_token_t final_token{};
    pid_t final_pid = -1; uid_t final_uid = static_cast<uid_t>(-1); gid_t final_gid = static_cast<gid_t>(-1);
    const auto final_self = detail::native_birth::observe(getpid()), final_peer = detail::native_birth::observe(peer_pid);
    const int descriptor_flags = ::fcntl(socket_, F_GETFD);
    if (!kernel_token(final_token, final_pid, final_uid, final_gid) || final_pid != peer_pid || final_uid != uid || final_gid != gid ||
        std::memcmp(&final_token, &result.token, sizeof(final_token)) != 0 || !final_self || !final_peer ||
        !(*final_self == *self) || !(*final_peer == *peer) || result.self_euid != geteuid() || result.self_egid != getegid() ||
        descriptor_flags < 0 || !(descriptor_flags & FD_CLOEXEC) || !parent_current() ||
        SecCodeCheckValidity(self_code.value, kSecCSStrictValidate, nullptr) != errSecSuccess ||
        SecCodeCheckValidity(peer_code.value, kSecCSStrictValidate, nullptr) != errSecSuccess) return fail_observation();
    if (!token_) token_ = result.token;
    if (!original_self_) original_self_ = *self;
    if (!original_peer_) original_peer_ = *peer;
    if (!original_identity_) original_identity_ = result;
    return result;
  }
  std::optional<detail::native_peer_observation> fail_observation() noexcept {
    refused_ = true;
    return std::nullopt;
  }
  bool transfer_locked(std::uint8_t* bytes, std::size_t size, bool writing,
                       const std::chrono::steady_clock::time_point& deadline) {
    std::size_t offset = 0;
    while (offset != size) {
      const auto now = std::chrono::steady_clock::now();
      if (now >= deadline || !observe_locked()) { refused_ = true; return false; }
      const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count();
      pollfd descriptor{socket_, static_cast<short>(writing ? POLLOUT : POLLIN), 0};
      const int ready = ::poll(&descriptor, 1, static_cast<int>(std::max<std::int64_t>(1, remaining)));
      if (ready < 0 && errno == EINTR) continue;
      if (ready <= 0 || (descriptor.revents & (POLLERR | POLLNVAL))) { refused_ = true; return false; }
      const auto count = writing ? ::send(socket_, bytes + offset, size - offset, 0)
          : ::recv(socket_, bytes + offset, size - offset, 0);
      if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) continue;
      if (count == 0 && !writing) peer_eof_ = true;
      if (count <= 0) { refused_ = true; return false; }
      offset += static_cast<std::size_t>(count);
    }
    return true;
  }
};
} // namespace ergoptiplus::installed_maintenance
