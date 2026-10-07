#pragma once

// The official VirtualHID broker has a different signing authority from the
// Ergopti Core/Console/CLI roles. This prerequisite never authorizes capture.
#include "remap_runtime_auth.hpp"
#include <CommonCrypto/CommonDigest.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/acl.h>
#include <sys/stat.h>
#include <array>
#include <cerrno>
#include <set>
#include <map>

namespace pqrs::unix_domain_stream::impl { class request_manager; }
namespace pqrs::karabiner::driverkit::virtual_hid_device_service { class client; }
namespace krbn::core_service::daemon { class device_grabber; }
namespace ergoptiplus::remap::vhd {
class broker_owner;
class connection;
class initializer_delivery;
namespace detail {
using auth::detail::cf_owned;
inline constexpr char daemon_path[] = "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app";
inline constexpr char endpoint[] = "/Library/Application Support/org.pqrs/tmp/rootonly/karabiner_virtual_hid_device_service.sock";
inline constexpr char identifier[] = "org.pqrs.Karabiner-VirtualHIDDevice-Daemon";
inline constexpr char executable[] = "Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon";
inline constexpr char x86_hash[] = "3736778029bc84c96bf1af782f81b86bb164bb3f";
inline constexpr char arm_hash[] = "c10ecd105806ecfc53c3c71b9b49affbe7a369f2";
inline constexpr char official_requirement[] =
    "identifier \"org.pqrs.Karabiner-VirtualHIDDevice-Daemon\" and anchor apple generic and "
    "certificate leaf[subject.OU] = \"G43BCU2T37\" and "
    "(cdhash H\"3736778029bc84c96bf1af782f81b86bb164bb3f\" or "
    "cdhash H\"c10ecd105806ecfc53c3c71b9b49affbe7a369f2\")";

inline bool same(const struct stat& a, const struct stat& b) noexcept {
  // Access time is changed by a genuine read, not by a changed source image.
  return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
      a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_size == b.st_size &&
      a.st_nlink == b.st_nlink && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec &&
      a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
      a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
}
inline bool protected_fd(int fd, const struct stat& s) noexcept {
  if (s.st_uid != 0 || (s.st_mode & 0022) != 0 ||
      (!S_ISDIR(s.st_mode) && (!S_ISREG(s.st_mode) || s.st_nlink != 1))) return false;
  auto acl = ::acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
  if (!acl) return false;
  acl_entry_t entry = nullptr;
  errno = 0;
  const auto valid = ::acl_valid(acl);
  const auto result = valid == 0 ? ::acl_get_entry(acl, ACL_FIRST_ENTRY, &entry) : 0;
  const auto error = errno;
  const auto released = ::acl_free(acl);
  return valid == 0 && result == -1 && error == EINVAL && released == 0;
}
inline std::optional<std::string> digest(int fd, off_t length) {
  if (length < 0 || length > 8 * 1024 * 1024) return std::nullopt;
  std::vector<std::uint8_t> data(static_cast<std::size_t>(length));
  std::size_t at = 0;
  while (at < data.size()) {
    const auto count = ::pread(fd, data.data() + at, data.size() - at, static_cast<off_t>(at));
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return std::nullopt;
    at += static_cast<std::size_t>(count);
  }
  std::uint8_t extra = 0;
  if (::pread(fd, &extra, 1, length) != 0) return std::nullopt;
  std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> hash{};
  if (!CC_SHA256(data.data(), static_cast<CC_LONG>(data.size()), hash.data())) return std::nullopt;
  constexpr char hex[] = "0123456789abcdef";
  std::string result;
  for (auto byte : hash) { result += hex[byte >> 4]; result += hex[byte & 15]; }
  return result;
}
inline std::optional<std::set<std::string>> members(int fd, bool& close_failed) {
  // An independently opened descriptor avoids changing the held directory's
  // offset. Custody is recorded before any operation that can refuse.
  const auto child = ::openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (child < 0) return std::nullopt;
  auto directory = ::fdopendir(child);
  if (!directory) { if (::close(child) != 0) close_failed = true; return std::nullopt; }
  std::set<std::string> result;
  errno = 0;
  while (auto entry = ::readdir(directory)) {
    const std::string name(entry->d_name);
    if (name == "." || name == "..") continue;
    if (result.size() == 256 || name.empty() || name.find('/') != std::string::npos) {
      if (::closedir(directory) != 0) close_failed = true; return std::nullopt;
    }
    result.insert(name);
    errno = 0;
  }
  const auto error = errno;
  const auto close = ::closedir(directory);
  if (close != 0) close_failed = true;
  if (error != 0 || close != 0) return std::nullopt;
  return result;
}

// This object owns actual descriptors, not a JSON observation or source path.
class daemon_reference final {
  friend class ::ergoptiplus::remap::vhd::broker_owner;
  friend class ::ergoptiplus::remap::vhd::connection;
  struct node final {
    int fd;
    int parent;
    std::string name;
    struct stat stamp{};
    std::optional<std::string> hash;
    std::optional<std::set<std::string>> children;
  };
  std::vector<node> nodes_;
  bool close_failed_ = false;
  bool retired_ = false;
  cf_owned<SecRequirementRef> requirement_;

