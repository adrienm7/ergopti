// Shared native installed-publisher observation. No observation is capture authority.
#pragma once
#include <CommonCrypto/CommonDigest.h>
#include <Security/Security.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/acl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <memory>
#include <limits>
#include <optional>
#include <string>
#include <vector>

namespace ergoptiplus::installed_maintenance::admission_detail { class retained_images; }

namespace ergoptiplus::installed_publisher {
enum class role { launcher, hammerspoon, module, core, console, cli, installer };
inline const char* identifier(role value) {
  switch (value) {
    case role::launcher: return "com.ergoptiplus.app";
    case role::hammerspoon: return "com.ergoptiplus.app.hammerspoon";
    case role::module: return "com.ergoptiplus.app.installed-physical-source";
    case role::core: return "com.ergoptiplus.remap.core";
    case role::console: return "com.ergoptiplus.remap.console";
    case role::cli: return "com.ergoptiplus.remap.cli";
    case role::installer: return "com.ergoptiplus.app.runtime-installer";
  }
  return nullptr;
}
inline std::optional<role> closed_role(const char* name) {
  if (!name) return std::nullopt;
  for (auto value : {role::launcher, role::hammerspoon, role::module, role::core, role::console, role::cli, role::installer}) {
    if (std::strcmp(name, identifier(value)) == 0) return value;
  }
  return std::nullopt;
}
namespace detail {
template<class T> struct cf final {
  T value = nullptr;
  cf() = default;
  cf(const cf&) = delete;
  cf& operator=(const cf&) = delete;
  ~cf() { if (value) CFRelease(value); }
};
inline bool same(const struct stat& a, const struct stat& b) {
  return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
      a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_size == b.st_size && a.st_nlink == b.st_nlink &&
      a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
      a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
}
inline bool empty_acl(int fd) {
  acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
  if (!acl) return false;
  acl_entry_t entry;
  const bool valid = acl_valid(acl) == 0;
  errno = 0;
  const int result = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry), failure = errno;
  const bool released = acl_free(acl) == 0;
  return valid && result == -1 && failure == EINVAL && released;
}
struct acquired_fd final {
  int value;
  bool& close_refused;
  int* refused_descriptor;
  acquired_fd(int value, bool& close_refused, int* refused_descriptor = nullptr) noexcept
      : value(value), close_refused(close_refused), refused_descriptor(refused_descriptor) {}
  acquired_fd(const acquired_fd&) = delete;
  ~acquired_fd() {
    if (value >= 0 && close(value) != 0) {
      close_refused = true;
      if (refused_descriptor && *refused_descriptor < 0) *refused_descriptor = value;
    }
  }
  int release() noexcept { const int result = value; value = -1; return result; }
};
struct acquired_directory final {
  DIR* value;
  bool& close_refused;
  int* refused_descriptor;
  acquired_directory(DIR* value, bool& close_refused, int* refused_descriptor = nullptr) noexcept
      : value(value), close_refused(close_refused), refused_descriptor(refused_descriptor) {}
  acquired_directory(const acquired_directory&) = delete;
  ~acquired_directory() { finish(); }
  bool finish() noexcept {
    if (value) {
      DIR* held = value; const int original = dirfd(held); value = nullptr;
      if (closedir(held) != 0) {
        close_refused = true;
        if (refused_descriptor && *refused_descriptor < 0) *refused_descriptor = original;
      }
    }
    return !close_refused;
  }
};
inline std::optional<std::vector<std::string>> names(int fd, bool& close_refused, int* refused_descriptor = nullptr) {
  const int copy = fcntl(fd, F_DUPFD_CLOEXEC, 0);
  if (copy < 0) return std::nullopt;
  acquired_fd held_copy(copy, close_refused, refused_descriptor);
  DIR* directory = fdopendir(copy);
  if (!directory) return std::nullopt;
  held_copy.release();
  acquired_directory held_directory(directory, close_refused, refused_descriptor);
  rewinddir(directory);
  std::vector<std::string> result;
  errno = 0;
  while (const auto entry = readdir(directory)) {
    std::string name(entry->d_name);
    if (name != "." && name != "..") result.push_back(std::move(name));
    errno = 0;
  }
  const int failure = errno;
  if (!held_directory.finish()) return std::nullopt;
  if (failure != 0) return std::nullopt;
  std::sort(result.begin(), result.end());
  if (std::adjacent_find(result.begin(), result.end()) != result.end()) return std::nullopt;
  return result;
}
inline std::optional<std::vector<std::uint8_t>> leaf_checked(SecStaticCodeRef code, role value) {
  cf<CFStringRef> expression;
  const std::string text = std::string("identifier \"") + identifier(value) + "\"";
  expression.value = CFStringCreateWithCString(nullptr, text.c_str(), kCFStringEncodingUTF8);
  cf<SecRequirementRef> requirement;
  const auto strict = static_cast<SecCSFlags>(kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode);
  if (!expression.value || SecRequirementCreateWithString(expression.value, kSecCSDefaultFlags, &requirement.value) != errSecSuccess ||
      SecStaticCodeCheckValidity(code, strict, requirement.value) != errSecSuccess) return std::nullopt;
  cf<CFDictionaryRef> information;
  if (SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information.value) != errSecSuccess || !information.value) return std::nullopt;
  cf<CFStringRef> exact_role;
  exact_role.value = CFStringCreateWithCString(nullptr, identifier(value), kCFStringEncodingUTF8);
  const auto actual_role = CFDictionaryGetValue(information.value, kSecCodeInfoIdentifier);
  if (!exact_role.value || !actual_role || CFGetTypeID(actual_role) != CFStringGetTypeID() ||
      CFStringCompare(static_cast<CFStringRef>(actual_role), exact_role.value, 0) != kCFCompareEqualTo) return std::nullopt;
  const auto cms = CFDictionaryGetValue(information.value, kSecCodeInfoCMS);
  const auto flags = CFDictionaryGetValue(information.value, kSecCodeInfoFlags);
  const auto certs = CFDictionaryGetValue(information.value, kSecCodeInfoCertificates);
  std::int64_t signature_flags = -1;
  if (!cms || CFGetTypeID(cms) != CFDataGetTypeID() || CFDataGetLength(static_cast<CFDataRef>(cms)) <= 0 ||
      !flags || CFGetTypeID(flags) != CFNumberGetTypeID() ||
      !CFNumberGetValue(static_cast<CFNumberRef>(flags), kCFNumberSInt64Type, &signature_flags) || signature_flags < 0 || signature_flags > std::numeric_limits<std::uint32_t>::max() ||
      (signature_flags & kSecCodeSignatureAdhoc) != 0 ||
      !certs || CFGetTypeID(certs) != CFArrayGetTypeID() || CFArrayGetCount(static_cast<CFArrayRef>(certs)) < 1) return std::nullopt;
  const auto cert = CFArrayGetValueAtIndex(static_cast<CFArrayRef>(certs), 0);
  if (!cert || CFGetTypeID(cert) != SecCertificateGetTypeID()) return std::nullopt;
  cf<CFDataRef> data;
  data.value = SecCertificateCopyData(static_cast<SecCertificateRef>(const_cast<void*>(cert)));
  if (!data.value || CFDataGetLength(data.value) <= 0 || CFDataGetLength(data.value) > 1024 * 1024) return std::nullopt;
  const auto bytes = CFDataGetBytePtr(data.value);
  const auto length = CFDataGetLength(data.value);
  std::array<unsigned char, CC_SHA1_DIGEST_LENGTH> digest{};
  if (!bytes || !CC_SHA1(bytes, static_cast<CC_LONG>(length), digest.data())) return std::nullopt;
  constexpr char hex[] = "0123456789abcdef";
  std::string pinned = text + " and certificate leaf = H\"";
  for (auto byte : digest) { pinned += hex[byte >> 4]; pinned += hex[byte & 15]; }
  pinned += "\"";
  cf<CFStringRef> pinned_text;
  cf<SecRequirementRef> same_leaf;
  pinned_text.value = CFStringCreateWithCString(nullptr, pinned.c_str(), kCFStringEncodingUTF8);
  if (!pinned_text.value || SecRequirementCreateWithString(pinned_text.value, kSecCSDefaultFlags, &same_leaf.value) != errSecSuccess ||
      SecStaticCodeCheckValidity(code, strict, same_leaf.value) != errSecSuccess) return std::nullopt;
  return std::vector<std::uint8_t>(bytes, bytes + length);
}
inline std::optional<std::vector<std::uint8_t>> leaf(SecStaticCodeRef code, role value) noexcept {
  try { return leaf_checked(code, value); } catch (...) { return std::nullopt; }
}
inline std::optional<std::vector<std::uint8_t>> path_leaf(const char* path, role value) {
  cf<CFURLRef> url;
  cf<SecStaticCodeRef> code;
  url.value = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8*>(path), std::strlen(path), false);
  if (!url.value || SecStaticCodeCreateWithPath(url.value, kSecCSDefaultFlags, &code.value) != errSecSuccess || !code.value) return std::nullopt;
  return leaf(code.value, value);
}
} // namespace detail

