#pragma once

// PRIVATE draft. Native sampler only; no vendor route, owner publication,
// delivery/close ABI or Console ownership binding has been integrated yet.
// Finite token observations cannot identify every buffered stream writer.
#include "remap_runtime_auth_policy.hpp"
#include "remap_runtime_parent.hpp"
#include <asio.hpp>
#include <dispatch/dispatch.h>
#include <functional>
#include <utility>
#include <algorithm>
#include <exception>
#include <nlohmann/json.hpp>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <bsm/libbsm.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace pqrs::unix_domain_stream {
class client;
class server;
namespace impl { class peer; class client_state; class server_state; class request_manager; }
}
namespace krbn {
class core_service_daemon_client;
class console_user_server_client;
namespace core_service::daemon { class receiver; class console_user_id_changed_receiver; }
namespace console_user_server { class receiver; class console_user_id_changed_client; }
}
namespace ergoptiplus::remap::auth {
class socket_lifetime;
class channel_owner;
class delivery_ticket;
class frame_scope;
namespace detail {

template <typename T>
class cf_owned final {
public:
  cf_owned() = default;
  cf_owned(const cf_owned&) = delete;
  cf_owned& operator=(const cf_owned&) = delete;
  ~cf_owned() { if (value_) CFRelease(value_); }
  T get() const noexcept { return value_; }
  T* out() noexcept { return &value_; }
private:
  T value_ = nullptr;
};

struct code_identity final {
  identity::role role = identity::role::unavailable;
  std::string team;
  std::vector<std::uint8_t> leaf;
};

[[nodiscard]] inline std::optional<std::string> exact_string(CFTypeRef value) {
  if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return std::nullopt;
  const auto string = static_cast<CFStringRef>(value);
  const auto length = CFStringGetLength(string);
  if (length <= 0 || length > 16384) return std::nullopt;
  const auto capacity = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8);
  if (capacity < 1 || capacity > 65536) return std::nullopt;
  std::vector<char> bytes(static_cast<std::size_t>(capacity) + 1);
  if (!CFStringGetCString(string, bytes.data(), capacity + 1, kCFStringEncodingUTF8)) return std::nullopt;
  std::string result(bytes.data());
  // Reject embedded NUL/truncation as well as unknown native signing IDs.
  if (result.empty()) return std::nullopt;
  cf_owned<CFStringRef> roundtrip;
  *roundtrip.out() = CFStringCreateWithBytes(kCFAllocatorDefault,
      reinterpret_cast<const UInt8*>(result.data()), static_cast<CFIndex>(result.size()),
      kCFStringEncodingUTF8, false);
  if (!roundtrip.get() || !CFEqual(string, roundtrip.get())) return std::nullopt;
  return result;
}

[[nodiscard]] inline std::optional<std::string> signing_team(CFDictionaryRef information) {
  if (!information || CFGetTypeID(information) != CFDictionaryGetTypeID()) return std::nullopt;
  // Team metadata is optional for non-Apple signatures; a present value stays strict.
  if (!CFDictionaryContainsKey(information, kSecCodeInfoTeamIdentifier)) return std::string{};
  return exact_string(CFDictionaryGetValue(information, kSecCodeInfoTeamIdentifier));
}

[[nodiscard]] inline std::optional<code_identity> signing_identity(SecCodeRef live) {
  if (!live || CFGetTypeID(live) != SecCodeGetTypeID() ||
      SecCodeCheckValidity(live, kSecCSStrictValidate, nullptr) != errSecSuccess) return std::nullopt;
  cf_owned<SecStaticCodeRef> static_code;
  if (SecCodeCopyStaticCode(live, kSecCSDefaultFlags, static_code.out()) != errSecSuccess ||
      !static_code.get() || CFGetTypeID(static_code.get()) != SecStaticCodeGetTypeID()) return std::nullopt;
  cf_owned<CFDictionaryRef> information;
  if (SecCodeCopySigningInformation(static_code.get(), kSecCSSigningInformation, information.out()) != errSecSuccess ||
      !information.get() || CFGetTypeID(information.get()) != CFDictionaryGetTypeID()) return std::nullopt;
  const auto identifier = exact_string(CFDictionaryGetValue(information.get(), kSecCodeInfoIdentifier));
  const auto flags_value = CFDictionaryGetValue(information.get(), kSecCodeInfoFlags);
  if (!identifier || !flags_value || CFGetTypeID(flags_value) != CFNumberGetTypeID()) return std::nullopt;
  std::int64_t flags = 0;
  if (!CFNumberGetValue(static_cast<CFNumberRef>(flags_value), kCFNumberSInt64Type, &flags) ||
      flags < 0 || flags > std::numeric_limits<std::uint32_t>::max() ||
      (flags & kSecCodeSignatureAdhoc) != 0) return std::nullopt;
  const auto role = identity::classify(*identifier);
  if (role == identity::role::unavailable) return std::nullopt;
  const auto certificates = CFDictionaryGetValue(information.get(), kSecCodeInfoCertificates);
  if (!certificates || CFGetTypeID(certificates) != CFArrayGetTypeID() ||
      CFArrayGetCount(static_cast<CFArrayRef>(certificates)) < 1) return std::nullopt;
  const auto leaf = CFArrayGetValueAtIndex(static_cast<CFArrayRef>(certificates), 0);
  if (!leaf || CFGetTypeID(leaf) != SecCertificateGetTypeID()) return std::nullopt;
  cf_owned<CFDataRef> der;
  *der.out() = SecCertificateCopyData(static_cast<SecCertificateRef>(const_cast<void*>(leaf)));
  if (!der.get() || CFGetTypeID(der.get()) != CFDataGetTypeID()) return std::nullopt;
  const auto length = CFDataGetLength(der.get());
  if (length <= 0 || length > 1024 * 1024 || !CFDataGetBytePtr(der.get())) return std::nullopt;
  if (SecCodeCheckValidity(live, kSecCSStrictValidate, nullptr) != errSecSuccess) return std::nullopt;
  const auto team = signing_team(information.get());
  if (!team) return std::nullopt;
  return code_identity{role, *team, std::vector<std::uint8_t>(CFDataGetBytePtr(der.get()), CFDataGetBytePtr(der.get()) + length)};
}

struct peer_observation final {
  audit_token_t token{};
  pid_t pid = -1;
  uid_t euid = static_cast<uid_t>(-1);
  gid_t egid = static_cast<gid_t>(-1);
  code_identity self;
  code_identity peer;
  uid_t self_euid = static_cast<uid_t>(-1);
  gid_t self_egid = static_cast<gid_t>(-1);
};

// Private to the future exact socket_lifetime. No exported FD/PID/token input
// supplies production authority, and no caller validation callback exists.
class native_sampler final {
  friend class ::ergoptiplus::remap::auth::socket_lifetime;
private:
  [[nodiscard]] static bool token(int descriptor, audit_token_t& value, pid_t& pid) noexcept {
    socklen_t token_length = sizeof(value);
    socklen_t pid_length = sizeof(pid);
    return descriptor >= 0 &&
           ::getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &value, &token_length) == 0 &&
           token_length == sizeof(value) &&
           ::getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &pid_length) == 0 &&
           pid_length == sizeof(pid) && pid > 1;
  }

  // The caller MUST hold its exact nativeFD lifetime validation mutex; this
  // private sampler neither duplicates the socket nor owns physical close.
  [[nodiscard]] static std::optional<peer_observation> sample(int descriptor,
                                                             const std::optional<audit_token_t>& initial) {
    peer_observation result;
    pid_t native_pid = -1;
    if (!token(descriptor, result.token, native_pid) ||
        (initial && std::memcmp(&*initial, &result.token, sizeof(result.token)) != 0)) return std::nullopt;
    // Genuine public libbsm API, never guessed audit_token_t word indices.
    audit_token_to_au32(result.token, nullptr, &result.euid, &result.egid,
                        nullptr, nullptr, &result.pid, nullptr, nullptr);
    uid_t cached_uid = static_cast<uid_t>(-1);
    gid_t cached_gid = static_cast<gid_t>(-1);
    if (result.pid <= 1 || result.pid != native_pid ||
        ::getpeereid(descriptor, &cached_uid, &cached_gid) != 0 ||
        cached_uid != result.euid || cached_gid != result.egid) return std::nullopt;
    result.self_euid = ::geteuid();
    result.self_egid = ::getegid();
    cf_owned<SecCodeRef> self;
    if (SecCodeCopySelf(kSecCSDefaultFlags, self.out()) != errSecSuccess || !self.get()) return std::nullopt;
    const auto self_identity = signing_identity(self.get());
    if (!self_identity) return std::nullopt;
    cf_owned<CFDataRef> audit;
    *audit.out() = CFDataCreate(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(&result.token), sizeof(result.token));
    if (!audit.get()) return std::nullopt;
    const void* keys[] = {kSecGuestAttributeAudit};
    const void* values[] = {audit.get()};
    cf_owned<CFDictionaryRef> attributes;
    *attributes.out() = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!attributes.get()) return std::nullopt;
    cf_owned<SecCodeRef> guest;
    if (SecCodeCopyGuestWithAttributes(nullptr, attributes.get(), kSecCSDefaultFlags, guest.out()) != errSecSuccess ||
        !guest.get()) return std::nullopt;
    const auto peer_identity = signing_identity(guest.get());
    if (!peer_identity || peer_identity->team != self_identity->team ||
        peer_identity->leaf != self_identity->leaf) return std::nullopt;
    if (SecCodeCheckValidity(guest.get(), kSecCSStrictValidate, nullptr) != errSecSuccess ||
        SecCodeCheckValidity(self.get(), kSecCSStrictValidate, nullptr) != errSecSuccess) return std::nullopt;
    audit_token_t final_token{};
    pid_t final_pid = -1;
    uid_t final_cached_uid = static_cast<uid_t>(-1);
    gid_t final_cached_gid = static_cast<gid_t>(-1);
    if (!token(descriptor, final_token, final_pid) || final_pid != result.pid ||
        std::memcmp(&result.token, &final_token, sizeof(result.token)) != 0 ||
        ::getpeereid(descriptor, &final_cached_uid, &final_cached_gid) != 0 ||
        final_cached_uid != result.euid || final_cached_gid != result.egid ||
        ::geteuid() != result.self_euid || ::getegid() != result.self_egid) return std::nullopt;
    result.self = *self_identity;
    result.peer = *peer_identity;
    return result;
  }
};
// Internal portable bookkeeping foundation. This cannot sample native identity,
// mint authenticated data or acknowledge physical native socket retirement.
// Only the future fixed native socket_lifetime may use these private gates.
class console_registry;
class publication_gate;
class lifetime_gate;
class delivery_identity;