  int pin(int parent, const std::string& name, bool directory) {
    struct stat named{};
    if ((parent < 0 ? ::lstat("/", &named) : ::fstatat(parent, name.c_str(), &named, AT_SYMLINK_NOFOLLOW)) != 0 ||
        (directory ? !S_ISDIR(named.st_mode) : !S_ISREG(named.st_mode))) return -1;
    const auto fd = parent < 0 ? ::open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        : ::openat(parent, name.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (directory ? O_DIRECTORY : 0));
    if (fd < 0) return -1;
    try { nodes_.push_back({fd, parent, name, named, std::nullopt, std::nullopt}); }
    catch (...) { if (::close(fd) != 0) close_failed_ = true; throw; }
    struct stat held{};
    if (::fstat(fd, &held) != 0 || !same(named, held) || !protected_fd(fd, held)) return -1;
    return fd;
  }
  bool tree(int fd, const std::string& prefix) {
    auto names = members(fd, close_failed_);
    if (!names) return false;
    const auto found = std::find_if(nodes_.begin(), nodes_.end(), [fd](const auto& n) { return n.fd == fd; });
    if (found == nodes_.end()) return false;
    found->children = *names;
    for (const auto& name : *names) {
      if (nodes_.size() >= 256) return false;
      struct stat before{};
      if (::fstatat(fd, name.c_str(), &before, AT_SYMLINK_NOFOLLOW) != 0) return false;
      const auto child = pin(fd, name, S_ISDIR(before.st_mode));
      if (child < 0) return false;
      const auto path = prefix.empty() ? name : prefix + "/" + name;
      if (S_ISDIR(before.st_mode)) {
        if (!tree(child, path)) return false;
      } else {
        const auto hash = digest(child, before.st_size);
        if (!hash) return false;
        nodes_.back().hash = *hash;
        const auto expected = file_hashes();
        const auto fixed = expected.find(path);
        if (fixed == expected.end() || fixed->second != *hash) return false;
      }
    }
    return true;
  }
  static std::map<std::string, std::string> file_hashes() {
    return {
      {"Contents/_CodeSignature/CodeResources", "c541af24a376259cd600371fd60911d2bd26765af00013c4078ee66eb0aa164c"},
      {"Contents/embedded.provisionprofile", "c38ad42248a52500e819a9b001c0e56f464bfb95935758db53f10e3fbc2bbc34"},
      {"Contents/Info.plist", "0fb5e8877dbbf929dd5fb8f1cfce7fe737971bf355c39d29a4fc5c7c44e05f99"},
      {"Contents/Resources/app.icns", "a04f2c5b8a37caa88fec8b80d50d2459596df50273c5b406bba3bacf302bb032"},
      {"Contents/PkgInfo", "82502191c9484b04d685374f9879a0066069c49b8acae7a04b01d38d07e8eca0"},
      {executable, "9620bd06cbbfbd377689fb5a0ba2f1e1bd346effe089fe49a083d7963f1a76ab"},
    };
  }
  static std::optional<std::string> data_hex(CFTypeRef value) {
    if (!value || CFGetTypeID(value) != CFDataGetTypeID()) return std::nullopt;
    auto data = static_cast<CFDataRef>(value);
    if (CFDataGetLength(data) != 20 || !CFDataGetBytePtr(data)) return std::nullopt;
    constexpr char hex[] = "0123456789abcdef";
    std::string result;
    for (CFIndex i = 0; i < 20; ++i) { auto b = CFDataGetBytePtr(data)[i]; result += hex[b >> 4]; result += hex[b & 15]; }
    return result;
  }
  bool signing(SecStaticCodeRef code, const char* fixed) {
    cf_owned<CFDictionaryRef> information;
    if (SecCodeCopySigningInformation(code, kSecCSSigningInformation, information.out()) != errSecSuccess ||
        !information.get()) return false;
    auto info = information.get();
    const auto id = auth::detail::exact_string(CFDictionaryGetValue(info, kSecCodeInfoIdentifier));
    const auto team = auth::detail::signing_team(info);
    const auto hash = data_hex(CFDictionaryGetValue(info, kSecCodeInfoUnique));
    const auto cms = CFDictionaryGetValue(info, kSecCodeInfoCMS);
    const auto certificates = CFDictionaryGetValue(info, kSecCodeInfoCertificates);
    const auto plist_value = CFDictionaryGetValue(info, kSecCodeInfoPList);
    if (!plist_value || CFGetTypeID(plist_value) != CFDictionaryGetTypeID()) return false;
    auto plist = static_cast<CFDictionaryRef>(plist_value);
    const auto bundle_id = auth::detail::exact_string(CFDictionaryGetValue(plist, CFSTR("CFBundleIdentifier")));
    const auto version = auth::detail::exact_string(CFDictionaryGetValue(plist, CFSTR("CFBundleVersion")));
    const auto short_version = auth::detail::exact_string(CFDictionaryGetValue(plist, CFSTR("CFBundleShortVersionString")));
    const auto executable_name = auth::detail::exact_string(CFDictionaryGetValue(plist, CFSTR("CFBundleExecutable")));
    const auto main_executable = CFDictionaryGetValue(info, kSecCodeInfoMainExecutable);
    cf_owned<CFURLRef> expected_executable;
    const std::string executable_path = std::string(daemon_path) + "/" + executable;
    *expected_executable.out() = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(executable_path.data()), static_cast<CFIndex>(executable_path.size()), false);
    if (!bundle_id || *bundle_id != identifier || !version || *version != "8.5.0" ||
        !short_version || *short_version != "8.5.0" || !executable_name || *executable_name != "Karabiner-VirtualHIDDevice-Daemon" ||
        !main_executable || CFGetTypeID(main_executable) != CFURLGetTypeID() || !expected_executable.get() ||
        !CFEqual(main_executable, expected_executable.get())) return false;
    return id && *id == identifier && team && *team == "G43BCU2T37" && hash &&
        (fixed ? *hash == fixed : (*hash == x86_hash || *hash == arm_hash)) &&
        cms && CFGetTypeID(cms) == CFDataGetTypeID() && CFDataGetLength(static_cast<CFDataRef>(cms)) > 0 &&
        certificates && CFGetTypeID(certificates) == CFArrayGetTypeID() && CFArrayGetCount(static_cast<CFArrayRef>(certificates)) > 0;
  }
  bool acquire() {
    auto parent = pin(-1, "/", true);
    if (parent < 0) return false;
    for (const char* name : {"Library", "Application Support", "org.pqrs", "Karabiner-DriverKit-VirtualHIDDevice", "Applications", "Karabiner-VirtualHIDDevice-Daemon.app"}) {
      parent = pin(parent, name, true);
      if (parent < 0) return false;
    }
    const auto tree_begin = nodes_.size();
    if (!tree(parent, "") || nodes_.size() != tree_begin + 10 || !current()) return false;
    // Fixed files plus native signature validation cover the secured bundle
    // fields and both supported CodeDirectories. No ABI compatibility inference.
    cf_owned<CFURLRef> url;
    *url.out() = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(daemon_path), sizeof(daemon_path) - 1, true);
    cf_owned<CFStringRef> text;
    *text.out() = CFStringCreateWithCString(kCFAllocatorDefault, official_requirement, kCFStringEncodingUTF8);
    if (!url.get() || !text.get() ||
        SecRequirementCreateWithString(text.get(), kSecCSDefaultFlags, requirement_.out()) != errSecSuccess) return false;
    cf_owned<SecStaticCodeRef> code;
    if (SecStaticCodeCreateWithPath(url.get(), kSecCSDefaultFlags, code.out()) != errSecSuccess ||
        !code.get() || SecStaticCodeCheckValidity(code.get(), kSecCSStrictValidate | kSecCSCheckAllArchitectures, requirement_.get()) != errSecSuccess) return false;
    for (const auto& slice : {std::pair{"x86_64", x86_hash}, std::pair{"arm64", arm_hash}}) {
      cf_owned<CFStringRef> architecture;
      *architecture.out() = CFStringCreateWithCString(kCFAllocatorDefault, slice.first, kCFStringEncodingUTF8);
      const void* keys[] = {kSecCodeAttributeArchitecture};
      const void* values[] = {architecture.get()};
      cf_owned<CFDictionaryRef> attributes;
      *attributes.out() = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
      cf_owned<SecStaticCodeRef> selected;
      if (!architecture.get() || !attributes.get() ||
          SecStaticCodeCreateWithPathAndAttributes(url.get(), kSecCSDefaultFlags, attributes.get(), selected.out()) != errSecSuccess ||
          !selected.get() || SecStaticCodeCheckValidity(selected.get(), kSecCSStrictValidate, requirement_.get()) != errSecSuccess ||
          !signing(selected.get(), slice.second) || !current()) return false;
    }
    return current();
  }
  bool current() {
    if (retired_ || close_failed_ || nodes_.empty()) return false;
    for (const auto& n : nodes_) {
      struct stat held{}, named{};
      if (::fstat(n.fd, &held) != 0 ||
          (n.parent < 0 ? ::lstat("/", &named) : ::fstatat(n.parent, n.name.c_str(), &named, AT_SYMLINK_NOFOLLOW)) != 0 ||
          !same(n.stamp, held) || !same(n.stamp, named) || !protected_fd(n.fd, held) ||
          (n.hash && digest(n.fd, held.st_size) != n.hash) ||
          (n.children && members(n.fd, close_failed_) != n.children)) return false;
    }
    return true;
  }
  bool retire() noexcept {
    if (retired_) return !close_failed_;
    for (auto i = nodes_.rbegin(); i != nodes_.rend(); ++i) {
      // close(2) failure is an irreversible custody ambiguity. Do not retry an
      // FD number which another thread could already have reused.
      if (::close(i->fd) != 0) close_failed_ = true;
      i->fd = -1;
    }
    retired_ = true;
    return !close_failed_;
  }
  ~daemon_reference() { if (!retired_) retire(); }
};
} // namespace detail

