// Native fixed-user configuration custody. File capture is not engine admission.
#pragma once
#include "InstalledRuntimePublisher.hpp"
#include <pwd.h>
#include <stdlib.h>
#include <mutex>
#include <limits>

namespace ergoptiplus::installed_capture { class core_peer_owner; }
namespace ergoptiplus::remap::auth { class console_control_owner; }
namespace ergoptiplus::installed_configuration {

class owner final : public std::enable_shared_from_this<owner> {
public:
  owner(const owner&) = delete;
  owner& operator=(const owner&) = delete;

  // The normal module derives its actual current process and installed publisher.
  static std::shared_ptr<owner> acquire() noexcept {
    try {
      const uid_t uid = getuid();
      if (uid == 0 || geteuid() != uid) return nullptr;
      return acquire_native(uid, installed_publisher::role::hammerspoon);
    } catch (...) { return nullptr; }
  }

  // The same policy serves the authenticated normal headless launcher.
  static std::shared_ptr<owner> acquire_launcher() noexcept {
    try {
      const uid_t uid = getuid();
      if (uid == 0 || geteuid() != uid) return nullptr;
      return acquire_native(uid, installed_publisher::role::launcher);
    } catch (...) { return nullptr; }
  }
  const char* generation() const noexcept { return generation_.data(); }

  const std::string& root() const noexcept { return root_; }
  uid_t uid() const noexcept { return uid_; }
  pid_t creating_pid() const noexcept { return pid_; }
  const std::string& destination() const noexcept { return destination_; }

  // Native namespace custody remains separate from a particular file generation.
  bool namespace_current() const noexcept {
    try {
      std::lock_guard<std::recursive_mutex> held(mutex_);
      return namespace_current_checked();
    } catch (...) { return false; }
  }

  // Only the original retired-cohort caller may use this data-restoration port.
  // It preserves the signed creating principal and private namespace without
  // treating a newly present operation journal as new image admission.
  bool rollback_namespace_current() const noexcept {
    try {
      std::lock_guard<std::recursive_mutex> held(mutex_);
      if (release_attempted_ || close_refused_ || nodes_.empty() || !rollback_principal_current()) return false;
      for (std::size_t i = 0; i < nodes_.size(); ++i) {
        struct stat held_node{}, named{};
        const auto& node = nodes_[i];
        if (node.fd < 0 || fstat(node.fd, &held_node) != 0 || !same_directory(held_node, node.identity)
            || !directory_shape(held_node, node.private_directory) || !safe_acl(node.fd)) return false;
        if (i == 0) { if (lstat("/", &named) != 0) return false; }
        else if (fstatat(nodes_[i - 1].fd, node.name.c_str(), &named, AT_SYMLINK_NOFOLLOW) != 0) return false;
        if (!same_directory(named, node.identity)) return false;
      }
      return rollback_principal_current();
    } catch (...) { return false; }
  }