class publication_gate final {
  friend class console_registry;
  friend class ::ergoptiplus::remap::auth::channel_owner;
  friend class lifetime_gate;
  friend class ::ergoptiplus::remap::auth::socket_lifetime;
private:
  std::mutex mutex_;
  const std::uint64_t generation_;
  bool stopped_ = false;
  std::vector<std::weak_ptr<lifetime_gate>> lifetimes_;
  inline static std::atomic<std::uint64_t> generation_counter_{0};

  static std::uint64_t next_generation() noexcept {
    auto current = generation_counter_.load();
    while (current != std::numeric_limits<std::uint64_t>::max()) {
      if (generation_counter_.compare_exchange_weak(current, current + 1)) return current + 1;
    }
    return 0;
  }
  publication_gate() : generation_(next_generation()), stopped_(generation_ == 0) {}
  bool publish(const std::shared_ptr<lifetime_gate>& lifetime);
  void stop() noexcept;
};

class delivery_identity final {
  friend class lifetime_gate;
  friend class ::ergoptiplus::remap::auth::socket_lifetime;
private:
  const std::shared_ptr<lifetime_gate> lifetime_;
  const std::uint64_t generation_;
  const std::uint64_t frame_;
  const std::uint64_t hop_;
  std::atomic<bool> consumed_{false};
  delivery_identity(std::shared_ptr<lifetime_gate> lifetime, std::uint64_t generation,
                    std::uint64_t frame, std::uint64_t hop)
      : lifetime_(std::move(lifetime)), generation_(generation), frame_(frame), hop_(hop) {}
};