// One fixed actual process owns this reference and every connected generation.
// Public retirement is a request. Only native closure plus drained custody debt
// can make retired() true. An ambiguous close retains a failed owner.
class broker_owner final : public std::enable_shared_from_this<broker_owner> {
  friend class connection;
  friend class pqrs::unix_domain_stream::impl::client_state;
  friend class pqrs::unix_domain_stream::impl::request_manager;
  friend class pqrs::unix_domain_stream::client;
  friend class pqrs::karabiner::driverkit::virtual_hid_device_service::client;
  std::recursive_mutex mutex_;
  detail::daemon_reference reference_;
  bool acquired_ = false;
  bool revoked_ = false;
  bool failed_ = false;
  bool retired_ = false;
  std::uint64_t generation_ = 0;
  std::uint64_t construction_debt_ = 0;
  std::vector<std::shared_ptr<connection>> sessions_;
  std::shared_ptr<broker_owner> retained_;
  broker_owner() = default;
  class construction final {
    friend class broker_owner;
    const std::shared_ptr<broker_owner> owner_;
    explicit construction(std::shared_ptr<broker_owner> owner) : owner_(std::move(owner)) {}
  public:
    ~construction() { owner_->release_construction(); }
  };
  std::shared_ptr<construction> retain_construction() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (revoked_ || failed_ || retired_ || !acquired_ ||
        construction_debt_ == std::numeric_limits<std::uint64_t>::max()) return nullptr;
    ++construction_debt_;
    return std::shared_ptr<construction>(new construction(shared_from_this()));
  }
  void release_construction();
  bool current() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    return !revoked_ && !failed_ && !retired_ && acquired_ && reference_.current();
  }
  enum class queue { native, dispatch };
  std::shared_ptr<void> retain_work(queue kind);
  std::shared_ptr<connection> active();
  void settle();
  void failed_cleanup() noexcept {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    failed_ = true;
    revoked_ = true;
  }