  bool capture_publication() noexcept {
    try {
      std::lock_guard<std::recursive_mutex> held(mutex_);
      if (file_ >= 0 || file_close_attempted_ || !namespace_current_checked()) return false;
      struct stat named{}, held_file{}, after{};
      if (fstatat(nodes_.back().fd, "karabiner.json", &named, AT_SYMLINK_NOFOLLOW) != 0 || !file_shape(named)) return false;
      // Storage allocation precedes acquisition of the new file descriptor.
      std::string contents(static_cast<std::size_t>(named.st_size), '\0');
      file_ = openat(nodes_.back().fd, "karabiner.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
      if (file_ < 0) return false;
      if (fstat(file_, &held_file) != 0 || !installed_publisher::detail::same(named, held_file)
          || !safe_acl(file_) || !read_whole(file_, contents)
          || fstat(file_, &after) != 0 || !installed_publisher::detail::same(held_file, after)
          || !namespace_current_checked()) return false;
      file_identity_ = after;
      bytes_ = std::move(contents);
      if (!CC_SHA256(bytes_.data(), static_cast<CC_LONG>(bytes_.size()), digest_.data())) return false;
      captured_ = true;
      return file_current_checked();
    } catch (...) { return false; }
  }

  bool file_current() const noexcept {
    try {
      std::lock_guard<std::recursive_mutex> held(mutex_);
      return file_current_checked();
    } catch (...) { return false; }
  }

  // These references are native-only; no caller document can mint a publication.
  const std::string& captured_bytes() const noexcept { return bytes_; }
  const std::array<unsigned char, CC_SHA256_DIGEST_LENGTH>& digest() const noexcept { return digest_; }
  const struct stat& file_identity() const noexcept { return file_identity_; }

  // Callers must first settle the original engine/cohort; this is close custody only.
  bool release() noexcept {
    std::shared_ptr<owner> keep;
    try {
      std::lock_guard<std::recursive_mutex> held(mutex_);
      keep = custody_;
      if (!release_attempted_) {
        release_attempted_ = true;
        if (file_ >= 0) {
          const int fd = file_; file_ = -1; file_close_attempted_ = true;
          if (close(fd) != 0) close_refused_ = true;
        }
        for (auto it = nodes_.rbegin(); it != nodes_.rend(); ++it) {
          if (it->fd >= 0) { const int fd = it->fd; it->fd = -1; if (close(fd) != 0) close_refused_ = true; }
        }
        if (publisher_ && !publisher_->release()) close_refused_ = true;
      }
      if (!close_refused_) custody_.reset();
      return !close_refused_;
    } catch (...) { return false; }
  }
  bool retired() const noexcept {
    try { std::lock_guard<std::recursive_mutex> held(mutex_); return release_attempted_ && !close_refused_; }
    catch (...) { return false; }
  }
  ~owner() { release(); }

private:
  friend class ergoptiplus::installed_capture::core_peer_owner;
  friend class ergoptiplus::remap::auth::console_control_owner;
  struct node { int fd = -1; std::string name; struct stat identity{}; bool private_directory = false; };
  owner() {
    unsigned char nonce[16];
    arc4random_buf(nonce, sizeof(nonce));
    constexpr char hexadecimal[] = "0123456789abcdef";
    for (std::size_t i = 0; i < sizeof(nonce); ++i) {
      generation_[2 * i] = hexadecimal[nonce[i] >> 4];
      generation_[2 * i + 1] = hexadecimal[nonce[i] & 15];
    }
    generation_[32] = '\0';
  }

  // Only the genuine native Core peer factory can lend its freshly observed UID.
  static std::shared_ptr<owner> acquire_peer(uid_t actual_peer_uid) noexcept {
    try {
      if (getuid() != 0 || geteuid() != 0 || actual_peer_uid == 0) return nullptr;
      return acquire_native(actual_peer_uid, installed_publisher::role::core);
    } catch (...) { return nullptr; }
  }

  static std::shared_ptr<owner> acquire_native(uid_t uid, installed_publisher::role role) {
    auto result = std::shared_ptr<owner>(new owner);
    // Retain every acquired resource even if a later allocation or close refuses.
    result->custody_ = result;
    struct refusal_cleanup {
      owner* value; bool delivered = false;
      ~refusal_cleanup() { if (!delivered) value->release(); }
    } cleanup{result.get()};
    result->uid_ = uid; result->pid_ = getpid(); result->role_ = role;
    result->publisher_ = installed_publisher::owner::acquire();
    if (!result->publisher_ || !result->principal_current()) { result->release(); return nullptr; }
    result->principal_uid_ = getuid(); result->principal_euid_ = geteuid();
    result->original_leaf_ = result->publisher_->observed_leaf();
    if (result->original_leaf_.empty() || !result->principal_current()) { result->release(); return nullptr; }
    long bound = sysconf(_SC_GETPW_R_SIZE_MAX);
    if (bound <= 0) { result->release(); return nullptr; }
    std::vector<char> buffer(static_cast<std::size_t>(bound));
    struct passwd entry{}, *found = nullptr;
    if (getpwuid_r(uid, &entry, buffer.data(), buffer.size(), &found) != 0 || found != &entry
        || entry.pw_uid != uid || !entry.pw_dir) { result->release(); return nullptr; }
    const std::string home(entry.pw_dir);
    if (home.size() < 2 || home[0] != '/' || home.back() == '/' || home.find("//") != std::string::npos) {
      result->release(); return nullptr;
    }
    std::vector<std::string> components;
    for (std::size_t first = 1; first < home.size();) {
      auto last = home.find('/', first); if (last == std::string::npos) last = home.size();
      std::string name = home.substr(first, last - first);
      if (name.empty() || name == "." || name == "..") { result->release(); return nullptr; }
      components.push_back(std::move(name)); first = last + 1;
    }
    components.insert(components.end(), {"Library", "Application Support", "ErgoptiPlus", "karabiner"});
    result->root_ = home + "/Library/Application Support/ErgoptiPlus";
    result->destination_ = result->root_ + "/karabiner/karabiner.json";
    result->nodes_.resize(components.size() + 1);
    for (std::size_t i = 0; i < components.size(); ++i) {
      result->nodes_[i + 1].name = std::move(components[i]);
      result->nodes_[i + 1].private_directory = i + 2 >= result->nodes_.size() - 1;
    }
    if (!result->anchor() || !result->namespace_current()) { result->release(); return nullptr; }
    cleanup.delivered = true;
    return result;
  }

  bool principal_current() const {
    if (!publisher_ || !publisher_->permits_installed_images()) return false;
    installed_publisher::detail::cf<SecCodeRef> self;
    installed_publisher::detail::cf<SecStaticCodeRef> code;
    return SecCodeCopySelf(kSecCSDefaultFlags, &self.value) == errSecSuccess && self.value
        && SecCodeCheckValidity(self.value, kSecCSStrictValidate, nullptr) == errSecSuccess
        && SecCodeCopyStaticCode(self.value, kSecCSDefaultFlags, &code.value) == errSecSuccess
        && code.value && publisher_->matches(code.value, role_) && publisher_->permits_installed_images();
  }

  bool rollback_principal_current() const {
    if (getpid() != pid_ || getuid() != principal_uid_ || geteuid() != principal_euid_
        || original_leaf_.empty()) return false;
    installed_publisher::detail::cf<SecCodeRef> self;
    installed_publisher::detail::cf<SecStaticCodeRef> code;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &self.value) != errSecSuccess || !self.value
        || SecCodeCheckValidity(self.value, kSecCSStrictValidate, nullptr) != errSecSuccess
        || SecCodeCopyStaticCode(self.value, kSecCSDefaultFlags, &code.value) != errSecSuccess || !code.value) return false;
    const auto observed = installed_publisher::detail::leaf(code.value, role_);
    return observed && *observed == original_leaf_ && getpid() == pid_
        && getuid() == principal_uid_ && geteuid() == principal_euid_;
  }