class lifetime_gate final : public std::enable_shared_from_this<lifetime_gate> {
  friend class ::ergoptiplus::remap::auth::frame_scope;
  friend class publication_gate;
  friend class ::ergoptiplus::remap::auth::socket_lifetime;
private:
  const std::shared_ptr<publication_gate> owner_;
  bool published_ = false; // guarded only by owner publication mutex
  std::atomic<bool> revoked_{false};
  std::atomic<std::uint64_t> debt_{0};
  std::atomic<std::uint64_t> frame_counter_{0};
  std::atomic<bool> close_continuation_claimed_{false};
  std::mutex validation_mutex_; // future exactFD+nativeSecurity lease protection

  explicit lifetime_gate(std::shared_ptr<publication_gate> owner) : owner_(std::move(owner)) {}
  void revoke() noexcept {
    std::lock_guard<std::mutex> lock(owner_->mutex_);
    revoked_.store(true);
  }
  std::shared_ptr<delivery_identity> new_identity() {
    std::lock_guard<std::mutex> lock(owner_->mutex_);
    if (owner_->stopped_ || !published_ || revoked_.load()) return nullptr;
    const auto previous = frame_counter_.load();
    if (previous == std::numeric_limits<std::uint64_t>::max()) {
      revoked_.store(true);
      return nullptr;
    }
    const auto frame = previous + 1;
    frame_counter_.store(frame);
    return std::shared_ptr<delivery_identity>(new delivery_identity(shared_from_this(), owner_->generation_, frame, 0));
  }
  // Called only while the native lifetime retains validation_mutex_ AFTER its
  // real same-FD checks, never instead of those checks. No handler under locks.
  bool claim(const std::shared_ptr<delivery_identity>& ticket) noexcept {
    std::lock_guard<std::mutex> lock(owner_->mutex_);
    if (!ticket || ticket->lifetime_.get() != this || ticket->generation_ != owner_->generation_ ||
        owner_->stopped_ || !published_ || revoked_.load() || ticket->consumed_.exchange(true)) return false;
    const auto count = debt_.load();
    if (count == std::numeric_limits<std::uint64_t>::max()) {
      revoked_.store(true);
      return false;
    }
    debt_.store(count + 1);
    return true;
  }
  std::shared_ptr<delivery_identity> handoff(const std::shared_ptr<delivery_identity>& previous,
                                           std::atomic<bool>& scope_handed_off) {
    std::lock_guard<std::mutex> lock(owner_->mutex_);
    if (!previous || previous->lifetime_.get() != this || !previous->consumed_.load() ||
        previous->generation_ != owner_->generation_ || owner_->stopped_ || !published_ ||
        revoked_.load() || scope_handed_off.exchange(true)) return nullptr;
    if (previous->hop_ == std::numeric_limits<std::uint64_t>::max()) {
      revoked_.store(true);
      return nullptr;
    }
    return std::shared_ptr<delivery_identity>(new delivery_identity(shared_from_this(), owner_->generation_, previous->frame_, previous->hop_ + 1));
  }
  // Exact once-only scope unwind only; the native frame_scope must ensure this
  // private method runs after its actual callback stack unwinds.
  bool unwind() noexcept {
    std::lock_guard<std::mutex> lock(owner_->mutex_);
    const auto count = debt_.load();
    if (count == 0) {
      revoked_.store(true);
      return false;
    }
    debt_.store(count - 1);
    return revoked_.load() && count == 1 && !close_continuation_claimed_.exchange(true);
  }
  bool claim_close_continuation() noexcept {
    std::lock_guard<std::mutex> lock(owner_->mutex_);
    return revoked_.load() && debt_.load() == 0 && !close_continuation_claimed_.exchange(true);
  }
};

inline bool publication_gate::publish(const std::shared_ptr<lifetime_gate>& lifetime) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!lifetime || stopped_ || generation_ == 0 || lifetime->owner_.get() != this ||
      lifetime->published_ || lifetime->revoked_.load()) return false;
  lifetimes_.push_back(lifetime);
  lifetime->published_ = true;
  return true;
}

inline void publication_gate::stop() noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  stopped_ = true;
  for (const auto& retained : lifetimes_) {
    if (auto lifetime = retained.lock()) lifetime->revoked_.store(true);
  }
}

} // namespace detail
} // namespace ergoptiplus::remap::auth


// Selected owned-profile transport. The native sampler and once-only identity
// engine above remain the only authority engines. Stock vendor constructors do
// not create any of these owners or perform any additional native observations.
namespace ergoptiplus::remap::auth {
enum class frame_kind { connected, user_data, request, response, health_check, health_check_response };

class frame_view final {
  friend class socket_lifetime;
  friend class delivery_ticket;
  friend class frame_scope;
public:
  frame_kind kind() const noexcept { return kind_; }
  std::uint64_t request_id() const noexcept { return request_id_; }
  const std::vector<std::uint8_t>& payload() const noexcept { return payload_; }
  uid_t peer_uid() const noexcept { return peer_uid_; }
  pid_t peer_pid() const noexcept { return peer_pid_; }
  identity::role peer_role() const noexcept { return peer_role_; }
private:
  frame_view(frame_kind kind, std::uint64_t request_id,
             std::vector<std::uint8_t> payload, const detail::peer_observation& native)
      : kind_(kind), request_id_(request_id), payload_(std::move(payload)),
        peer_uid_(native.euid), peer_pid_(native.pid), peer_role_(native.peer.role) {}
  const frame_kind kind_;
  const std::uint64_t request_id_;
  const std::vector<std::uint8_t> payload_;
  const uid_t peer_uid_;
  const pid_t peer_pid_;
  const identity::role peer_role_;
};

namespace detail {
class console_runtime_binding;
class console_registry final {
  friend class console_runtime_binding;
  friend class ::ergoptiplus::remap::auth::channel_owner;
  friend class ::ergoptiplus::remap::auth::socket_lifetime;
private:
  struct entry final {
    const std::shared_ptr<owned_console_parent_watch> watch;
    const std::uint64_t runtime_generation;
    const uid_t euid;
    const std::shared_ptr<publication_gate> gate;
    std::vector<std::shared_ptr<channel_owner>> channels;
    std::function<void()> retirement_hint;
    std::atomic<bool> published{false};
    bool hint_claimed = false;
    bool hint_pending = false;
    bool hint_failed = false;
    entry(std::shared_ptr<owned_console_parent_watch> native_watch,
          std::uint64_t generation, uid_t native_uid)
        : watch(std::move(native_watch)), runtime_generation(generation), euid(native_uid),
          gate(new publication_gate) {}
  };
  using entry_ptr = std::shared_ptr<entry>;
  // The macOS SDK used by CI lacks atomic<shared_ptr>. Standard shared_ptr
  // operations retain the same sequential consistency and ownership-aware CAS.
#if defined(__cpp_lib_atomic_shared_ptr) && __cpp_lib_atomic_shared_ptr >= 201711L
  using atomic_entry_ptr = std::atomic<entry_ptr>;
#else
  class atomic_entry_ptr final {
    entry_ptr value_;
  public:
    atomic_entry_ptr() noexcept : value_(nullptr) {}
    atomic_entry_ptr(const atomic_entry_ptr&) = delete;
    atomic_entry_ptr& operator=(const atomic_entry_ptr&) = delete;
    entry_ptr load() const noexcept { return std::atomic_load(&value_); }
    bool compare_exchange_strong(entry_ptr& expected, entry_ptr desired) noexcept {
      return std::atomic_compare_exchange_strong(&value_, &expected, std::move(desired));
    }
  };
#endif
  inline static atomic_entry_ptr current_;