public:
  static std::shared_ptr<broker_owner> acquire() {
    auto owner = std::shared_ptr<broker_owner>(new broker_owner());
    // Custody exists before native acquisition. A partial failed acquisition is
    // returned as a closed owner, so its caller can retain/report failed cleanup.
    owner->retained_ = owner;
    try { owner->acquired_ = owner->reference_.acquire(); }
    catch (...) { owner->revoked_ = true; owner->settle(); throw; }
    if (!owner->acquired_) { owner->revoked_ = true; owner->settle(); }
    return owner;
  }
  void retire();
  bool retired() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    return retired_ && !failed_;
  }
};

class connection final : public std::enable_shared_from_this<connection> {
  friend class initializer_delivery;
  friend class broker_owner;
  friend class pqrs::unix_domain_stream::impl::client_state;
  friend class pqrs::unix_domain_stream::impl::request_manager;
  friend class pqrs::unix_domain_stream::impl::peer;
  friend class pqrs::unix_domain_stream::client;
  friend class pqrs::karabiner::driverkit::virtual_hid_device_service::client;
  enum class task_kind { native, dispatch };
  class task final {
    friend class connection;
    const std::shared_ptr<connection> session_;
    const task_kind kind_;
    task(std::shared_ptr<connection> session, task_kind kind)
        : session_(std::move(session)), kind_(kind) {}
  public:
    ~task() { session_->release_task(kind_); }
  };
  const std::shared_ptr<broker_owner> owner_;
  const int descriptor_;
  const std::uint64_t generation_;
  std::optional<audit_token_t> token_;
  bool revoked_ = false;
  bool failed_ = false;
  bool physical_ = false;
  bool completed_ = false;
  bool staged_ = true;
  bool scheduled_ = false;
  bool notified_ = false;
  bool notification_active_ = false;
  std::uint64_t native_debt_ = 0;
  std::uint64_t dispatch_debt_ = 0;
  std::function<void()> schedule_;
  std::function<void()> close_;
  std::function<void()> completion_;
  connection(std::shared_ptr<broker_owner> owner, int fd, std::uint64_t generation)
      : owner_(std::move(owner)), descriptor_(fd), generation_(generation) {}
  static bool peer_token(int fd, audit_token_t& token, pid_t& pid) noexcept {
    socklen_t length = sizeof(token), pid_length = sizeof(pid);
    return fd >= 0 && ::getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 &&
        length == sizeof(token) && ::getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pid_length) == 0 &&
        pid_length == sizeof(pid) && pid > 1;
  }
  bool sample() {
    if (revoked_ || failed_ || physical_ || completed_ || !owner_->current()) return false;
    audit_token_t first{}, last{};
    pid_t native_pid = -1, final_pid = -1, pid = -1;
    uid_t uid = static_cast<uid_t>(-1), cached_uid = static_cast<uid_t>(-1);
    gid_t gid = static_cast<gid_t>(-1), cached_gid = static_cast<gid_t>(-1);
    if (!peer_token(descriptor_, first, native_pid) ||
        (token_ && std::memcmp(&*token_, &first, sizeof(first)) != 0)) return false;
    audit_token_to_au32(first, nullptr, &uid, &gid, nullptr, nullptr, &pid, nullptr, nullptr);
    if (uid != 0 || pid != native_pid || ::getpeereid(descriptor_, &cached_uid, &cached_gid) != 0 ||
        cached_uid != uid || cached_gid != gid) return false;
    detail::cf_owned<CFDataRef> audit;
    *audit.out() = CFDataCreate(kCFAllocatorDefault, reinterpret_cast<const UInt8*>(&first), sizeof(first));
    const void* keys[] = {kSecGuestAttributeAudit};
    const void* values[] = {audit.get()};
    detail::cf_owned<CFDictionaryRef> attributes;
    if (!audit.get()) return false;
    *attributes.out() = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    detail::cf_owned<SecCodeRef> live;
    detail::cf_owned<SecStaticCodeRef> fixed;
    if (!attributes.get() || SecCodeCopyGuestWithAttributes(nullptr, attributes.get(), kSecCSDefaultFlags, live.out()) != errSecSuccess ||
        !live.get() || SecCodeCheckValidity(live.get(), kSecCSStrictValidate, owner_->reference_.requirement_.get()) != errSecSuccess ||
        SecCodeCopyStaticCode(live.get(), kSecCSDefaultFlags, fixed.out()) != errSecSuccess || !fixed.get() ||
        !owner_->reference_.signing(fixed.get(), nullptr)) return false;
    detail::cf_owned<CFURLRef> located;
    detail::cf_owned<CFURLRef> expected;
    *expected.out() = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(detail::daemon_path), sizeof(detail::daemon_path) - 1, true);
    if (!expected.get() || SecCodeCopyPath(fixed.get(), kSecCSDefaultFlags, located.out()) != errSecSuccess ||
        !located.get() || !CFEqual(located.get(), expected.get()) || !owner_->reference_.current() ||
        SecCodeCheckValidity(live.get(), kSecCSStrictValidate, owner_->reference_.requirement_.get()) != errSecSuccess ||
        !peer_token(descriptor_, last, final_pid) || final_pid != pid || std::memcmp(&first, &last, sizeof(first)) != 0 ||
        ::getpeereid(descriptor_, &cached_uid, &cached_gid) != 0 || cached_uid != uid || cached_gid != gid) return false;
    if (!token_) token_ = first;
    return true;
  }
  static std::shared_ptr<connection> stage(const std::shared_ptr<broker_owner>& owner,
      const std::shared_ptr<asio::local::stream_protocol::socket>& socket) {
    if (!owner || !socket || !socket->is_open()) return nullptr;
    std::lock_guard<std::recursive_mutex> lock(owner->mutex_);
    if (owner->revoked_ || owner->failed_ || owner->retired_ || !owner->acquired_ || !owner->sessions_.empty() ||
        owner->generation_ == std::numeric_limits<std::uint64_t>::max()) return nullptr;
    auto session = std::shared_ptr<connection>(new connection(owner, socket->native_handle(), ++owner->generation_));
    owner->sessions_.push_back(session);
    const auto executor = socket->get_executor();
    session->schedule_ = [session, executor] {
      asio::dispatch(executor, [session] { session->close_step(); });
    };
    session->close_ = [session, socket] { session->close_native(*socket); };
    // The socket is already in owned custody, even if native identity refuses.
    // Returning this closed session lets the actual lower caller retire it.
    if (!session->sample()) session->revoked_ = true;
    return session;
  }
  bool current() {
    std::lock_guard<std::recursive_mutex> lock(owner_->mutex_);
    if (generation_ != owner_->generation_ || !sample()) { revoked_ = true; return false; }
    return true;
  }
  std::shared_ptr<task> retain_task(task_kind kind) {
    std::lock_guard<std::recursive_mutex> lock(owner_->mutex_);
    if (completed_ || failed_) return nullptr;
    auto& count = kind == task_kind::native ? native_debt_ : dispatch_debt_;
    if (count == std::numeric_limits<std::uint64_t>::max()) { failed_ = true; return nullptr; }
    ++count;
    return std::shared_ptr<task>(new task(shared_from_this(), kind));
  }
  void release_task(task_kind kind) noexcept {
    {
      std::lock_guard<std::recursive_mutex> lock(owner_->mutex_);
      auto& count = kind == task_kind::native ? native_debt_ : dispatch_debt_;
      if (count == 0) failed_ = true;
      else --count;
    }
    request_close();
  }
  void revoke() noexcept {
    { std::lock_guard<std::recursive_mutex> lock(owner_->mutex_); revoked_ = true; }
    request_close();
  }
  void fail_cleanup() noexcept {
    std::lock_guard<std::recursive_mutex> lock(owner_->mutex_);
    failed_ = true; revoked_ = true; owner_->failed_ = true; owner_->revoked_ = true;
  }
  void request_close() noexcept {
    std::function<void()> schedule;
    {
      std::lock_guard<std::recursive_mutex> lock(owner_->mutex_);
      if (!revoked_ || failed_ || completed_ || scheduled_ || dispatch_debt_ != 0 || !schedule_) return;
      scheduled_ = true;
      schedule = schedule_;
    }
    try { schedule(); } catch (...) { fail_cleanup(); }
  }
  bool migrate(asio::local::stream_protocol::socket& socket, std::function<void()> close,
      std::function<void()> completion) {
    std::function<void()> old_close, old_completion;
    std::lock_guard<std::recursive_mutex> lock(owner_->mutex_);
    if (!staged_ || physical_ || failed_ || completed_ || !close || !completion ||
        !socket.is_open() || socket.native_handle() != descriptor_) { fail_cleanup(); return false; }
    staged_ = false;
    old_close = std::move(close_); old_completion = std::move(completion_);
    close_ = std::move(close);
    completion_ = std::move(completion);
    return true;
  }
  void close_native(asio::local::stream_protocol::socket& socket) {
    std::lock_guard<std::recursive_mutex> lock(owner_->mutex_);
    if (!revoked_ || dispatch_debt_ != 0 || failed_) return;
    if (physical_) return;
    if (!socket.is_open() || socket.native_handle() != descriptor_) { fail_cleanup(); return; }
    asio::error_code error;
    socket.cancel(error);
    if (error) { fail_cleanup(); return; }
    socket.close(error);
    if (error || socket.is_open()) { fail_cleanup(); return; }
    physical_ = true;
  }
  void close_step() {
    std::function<void()> operation, notification, released_schedule, released_close, released_completion;
    {
      std::lock_guard<std::recursive_mutex> lock(owner_->mutex_);
      scheduled_ = false;
      if (notification_active_) return;
      if (!revoked_ || failed_ || completed_ || dispatch_debt_ != 0) return;
      operation = close_;
    }
    if (!operation) { fail_cleanup(); return; }
    operation();
    {
      std::lock_guard<std::recursive_mutex> lock(owner_->mutex_);
      if (!physical_ || native_debt_ != 0 || dispatch_debt_ != 0 || failed_ || completed_) return;
      if (!notified_ && completion_) { notified_ = true; notification = completion_; notification_active_ = true; }
    }
    if (notification) {
      // An actual peer close observer can reenter retirement before the peer
      // admits its follow-on dispatcher debt. Retain that notification frame
      // until it returns; do not hold the owner mutex across user callbacks.
      try { notification(); }
      catch (...) {
        std::lock_guard<std::recursive_mutex> lock(owner_->mutex_);
        notification_active_ = false;
        fail_cleanup();
        return;
      }
      std::lock_guard<std::recursive_mutex> lock(owner_->mutex_);
      notification_active_ = false;
    }
    {
      std::lock_guard<std::recursive_mutex> lock(owner_->mutex_);
      if (notification_active_) return;
      if (!physical_ || native_debt_ != 0 || dispatch_debt_ != 0 || failed_ || completed_) return;
      completed_ = true;
      released_schedule = std::move(schedule_); released_close = std::move(close_); released_completion = std::move(completion_);
    }
    owner_->settle();
  }
  bool completed() {
    std::lock_guard<std::recursive_mutex> lock(owner_->mutex_);
    return completed_ && !failed_;
  }
};