  static bool safe_acl(int fd) {
    acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
    if (!acl) return false;
    bool safe = acl_valid(acl) == 0;
    acl_entry_t entry;
    int kind = ACL_FIRST_ENTRY;
    while (safe) {
      errno = 0; const int got = acl_get_entry(acl, kind, &entry); kind = ACL_NEXT_ENTRY;
      if (got == -1) { safe = errno == EINVAL; break; }
      if (got != 0) { safe = false; break; }
      acl_tag_t tag; acl_permset_t permissions;
      if (acl_get_tag_type(entry, &tag) != 0 || acl_get_permset(entry, &permissions) != 0) { safe = false; break; }
      if (tag != ACL_EXTENDED_ALLOW) continue;
      for (auto permission : {ACL_WRITE_DATA, ACL_ADD_FILE, ACL_APPEND_DATA, ACL_ADD_SUBDIRECTORY,
          ACL_DELETE, ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES,
          ACL_WRITE_SECURITY, ACL_CHANGE_OWNER}) {
        const int allowed = acl_get_perm_np(permissions, permission);
        if (allowed != 0) { safe = false; break; }
      }
    }
    return acl_free(acl) == 0 && safe;
  }

  bool directory_shape(const struct stat& value, bool private_directory) const {
    return S_ISDIR(value.st_mode) && (value.st_uid == 0 || value.st_uid == uid_)
        && (value.st_mode & 0022) == 0
        && (!private_directory || (value.st_uid == uid_ && (value.st_mode & 07777) == 0700));
  }
  bool file_shape(const struct stat& value) const {
    return S_ISREG(value.st_mode) && value.st_uid == uid_ && value.st_nlink == 1
        && (value.st_mode & 0022) == 0 && value.st_size > 0
        && static_cast<std::uintmax_t>(value.st_size) <= std::numeric_limits<CC_LONG>::max();
  }
  static bool same_directory(const struct stat& left, const struct stat& right) {
    return left.st_dev == right.st_dev && left.st_ino == right.st_ino && left.st_mode == right.st_mode
        && left.st_uid == right.st_uid && left.st_gid == right.st_gid;
  }
  static bool read_whole(int fd, std::string& output) {
    std::size_t offset = 0;
    while (offset < output.size()) {
      const auto remaining = std::min(output.size() - offset, static_cast<std::size_t>(std::numeric_limits<ssize_t>::max()));
      const ssize_t count = pread(fd, output.data() + offset, remaining, static_cast<off_t>(offset));
      if (count < 0 && errno == EINTR) continue;
      if (count <= 0) return false;
      offset += static_cast<std::size_t>(count);
    }
    char tail;
    return pread(fd, &tail, 1, static_cast<off_t>(offset)) == 0;
  }
  bool anchor() {
    nodes_[0].fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    for (std::size_t i = 0; i < nodes_.size(); ++i) {
      auto& node = nodes_[i];
      if (i != 0) {
        struct stat named{};
        if (fstatat(nodes_[i - 1].fd, node.name.c_str(), &named, AT_SYMLINK_NOFOLLOW) != 0) {
          if (errno != ENOENT || !node.private_directory || uid_ != getuid()
              || mkdirat(nodes_[i - 1].fd, node.name.c_str(), 0700) != 0) return false;
        }
        node.fd = openat(nodes_[i - 1].fd, node.name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      }
      if (node.fd < 0 || fstat(node.fd, &node.identity) != 0
          || !directory_shape(node.identity, node.private_directory) || !safe_acl(node.fd)) return false;
    }
    return true;
  }
  bool namespace_current_checked() const {
    if (release_attempted_ || close_refused_ || nodes_.empty() || !principal_current()) return false;
    for (std::size_t i = 0; i < nodes_.size(); ++i) {
      struct stat held{}, named{};
      const auto& node = nodes_[i];
      if (node.fd < 0 || fstat(node.fd, &held) != 0 || !same_directory(held, node.identity)
          || !directory_shape(held, node.private_directory) || !safe_acl(node.fd)) return false;
      if (i == 0) { if (lstat("/", &named) != 0) return false; }
      else if (fstatat(nodes_[i - 1].fd, node.name.c_str(), &named, AT_SYMLINK_NOFOLLOW) != 0) return false;
      if (!same_directory(named, node.identity)) return false;
    }
    return principal_current();
  }
  bool file_current_checked() const {
    if (!captured_ || file_ < 0 || !namespace_current_checked()) return false;
    struct stat held{}, named{}, after{};
    if (fstat(file_, &held) != 0 || !installed_publisher::detail::same(held, file_identity_)
        || fstatat(nodes_.back().fd, "karabiner.json", &named, AT_SYMLINK_NOFOLLOW) != 0
        || !installed_publisher::detail::same(held, named) || !safe_acl(file_)) return false;
    std::string observed(bytes_.size(), '\0');
    return read_whole(file_, observed) && observed == bytes_ && fstat(file_, &after) == 0
        && installed_publisher::detail::same(after, held) && namespace_current_checked();
  }

  mutable std::recursive_mutex mutex_;
  std::shared_ptr<owner> custody_;
  std::unique_ptr<installed_publisher::owner> publisher_;
  std::vector<node> nodes_;
  std::vector<std::uint8_t> original_leaf_;
  uid_t principal_uid_ = 0, principal_euid_ = 0;
  std::string root_, destination_, bytes_;
  uid_t uid_ = 0; pid_t pid_ = 0;
  installed_publisher::role role_ = installed_publisher::role::hammerspoon;
  int file_ = -1;
  struct stat file_identity_{};
  std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> digest_{};
  std::array<char, 33> generation_{};
  bool captured_ = false, file_close_attempted_ = false, release_attempted_ = false, close_refused_ = false;
};
} // namespace ergoptiplus::installed_configuration