  // Allocation and genuine UID/watch observations occur outside all Runtime
  // and publication locks. This inert object cannot register a channel/frame.
  static entry_ptr prepare(std::shared_ptr<owned_console_parent_watch> watch,
                           std::uint64_t actual_runtime_generation) {
    const auto uid = ::geteuid();
    if (!watch || actual_runtime_generation == 0 || uid == 0 || !watch->current()) return nullptr;
    return std::make_shared<entry>(std::move(watch), actual_runtime_generation, uid);
  }
  // Parent retains this SAME entry within the SAME Runtime critical section.
  // No native call, allocation or callback is made while this gate is held.
  static bool publish(const entry_ptr& prepared) noexcept {
    if (!prepared) return false;
    std::lock_guard<std::mutex> lock(prepared->gate->mutex_);
    if (prepared->published || prepared->gate->stopped_ || prepared->gate->generation_ == 0) return false;
    entry_ptr empty;
    if (!current_.compare_exchange_strong(empty, prepared)) return false;
    prepared->published = true;
    return true;
  }
  static void revoke(const entry_ptr& expected) noexcept;
  static void schedule_closures(const entry_ptr& expected) noexcept;
  static bool retired(const entry_ptr& expected) noexcept {
    if (!expected) return false;
    std::lock_guard<std::mutex> lock(expected->gate->mutex_);
    return expected->gate->stopped_ && expected->channels.empty() &&
           !expected->hint_pending && !expected->hint_failed;
  }
  static bool set_retirement_hint(const entry_ptr& expected, std::function<void()> hint) {
    if (!expected || !hint) return false;
    std::lock_guard<std::mutex> lock(expected->gate->mutex_);
    if (expected->retirement_hint || expected->hint_claimed) return false;
    expected->retirement_hint = std::move(hint);
    return true;
  }
  static void schedule_hint(const entry_ptr& expected) noexcept {
    if (!expected) return;
    {
      std::lock_guard<std::mutex> lock(expected->gate->mutex_);
      if (!expected->gate->stopped_ || !expected->channels.empty() ||
          !expected->retirement_hint || expected->hint_claimed) return;
      expected->hint_claimed = true;
      expected->hint_pending = true;
    }
    // Serial main execution is essential: the fixed hint enqueues one main
    // continuation that cannot execute before this hint's own frame unwinds.
    auto* retained = new (std::nothrow) entry_ptr(expected);
    if (!retained) {
      std::lock_guard<std::mutex> lock(expected->gate->mutex_);
      expected->hint_failed = true;
      return;
    }
    ::dispatch_async_f(::dispatch_get_main_queue(), retained, [](void* raw) {
      std::unique_ptr<entry_ptr> retained(static_cast<entry_ptr*>(raw));
      const auto expected = *retained;
      try { expected->retirement_hint(); }
      catch (...) {
        std::lock_guard<std::mutex> lock(expected->gate->mutex_);
        expected->hint_failed = true;
      }
      {
        std::lock_guard<std::mutex> lock(expected->gate->mutex_);
        expected->hint_pending = false;
      }
      entry_ptr exact = expected;
      if (retired(expected)) current_.compare_exchange_strong(exact, nullptr);
    });
  }
  static bool native_current(const entry_ptr& exact, uid_t native_uid) {
    return exact && current_.load().get() == exact.get() && exact->published &&
           exact->runtime_generation != 0 && native_uid == exact->euid &&
           ::geteuid() == exact->euid && exact->watch && exact->watch->current() &&
           current_.load().get() == exact.get();
  }
  static void remove_channel(const entry_ptr& entry, const channel_owner* exact) noexcept;
};
}

class channel_owner final : public std::enable_shared_from_this<channel_owner> {
  friend class socket_lifetime;
  friend class detail::console_registry;
  friend class pqrs::unix_domain_stream::client;
  friend class pqrs::unix_domain_stream::server;
  friend class pqrs::unix_domain_stream::impl::client_state;
  friend class pqrs::unix_domain_stream::impl::server_state;
  friend class pqrs::unix_domain_stream::impl::request_manager;
  friend class krbn::core_service_daemon_client;
  friend class krbn::console_user_server_client;
  friend class krbn::core_service::daemon::receiver;
  friend class krbn::core_service::daemon::console_user_id_changed_receiver;
  friend class krbn::console_user_server::receiver;
  friend class krbn::console_user_server::console_user_id_changed_client;
public:
  channel_owner(const channel_owner&) = delete;
  void revoke() noexcept { gate_->stop(); }
  bool retired() const noexcept {
    std::lock_guard<std::mutex> lock(gate_->mutex_);
    return gate_->stopped_ && sockets_.empty() && construction_debt_ == 0 && !tainted_;
  }
private:
  const auth_policy::route route_;
  const std::optional<std::uint32_t> receiver_uid_;
  const std::shared_ptr<detail::publication_gate> gate_;
  const detail::console_registry::entry_ptr console_;
  std::vector<std::shared_ptr<socket_lifetime>> sockets_;
  std::uint64_t construction_debt_ = 0;
  bool tainted_ = false;
  channel_owner(auth_policy::route route, std::optional<std::uint32_t> uid,
                detail::console_registry::entry_ptr console)
      : route_(route), receiver_uid_(uid), gate_(new detail::publication_gate), console_(std::move(console)) {}
  static std::shared_ptr<channel_owner> make(auth_policy::route route,
                                             std::optional<std::uint32_t> receiver_uid = std::nullopt) {
    detail::cf_owned<SecCodeRef> self;
    if (SecCodeCopySelf(kSecCSDefaultFlags, self.out()) != errSecSuccess) return nullptr;
    const auto actual_self = detail::signing_identity(self.get());
    if (!actual_self) return nullptr;
    detail::console_registry::entry_ptr console;
    const auto native_uid = ::geteuid();
    if (actual_self->role == identity::role::console) {
      console = detail::console_registry::current_.load();
      if (!detail::console_registry::native_current(console, native_uid)) return nullptr;
    }
    auto owner = std::shared_ptr<channel_owner>(new channel_owner(route, receiver_uid, console));
    if (console) {
      std::lock_guard<std::mutex> lock(console->gate->mutex_);
      if (console->gate->stopped_ || detail::console_registry::current_.load().get() != console.get()) return nullptr;
      console->channels.push_back(owner);
    }
    return owner;
  }
  // These fixed methods are accessible only to the actual pinned wrappers.
  static std::shared_ptr<channel_owner> daemon_client() { return make(auth_policy::route::daemon_client); }
  static std::shared_ptr<channel_owner> daemon_server(std::optional<uid_t> uid) {
    return make(auth_policy::route::daemon_server, uid);
  }
  static std::shared_ptr<channel_owner> session_client() { return make(auth_policy::route::session_client); }
  static std::shared_ptr<channel_owner> session_server() { return make(auth_policy::route::session_server); }
  static std::shared_ptr<channel_owner> console_client() { return make(auth_policy::route::console_client); }
  static std::shared_ptr<channel_owner> console_server() { return make(auth_policy::route::console_server); }
  class construction_marker final {
    friend class channel_owner;
    const std::shared_ptr<channel_owner> owner_;
    explicit construction_marker(std::shared_ptr<channel_owner> owner) : owner_(std::move(owner)) {}
  public:
    construction_marker(const construction_marker&) = delete;
    ~construction_marker() { owner_->release_construction(); }
  };
  std::shared_ptr<construction_marker> retain_construction() {
    std::lock_guard<std::mutex> lock(gate_->mutex_);
    if (gate_->stopped_ || tainted_) return nullptr;
    if (construction_debt_ == std::numeric_limits<std::uint64_t>::max()) { tainted_ = true; return nullptr; }
    ++construction_debt_;
    return std::shared_ptr<construction_marker>(new construction_marker(shared_from_this()));
  }
  void release_construction() noexcept {
    {
      std::lock_guard<std::mutex> lock(gate_->mutex_);
      if (construction_debt_ == 0) tainted_ = true;
      else --construction_debt_;
    }
    if (retired() && console_) detail::console_registry::remove_channel(console_, this);
  }
  bool current_gate() const noexcept {
    std::lock_guard<std::mutex> lock(gate_->mutex_);
    return !gate_->stopped_ && !tainted_;
  }
  void schedule_closures() noexcept;
  void remove_socket(const socket_lifetime* exact) noexcept;
};

// Stored callables, including their captures, unwind before real owner debt.
// A lambda's capture-member declaration order is unspecified by C++.
namespace detail {
template <typename Debt, typename Callable>
struct ordered_task final {
  Debt debt;
  Callable callable;