// This is an observation of one delivered initializer request, never a native
// initialization-success, initialized-ready, DriverKit or capture capability.
// Only the actual upper initializer callsite constructs an intent. The actual
// lower manager binds its own nonzero id, sent bytes and connected generation.
enum class initializer_kind { keyboard, pointing };
class initializer_delivery final {
  friend class pqrs::unix_domain_stream::impl::request_manager;
  friend class pqrs::unix_domain_stream::impl::client_state;
  friend class pqrs::karabiner::driverkit::virtual_hid_device_service::client;
public:
  enum class observation { unbound, pending, delivered, refused };
private:
  const std::vector<std::uint8_t> bytes_;
  const initializer_kind kind_;
  std::mutex mutex_;
  std::weak_ptr<connection> session_;
  std::uint64_t id_ = 0;
  observation state_ = observation::unbound;
  initializer_delivery(std::vector<std::uint8_t> bytes, initializer_kind kind)
      : bytes_(std::move(bytes)), kind_(kind) {}
  static std::shared_ptr<initializer_delivery> create(
      const std::vector<std::uint8_t>& bytes, initializer_kind kind) {
    return std::shared_ptr<initializer_delivery>(new initializer_delivery(bytes, kind));
  }
  void refuse() {
    std::shared_ptr<connection> session;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      state_ = observation::refused;
      session = session_.lock();
    }
    // Never hold the intent mutex while entering native owner retirement. That
    // path can synchronously cancel pending manager rows which contain us.
    if (session) session->owner_->retire();
  }
  bool bind(const std::shared_ptr<connection>& session, std::uint64_t id,
      const std::vector<std::uint8_t>& sent) {
    const bool current = session && session->current();
    bool bound = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (state_ == observation::unbound && current && id != 0 &&
          (kind_ == initializer_kind::keyboard || kind_ == initializer_kind::pointing) &&
          !bytes_.empty() && bytes_ == sent) {
        session_ = session;
        id_ = id;
        state_ = observation::pending;
        bound = true;
      } else state_ = observation::refused;
    }
    if (!bound && session) session->owner_->retire();
    return bound;
  }
  void complete(std::uint64_t id, const asio::error_code& error,
      const std::shared_ptr<std::vector<std::uint8_t>>& reply) {
    bool canonical = !error && reply && reply->size() == 10;
    if (canonical) {
      for (std::size_t at = 0; at < 10; at += 2) {
        if ((*reply)[at] != at / 2 + 1 || (*reply)[at + 1] > 1) {
          canonical = false; break;
        }
      }
    }
    std::shared_ptr<connection> session;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      session = session_.lock();
      canonical = canonical && state_ == observation::pending && id == id_;
    }
    const bool current = session && session->current();
    if (!canonical || !current) { refuse(); return; }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (state_ != observation::pending || id != id_) canonical = false;
      else state_ = observation::delivered;
    }
    if (!canonical) refuse();
  }