// A retained native tree and cryptographic observation; not READY, process or capture ownership.
class owner final {
  friend class ergoptiplus::installed_maintenance::admission_detail::retained_images;
public:
  owner(const owner&) = delete;
  owner& operator=(const owner&) = delete;
  static std::unique_ptr<owner> acquire() noexcept {
    try { return acquire_checked(); } catch (...) { return nullptr; }
  }
private:
  static std::unique_ptr<owner> failed_acquisition(std::unique_ptr<owner> result) noexcept {
    if (!result) return nullptr;
    bool acknowledged=false;
    try { acknowledged=result->release(); } catch (...) { result->close_refused_=true; }
    if (!acknowledged) {
      // No allocation follows native acquisition. The exact failed owner keeps
      // its immutable FD identities/refused-close metadata and owns itself.
      // Ambiguous close is sticky; no successor or destructor can retry it.
      owner* original=result.get();
      original->failed_custody_.reset(result.release());
    }
    return nullptr;
  }
  static std::unique_ptr<owner> acquire_checked() {
    auto result = std::unique_ptr<owner>(new owner);
    try {
      if (!result->anchor()) return failed_acquisition(std::move(result));
      auto observed = detail::path_leaf(core, role::core);
      if (!observed) return failed_acquisition(std::move(result));
      result->leaf_ = std::move(*observed);
      if (!result->current()) return failed_acquisition(std::move(result));
      return result;
    } catch (...) { return failed_acquisition(std::move(result)); }
  }
public:
  const std::vector<std::uint8_t>& observed_leaf() const { return leaf_; }
  bool matches(SecStaticCodeRef code, role value) const {
    if (!current()) return false;
    const auto actual = detail::leaf(code, value);
    return actual && *actual == leaf_ && current();
  }
  bool current() const noexcept {
    try { return current_checked(); } catch (...) { return false; }
  }
  // Cleanup observation of this original held publisher; never image admission.
  // Operation journals/stage directories may change protected ancestor entries.
  bool custody_current() const noexcept {
    try {
      if (released_ || close_refused_ || nodes_.size() < 5 || !custody_tree_current()) return false;
      const auto actual_core = detail::path_leaf(core, role::core);
      const auto actual_console = detail::path_leaf(console, role::console);
      const auto actual_cli = detail::path_leaf(cli, role::cli);
      return actual_core && actual_console && actual_cli && *actual_core == leaf_
          && *actual_console == leaf_ && *actual_cli == leaf_ && custody_tree_current();
    } catch (...) { return false; }
  }
  // Installed-image admission is distinct from a generic signature/tree observation.
  bool permits_installed_images() const noexcept {
    try {
      if (!current() || nodes_.size() < 5 || nodes_[3].name != "ErgoptiPlus") return false;
      const int parent = nodes_[3].fd;
      for (const char* name : {".runtime-install-journal", ".runtime-service-journal",
          ".runtime-bootstrap-journal", ".runtime-maintenance-journal"}) {
        struct stat observed{}; errno = 0;
        if (fstatat(parent, name, &observed, AT_SYMLINK_NOFOLLOW) != -1 || errno != ENOENT) return false;
      }
      return current();
    } catch (...) { return false; }
  }
private:
  bool current_checked() const {
    if (released_ || close_refused_ || nodes_.empty()) return false;
    if (!tree_current()) return false;
    const auto actual_core = detail::path_leaf(core, role::core);
    const auto actual_console = detail::path_leaf(console, role::console);
    const auto actual_cli = detail::path_leaf(cli, role::cli);
    return actual_core && actual_console && actual_cli && *actual_core == leaf_ && *actual_console == leaf_ && *actual_cli == leaf_ && tree_current();
  }
public:
  bool release() {
    if (!released_) {
      released_ = true;
      for (auto it = nodes_.rbegin(); it != nodes_.rend(); ++it) {
        if (it->fd >= 0 && close(it->fd) != 0) {
          it->refused_descriptor=it->fd;
          close_refused_ = true;
        }
        it->fd = -1;
      }
    }
    return !close_refused_;
  }
  ~owner() { release(); }
private:
  struct node {
    int fd;
    std::size_t parent;
    std::string name;
    struct stat identity;
    bool census = false;
    std::vector<std::string> children;
    int refused_descriptor=-1;
  };
  owner() = default;
  static constexpr const char* core = "/Library/Application Support/ErgoptiPlus/Runtime/ErgoptiPlus-Remap-Core.app";
  static constexpr const char* console = "/Library/Application Support/ErgoptiPlus/Runtime/ErgoptiPlus-Remap-Console.app";
  static constexpr const char* cli = "/Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli";
  bool tree_current() const {
    for (std::size_t i = 0; i < nodes_.size(); ++i) {
      const auto& node = nodes_[i];
      struct stat held{}, named{};
      if (fstat(node.fd, &held) != 0 || !detail::same(held, node.identity) || !detail::empty_acl(node.fd)) return false;
      const int observed = i == 0 ? lstat("/", &named) : fstatat(nodes_[node.parent].fd, node.name.c_str(), &named, AT_SYMLINK_NOFOLLOW);
      if (observed != 0 || !detail::same(named, node.identity)) return false;
      if (node.census) {
        const auto actual = detail::names(node.fd, close_refused_, &unregistered_refused_descriptor_);
        if (!actual || *actual != node.children) return false;
      }
    }
    return !close_refused_;
  }
  bool custody_tree_current() const {
    const auto same_ancestor = [](const struct stat& a, const struct stat& b) {
      return S_ISDIR(a.st_mode) && S_ISDIR(b.st_mode) && a.st_dev == b.st_dev
          && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid && a.st_gid == b.st_gid;
    };
    for (std::size_t i = 0; i < nodes_.size(); ++i) {
      const auto& node = nodes_[i]; struct stat held{}, named{};
      if (node.fd < 0 || fstat(node.fd, &held) != 0 || !detail::empty_acl(node.fd)) return false;
      const int observed = i == 0 ? lstat("/", &named)
          : fstatat(nodes_[node.parent].fd, node.name.c_str(), &named, AT_SYMLINK_NOFOLLOW);
      if (observed != 0) return false;
      if (i < 4) {
        if (!same_ancestor(held, node.identity) || !same_ancestor(named, node.identity)) return false;
      } else if (!detail::same(held, node.identity) || !detail::same(named, node.identity)) return false;
      if (node.census) {
        const auto actual = detail::names(node.fd, close_refused_, &unregistered_refused_descriptor_);
        if (!actual || *actual != node.children) return false;
      }
    }
    return !close_refused_;
  }
  bool enroll(int fd, std::size_t parent, const char* name, bool directory) {
    struct stat value{};
    if (fd < 0) return false;
    detail::acquired_fd acquired(fd, close_refused_, &unregistered_refused_descriptor_);
    const bool accepted = fstat(fd, &value) == 0 && value.st_uid == 0 && (value.st_mode & 0022) == 0 &&
        (directory ? S_ISDIR(value.st_mode) : (S_ISREG(value.st_mode) && value.st_nlink == 1)) && detail::empty_acl(fd);
    if (!accepted) return false;
    nodes_.push_back({fd, parent, std::string(name), value, false, {}});
    acquired.release();
    return true;
  }
  bool walk(std::size_t index) {
    const auto actual = detail::names(nodes_[index].fd, close_refused_, &unregistered_refused_descriptor_);
    if (!actual) return false;
    nodes_[index].census = true;
    nodes_[index].children = *actual;
    for (const auto& name : *actual) {
      struct stat named{};
      if (fstatat(nodes_[index].fd, name.c_str(), &named, AT_SYMLINK_NOFOLLOW) != 0 ||
          (!S_ISDIR(named.st_mode) && !S_ISREG(named.st_mode))) return false;
      const bool directory = S_ISDIR(named.st_mode);
      const int fd = openat(nodes_[index].fd, name.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0));
      if (!enroll(fd, index, name.c_str(), directory) || !detail::same(nodes_.back().identity, named)) return false;
      const auto child = nodes_.size() - 1;
      if (directory && !walk(child)) return false;
    }
    return true;
  }
  bool anchor() {
    if (!enroll(open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), 0, "", true)) return false;
    std::size_t parent = 0;
    for (const char* name : {"Library", "Application Support", "ErgoptiPlus", "Runtime"}) {
      if (!enroll(openat(nodes_[parent].fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), parent, name, true)) return false;
      parent = nodes_.size() - 1;
    }
    return walk(parent);
  }
  std::vector<node> nodes_;
  std::unique_ptr<owner> failed_custody_;
  std::vector<std::uint8_t> leaf_;
  bool released_ = false;
  mutable bool close_refused_ = false;
  mutable int unregistered_refused_descriptor_ = -1;
};
} // namespace ergoptiplus::installed_publisher