  template <typename... Arguments>
  decltype(auto) operator()(Arguments&&... arguments) {
    return std::invoke(callable, std::forward<Arguments>(arguments)...);
  }
};

template <typename Debt, typename Callable>
auto retain_callable(Debt debt, Callable callable) {
  return ordered_task<Debt, Callable>{std::move(debt), std::move(callable)};
}
} // namespace detail

class frame_scope final {
  friend class socket_lifetime;
  friend class delivery_ticket;
public:
  frame_scope(const frame_scope&) = delete;
  frame_scope& operator=(const frame_scope&) = delete;
  ~frame_scope();
  const frame_view& view() const noexcept { return *frame_; }
  bool permit(std::string_view canonical_operation);
  std::shared_ptr<delivery_ticket> handoff();
private:
  frame_scope(std::shared_ptr<socket_lifetime> socket,
              std::shared_ptr<const frame_view> frame,
              std::shared_ptr<detail::delivery_identity> identity)
      : socket_(std::move(socket)), frame_(std::move(frame)), identity_(std::move(identity)) {}
  const std::shared_ptr<socket_lifetime> socket_;
  const std::shared_ptr<const frame_view> frame_;
  const std::shared_ptr<detail::delivery_identity> identity_;
  std::atomic<bool> handed_off_{false};
};

class delivery_ticket final {
  friend class socket_lifetime;
  friend class frame_scope;
public:
  delivery_ticket(const delivery_ticket&) = delete;
  delivery_ticket& operator=(const delivery_ticket&) = delete;
  ~delivery_ticket();
  bool consume(const std::function<void(frame_scope&)>& handler);
private:
  delivery_ticket(std::shared_ptr<socket_lifetime> socket,
                  std::shared_ptr<const frame_view> frame,
                  std::shared_ptr<detail::delivery_identity> identity)
      : socket_(std::move(socket)), frame_(std::move(frame)), identity_(std::move(identity)) {}
  const std::shared_ptr<socket_lifetime> socket_;
  const std::shared_ptr<const frame_view> frame_;
  const std::shared_ptr<detail::delivery_identity> identity_;
};

// Debt markers do not authorize input. The actual Asio/dispatcher handler owns
// this marker until its stored callable is destroyed AFTER invocation/unwind.
class socket_lifetime final : public std::enable_shared_from_this<socket_lifetime> {
  friend class pqrs::unix_domain_stream::impl::peer;
  friend class pqrs::unix_domain_stream::impl::client_state;
  friend class pqrs::unix_domain_stream::impl::server_state;
  friend class frame_scope;
  friend class delivery_ticket;
  friend class channel_owner;
private:
  enum class task_kind { native, dispatch };
  class task_debt final {
  public:
    task_debt(const task_debt&) = delete;
    ~task_debt() { socket_->release_task(kind_); }
  private:
    friend class socket_lifetime;
    task_debt(std::shared_ptr<socket_lifetime> socket, task_kind kind)
        : socket_(std::move(socket)), kind_(kind) {}
    const std::shared_ptr<socket_lifetime> socket_;
    const task_kind kind_;
  };
  const int descriptor_;
  const std::shared_ptr<channel_owner> owner_;
  bool session_ack_route() const noexcept { return owner_->route_ == auth_policy::route::session_client; }
  const std::shared_ptr<detail::lifetime_gate> gate_;
  std::optional<audit_token_t> initial_;
  std::optional<detail::peer_observation> latest_;
  std::optional<bool> health_only_;
  std::mutex cleanup_mutex_;
  std::uint64_t native_debt_ = 0;
  std::uint64_t dispatch_debt_ = 0;
  std::uint64_t ticket_debt_ = 0;
  bool physically_closed_ = false;
  bool close_failed_ = false;
  bool close_scheduled_ = false;
  bool completion_running_ = false;
  bool completion_delivered_ = false;
  bool completed_ = false;
  std::function<void()> schedule_close_; // fixed actual owner post, never validation
  std::function<void()> completion_;     // actual close observer, outside all locks
  std::function<void()> native_close_step_; // actual fixed IO owner only
  bool staged_ports_ = false;
  std::shared_ptr<socket_lifetime> retained_;