public:
  observation state() {
    std::shared_ptr<connection> session;
    observation result;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      result = state_;
      session = session_.lock();
    }
    if (result == observation::unbound || result == observation::refused) return result;
    if (!session || !session->current()) { refuse(); return observation::refused; }
    std::lock_guard<std::mutex> lock(mutex_);
    return state_;
  }
};

inline std::shared_ptr<void> broker_owner::retain_work(queue kind) {
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  if (!sessions_.empty()) return sessions_.back()->retain_task(
      kind == queue::native ? connection::task_kind::native : connection::task_kind::dispatch);
  return retain_construction();
}
inline std::shared_ptr<connection> broker_owner::active() {
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  if (sessions_.size() != 1 || !sessions_.front()->current()) return nullptr;
  return sessions_.front();
}

inline void broker_owner::release_construction() {
  {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (construction_debt_ == 0) failed_ = true;
    else --construction_debt_;
  }
  settle();
}
inline void broker_owner::retire() {
  std::vector<std::shared_ptr<connection>> sessions;
  {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    revoked_ = true;
    sessions = sessions_;
  }
  for (auto& session : sessions) session->revoke();
  settle();
}
inline void broker_owner::settle() {
  std::shared_ptr<broker_owner> release;
  std::vector<std::shared_ptr<connection>> completed;
  {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    for (auto i = sessions_.begin(); i != sessions_.end();) {
      if ((*i)->completed()) { completed.push_back(*i); i = sessions_.erase(i); }
      else ++i;
    }
    if (!revoked_ || failed_ || retired_ || construction_debt_ != 0 || !sessions_.empty()) return;
    if (!reference_.retire()) { failed_ = true; return; }
    retired_ = true;
    release = std::move(retained_);
  }
  // Session closures and the self-retention are released outside the owner lock.
}
} // namespace ergoptiplus::remap::vhd