  socket_lifetime(std::shared_ptr<channel_owner> owner, int descriptor)
      : descriptor_(descriptor), owner_(std::move(owner)),
        gate_(new detail::lifetime_gate(owner_->gate_)) {}
  static std::shared_ptr<socket_lifetime> bind(const std::shared_ptr<channel_owner>& owner,
                                               int connected_descriptor) {
    if (!owner || connected_descriptor < 0) return nullptr;
    auto socket = std::shared_ptr<socket_lifetime>(new socket_lifetime(owner, connected_descriptor));
    {
      std::lock_guard<std::mutex> validation(socket->gate_->validation_mutex_);
      if (!socket->sample()) return nullptr;
      // Final publication uses exact Console->channel ordering after native cuts.
      std::unique_lock<std::mutex> console;
      if (owner->console_) {
        console = std::unique_lock<std::mutex>(owner->console_->gate->mutex_);
        if (owner->console_->gate->stopped_ ||
            detail::console_registry::current_.load().get() != owner->console_.get()) return nullptr;
      }
      if (!owner->gate_->publish(socket->gate_)) return nullptr;
      {
        std::lock_guard<std::mutex> channel(owner->gate_->mutex_);
        if (owner->gate_->stopped_ || socket->gate_->revoked_.load()) return nullptr;
        const auto route = owner->route_;
        if ((route == auth_policy::route::daemon_client || route == auth_policy::route::session_client ||
             route == auth_policy::route::console_client) && !owner->sockets_.empty()) return nullptr;
        owner->sockets_.push_back(socket);
      }
    }
    socket->retained_ = socket;
    return socket;
  }
  auth_policy::observation policy(const detail::peer_observation& native) const noexcept {
    auto route = owner_->route_;
    if (health_only_.value_or(false)) {
      switch (route) {
        case auth_policy::route::daemon_server: route = auth_policy::route::daemon_server_health; break;
        case auth_policy::route::session_server: route = auth_policy::route::session_server_health; break;
        case auth_policy::route::console_server: route = auth_policy::route::console_server_health; break;
        default: break;
      }
    }
    return {route, native.self.role, native.peer.role,
            native.self_euid, native.euid, owner_->receiver_uid_};
  }
  bool sample() {
    if (gate_->revoked_.load()) return false;
    if (owner_->console_ &&
        !detail::console_registry::native_current(owner_->console_, ::geteuid())) return refuse();
    const auto native = detail::native_sampler::sample(descriptor_, initial_);
    if (!native) return refuse();
    if (!health_only_) {
      health_only_ = false;
      if (auth_policy::qualify(policy(*native)) == auth_policy::admission::denied) health_only_ = true;
    }
    if (auth_policy::qualify(policy(*native)) == auth_policy::admission::denied ||
        (native->self.role == identity::role::console && !owner_->console_) ||
        (owner_->console_ && !detail::console_registry::native_current(owner_->console_, native->self_euid))) return refuse();
    if (!initial_) initial_ = native->token;
    latest_ = *native;
    return true;
  }
  bool refuse() noexcept { gate_->revoke(); return false; }
  bool current() {
    std::lock_guard<std::mutex> validation(gate_->validation_mutex_);
    if (!sample()) return false;
    std::unique_lock<std::mutex> console;
    if (owner_->console_) {
      console = std::unique_lock<std::mutex>(owner_->console_->gate->mutex_);
      if (owner_->console_->gate->stopped_) return refuse();
    }
    std::lock_guard<std::mutex> channel(owner_->gate_->mutex_);
    return !owner_->gate_->stopped_ && gate_->published_ && !gate_->revoked_.load();
  }
  void revoke() noexcept { gate_->revoke(); request_close(); }
  std::shared_ptr<task_debt> retain_task(task_kind kind) {
    std::lock_guard<std::mutex> lock(cleanup_mutex_);
    if (completed_ || close_failed_) return nullptr;
    auto& count = kind == task_kind::native ? native_debt_ : dispatch_debt_;
    if (count == std::numeric_limits<std::uint64_t>::max()) { close_failed_ = true; return nullptr; }
    ++count;
    return std::shared_ptr<task_debt>(new task_debt(shared_from_this(), kind));
  }
  void release_task(task_kind kind) noexcept {
    {
      std::lock_guard<std::mutex> lock(cleanup_mutex_);
      auto& count = kind == task_kind::native ? native_debt_ : dispatch_debt_;
      if (count == 0) close_failed_ = true;
      else --count;
    }
    request_close();
  }
  void set_close_ports(std::function<void()> schedule, std::function<void()> completion) {
    std::lock_guard<std::mutex> lock(cleanup_mutex_);
    if (schedule_close_ || !schedule || !completion || completed_) { close_failed_ = true; return; }
    schedule_close_ = std::move(schedule);
    completion_ = std::move(completion);
  }
  // The connecting socket and eventual peer share ONE immutable lifetime/token.
  // A queued staged closure dispatches through the current private IO owner;
  // it cannot close the moved-from connecting object or invent a new binding.
  void set_staged_ports(const std::shared_ptr<asio::local::stream_protocol::socket>& socket) {
    if (!socket || !socket->is_open() || socket->native_handle() != descriptor_) { fail_cleanup(); return; }
    const auto executor = socket->get_executor();
    auto self = shared_from_this();
    {
      std::lock_guard<std::mutex> lock(cleanup_mutex_);
      if (schedule_close_ || completed_) { close_failed_ = true; return; }
      staged_ports_ = true;
      schedule_close_ = [self, executor] {
        asio::post(executor, [self] { self->run_native_owner_close(); });
      };
      native_close_step_ = [self, socket] {
        if (self->close_native(*socket)) self->finish_close();
      };
      completion_ = [] {};
    }
    request_close();
  }
  bool has_staged_ports() {
    std::lock_guard<std::mutex> lock(cleanup_mutex_);
    return staged_ports_;
  }
  // Cleanup migration only: it never unrevokes, reseals, publishes or claims.
  // Called by the actual peer on the SAME serial IO executor after socket move.
  bool transfer_close_ports(asio::local::stream_protocol::socket& socket,
                            std::function<void()> native_step, std::function<void()> completion) {
    std::function<void()> old_step, old_completion;
    {
      std::lock_guard<std::mutex> validation(gate_->validation_mutex_);
      std::lock_guard<std::mutex> lock(cleanup_mutex_);
      if (!staged_ports_ || physically_closed_ || completed_ || close_failed_ || !native_step || !completion ||
          !socket.is_open() || socket.native_handle() != descriptor_) { close_failed_ = true; return false; }
      old_step = std::move(native_close_step_);
      old_completion = std::move(completion_);
      native_close_step_ = std::move(native_step);
      completion_ = std::move(completion);
      staged_ports_ = false;
    }
    // Moved-from socket/closures are released only outside all locks.
    return true;
  }
  void run_native_owner_close() {
    std::function<void()> step;
    { std::lock_guard<std::mutex> lock(cleanup_mutex_); step = native_close_step_; }
    if (!step) { fail_cleanup(); return; }
    step();
  }
  void fail_cleanup() noexcept {
    gate_->revoke();
    std::lock_guard<std::mutex> lock(cleanup_mutex_);
    close_failed_ = true;
  }
  void request_close() noexcept {
    std::function<void()> schedule;
    {
      std::lock_guard<std::mutex> lock(cleanup_mutex_);
      if (!gate_->revoked_.load() || close_failed_ || completed_ || close_scheduled_ ||
          !schedule_close_ || gate_->debt_.load() != 0 || dispatch_debt_ != 0 || ticket_debt_ != 0) return;
      close_scheduled_ = true;
      schedule = schedule_close_;
    }
    try { schedule(); }
    catch (...) { std::lock_guard<std::mutex> lock(cleanup_mutex_); close_failed_ = true; }
  }
  // Private fixed native callsite only. This must run on the socket executor.
  bool close_native(asio::local::stream_protocol::socket& socket) {
    std::lock_guard<std::mutex> validation(gate_->validation_mutex_);
    std::lock_guard<std::mutex> lock(cleanup_mutex_);
    close_scheduled_ = false;
    if (!gate_->revoked_.load() || gate_->debt_.load() != 0 || dispatch_debt_ != 0 ||
        ticket_debt_ != 0 || close_failed_) return false;
    if (physically_closed_) return true;
    if (!socket.is_open() || socket.native_handle() != descriptor_) { close_failed_ = true; return false; }
    asio::error_code error;
    socket.cancel(error);
    if (error) { close_failed_ = true; return false; }
    socket.close(error);
    if (error || socket.is_open()) { close_failed_ = true; return false; }
    physically_closed_ = true;
    return true;
  }
  bool completed() {
    std::lock_guard<std::mutex> lock(cleanup_mutex_);
    return completed_ && !close_failed_;
  }
  // Called by a fresh serial IO continuation AFTER native/dispatch callback
  // stored callables have retired. A requested close alone never reaches this.
  void finish_close() {
    std::function<void()> complete;
    {
      std::lock_guard<std::mutex> lock(cleanup_mutex_);
      if (!physically_closed_ || native_debt_ != 0 || dispatch_debt_ != 0 ||
          ticket_debt_ != 0 || gate_->debt_.load() != 0 || close_failed_ || completed_ || completion_running_) return;
      // The fixed owner port drains observers registered while a previous
      // closed notification still held debt. The owner emits its signal once.
      completion_running_ = true;
      complete = completion_;
    }
    try { if (complete) complete(); }
    catch (...) {
      std::lock_guard<std::mutex> lock(cleanup_mutex_);
      close_failed_ = true;
      completion_running_ = false;
      throw;
    }
    {
      std::lock_guard<std::mutex> lock(cleanup_mutex_);
      completion_running_ = false;
      completion_delivered_ = true;
      if (native_debt_ != 0 || dispatch_debt_ != 0 || ticket_debt_ != 0 ||
          gate_->debt_.load() != 0 || close_failed_) return;
      completed_ = true;
      schedule_close_ = nullptr;
      completion_ = nullptr;
      native_close_step_ = nullptr;
    }
    owner_->remove_socket(this);
    retained_.reset();
  }
  std::shared_ptr<delivery_ticket> ticket(frame_kind kind, std::uint64_t request_id,
                                         std::vector<std::uint8_t> payload) {
    std::lock_guard<std::mutex> validation(gate_->validation_mutex_);
    if (!sample()) return nullptr;
    if (health_only_.value_or(false) &&
        ((kind != frame_kind::health_check && kind != frame_kind::health_check_response) ||
         request_id != 0 || !payload.empty())) { refuse(); return nullptr; }
    std::shared_ptr<detail::delivery_identity> identity;
    {
      std::unique_lock<std::mutex> console;
      if (owner_->console_) {
        console = std::unique_lock<std::mutex>(owner_->console_->gate->mutex_);
        if (owner_->console_->gate->stopped_ ||
            detail::console_registry::current_.load().get() != owner_->console_.get()) return nullptr;
      }
      identity = gate_->new_identity();
    }
    if (!identity) return nullptr;
    auto frame = std::shared_ptr<const frame_view>(new frame_view(kind, request_id, std::move(payload), *latest_));
    {
      std::lock_guard<std::mutex> lock(cleanup_mutex_);
      if (ticket_debt_ == std::numeric_limits<std::uint64_t>::max()) { close_failed_ = true; return nullptr; }
      ++ticket_debt_;
    }
    return std::shared_ptr<delivery_ticket>(new delivery_ticket(shared_from_this(), std::move(frame), identity));
  }
  bool claim(const std::shared_ptr<detail::delivery_identity>& identity,
             const std::optional<std::string>& operation = std::nullopt) {
    std::lock_guard<std::mutex> validation(gate_->validation_mutex_);
    if (!sample() || (operation &&
        auth_policy::operation_admission(policy(*latest_), *operation) == auth_policy::admission::denied)) return refuse();
    std::unique_lock<std::mutex> console;
    if (owner_->console_) {
      console = std::unique_lock<std::mutex>(owner_->console_->gate->mutex_);
      if (owner_->console_->gate->stopped_ ||
          detail::console_registry::current_.load().get() != owner_->console_.get()) return refuse();
    }
    return gate_->claim(identity);
  }
  bool permit(std::string_view operation) {
    std::lock_guard<std::mutex> validation(gate_->validation_mutex_);
    if (!sample() || auth_policy::operation_admission(policy(*latest_), operation) == auth_policy::admission::denied) return refuse();
    std::unique_lock<std::mutex> console;
    if (owner_->console_) {
      console = std::unique_lock<std::mutex>(owner_->console_->gate->mutex_);
      if (owner_->console_->gate->stopped_) return refuse();
    }
    std::lock_guard<std::mutex> channel(owner_->gate_->mutex_);
    return !owner_->gate_->stopped_ && !gate_->revoked_.load();
  }
  std::shared_ptr<delivery_ticket> handoff(const std::shared_ptr<const frame_view>& frame,
                                          const std::shared_ptr<detail::delivery_identity>& identity,
                                          std::atomic<bool>& once) {
    std::lock_guard<std::mutex> validation(gate_->validation_mutex_);
    if (!sample()) return nullptr;
    std::shared_ptr<detail::delivery_identity> next;
    {
      std::unique_lock<std::mutex> console;
      if (owner_->console_) {
        console = std::unique_lock<std::mutex>(owner_->console_->gate->mutex_);
        if (owner_->console_->gate->stopped_ ||
            detail::console_registry::current_.load().get() != owner_->console_.get()) return nullptr;
      }
      next = gate_->handoff(identity, once);
    }
    if (!next) return nullptr;
    {
      std::lock_guard<std::mutex> lock(cleanup_mutex_);
      if (ticket_debt_ == std::numeric_limits<std::uint64_t>::max()) { close_failed_ = true; return nullptr; }
      ++ticket_debt_;
    }
    return std::shared_ptr<delivery_ticket>(new delivery_ticket(shared_from_this(), frame, next));
  }
  void release_ticket() noexcept {
    {
      std::lock_guard<std::mutex> lock(cleanup_mutex_);
      if (ticket_debt_ == 0) close_failed_ = true;
      else --ticket_debt_;
    }
    request_close();
  }
};

inline frame_scope::~frame_scope() {
  socket_->gate_->unwind();
  socket_->request_close();
}
inline bool frame_scope::permit(std::string_view operation) { return socket_->permit(operation); }
inline std::shared_ptr<delivery_ticket> frame_scope::handoff() { return socket_->handoff(frame_, identity_, handed_off_); }
inline delivery_ticket::~delivery_ticket() { socket_->release_ticket(); }
inline bool delivery_ticket::consume(const std::function<void(frame_scope&)>& handler) {
  if (!handler) { socket_->revoke(); return false; }
  std::optional<std::string> operation;
  if (frame_->kind() == frame_kind::user_data || frame_->kind() == frame_kind::request ||
      frame_->kind() == frame_kind::response) {
    if (frame_->kind() == frame_kind::response && frame_->payload().empty()) {
      // The real session receiver's ACK has no payload. This internal hop
      // carries no operation effect; the request manager still requires the
      // actual pending console_user_id_changed request before its callback.
      if (!socket_->session_ack_route()) {
        socket_->revoke(); return false;
      }
    } else try {
      const auto parsed = nlohmann::json::from_msgpack(frame_->payload());
      if (!parsed.is_object() || !parsed.contains("operation_type") || !parsed.at("operation_type").is_string()) {
        socket_->revoke(); return false;
      }
      operation = parsed.at("operation_type").get<std::string>();
    } catch (...) { socket_->revoke(); return false; }
  }
  if (!socket_->claim(identity_, operation)) return false;
  frame_scope scope(socket_, frame_, identity_);
  try { handler(scope); }
  catch (...) { socket_->revoke(); throw; }
  return true;
}
inline void channel_owner::schedule_closures() noexcept {
  std::vector<std::shared_ptr<socket_lifetime>> sockets;
  {
    std::lock_guard<std::mutex> lock(gate_->mutex_);
    sockets = sockets_;
  }
  for (const auto& socket : sockets) socket->revoke();
  if (retired() && console_) detail::console_registry::remove_channel(console_, this);
}
inline void channel_owner::remove_socket(const socket_lifetime* exact) noexcept {
  {
    std::lock_guard<std::mutex> lock(gate_->mutex_);
    sockets_.erase(std::remove_if(sockets_.begin(), sockets_.end(),
                    [exact](const auto& value) { return value.get() == exact; }), sockets_.end());
  }
  if (retired() && console_) detail::console_registry::remove_channel(console_, this);
}
inline void detail::console_registry::revoke(const entry_ptr& expected) noexcept {
  if (!expected) return;
  std::lock_guard<std::mutex> lock(expected->gate->mutex_);
  expected->gate->stopped_ = true;
  for (const auto& channel : expected->channels) channel->revoke();
}
inline void detail::console_registry::schedule_closures(const entry_ptr& expected) noexcept {
  if (!expected) return;
  std::vector<std::shared_ptr<channel_owner>> channels;
  {
    std::lock_guard<std::mutex> lock(expected->gate->mutex_);
    channels = expected->channels;
  }
  for (const auto& channel : channels) channel->schedule_closures();
  schedule_hint(expected);
}
inline void detail::console_registry::remove_channel(const entry_ptr& expected, const channel_owner* exact) noexcept {
  {
    std::lock_guard<std::mutex> lock(expected->gate->mutex_);
    expected->channels.erase(std::remove_if(expected->channels.begin(), expected->channels.end(),
                             [exact](const auto& value) { return value.get() == exact; }), expected->channels.end());
  }
  schedule_hint(expected);
}
} // namespace ergoptiplus::remap::auth
