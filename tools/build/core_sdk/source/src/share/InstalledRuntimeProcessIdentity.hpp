// Shared native process/image/CF/lock identity; no owner factory or Core SDK dependency.
#pragma once
#include "OwnedRuntimeLifecycleContract.h"
#include "InstalledRuntimePublisher.hpp"
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

namespace ergoptiplus::installed_capture {
namespace detail {

template <class T> class cf_owner final {
public:
  cf_owner() = default;
  cf_owner(const cf_owner&) = delete;
  cf_owner& operator=(const cf_owner&) = delete;
  ~cf_owner() { if (value_) CFRelease(value_); }
  T get() const noexcept { return value_; }
  T* out() noexcept { return &value_; }
private:
  T value_ = nullptr;
};

inline bool empty_acl(int descriptor) {
  acl_t acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED);
  if (!acl) return false;
  acl_entry_t entry;
  const bool valid = acl_valid(acl) == 0;
  errno = 0;
  const auto result = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry);
  const int failure = errno;
  const bool released = acl_free(acl) == 0;
  return valid && result == -1 && failure == EINVAL && released;
}

inline bool same_file(const struct stat& left, const struct stat& right) {
  return left.st_dev == right.st_dev && left.st_ino == right.st_ino && left.st_mode == right.st_mode &&
      left.st_uid == right.st_uid && left.st_gid == right.st_gid && left.st_size == right.st_size &&
      left.st_nlink == right.st_nlink && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec &&
      left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec &&
      left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec;
}

inline bool protected_directory(int descriptor) {
  struct stat value{};
  return fstat(descriptor, &value) == 0 && S_ISDIR(value.st_mode) && value.st_uid == 0 &&
      (value.st_mode & 0022) == 0 && empty_acl(descriptor);
}

inline bool fixed_lock(struct stat& identity) {
  const int inherited = ERGOPTI_OWNED_RUNTIME_LIFECYCLE_CHILD_DESCRIPTOR;
  if (fstat(inherited, &identity) != 0 || !S_ISREG(identity.st_mode) || identity.st_uid != 0 ||
      (identity.st_mode & 07777) != 0644 || identity.st_nlink != 1 || identity.st_size != 0 || !empty_acl(inherited)) return false;
  int parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (parent < 0) return false;
  bool accepted = protected_directory(parent);
  for (const char* component : {"Library", "Application Support", "ErgoptiPlus"}) {
    if (!accepted) break;
    const int next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    const bool previous_closed = close(parent) == 0;
    parent = next;
    accepted = next >= 0 && previous_closed && protected_directory(next);
  }
  int named = -1;
  struct stat observed{}, final{};
  if (accepted) {
    named = openat(parent, ".runtime-service-lifecycle-lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    accepted = named >= 0 && fstat(named, &observed) == 0 && same_file(identity, observed) && empty_acl(named) &&
        fstat(inherited, &final) == 0 && same_file(identity, final);
  }
  if (named >= 0 && close(named) != 0) accepted = false;
  if (parent >= 0 && close(parent) != 0) accepted = false;
  return accepted;
}

inline bool process(pid_t pid, proc_bsdinfo& result) {
  return pid > 1 && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &result, sizeof(result)) == sizeof(result) &&
      result.pbi_pid == static_cast<unsigned>(pid) && result.pbi_start_tvusec < 1000000;
}

inline bool same_birth(const proc_bsdinfo& left, const proc_bsdinfo& right) {
  return left.pbi_pid == right.pbi_pid && left.pbi_uid == right.pbi_uid &&
      left.pbi_start_tvsec == right.pbi_start_tvsec && left.pbi_start_tvusec == right.pbi_start_tvusec;
}

inline std::optional<std::vector<unsigned char>> live_leaf(pid_t pid, const char* identifier, const char* fixed_path = nullptr) {
  proc_bsdinfo before{}, after{};
  const auto closed_role = ergoptiplus::installed_publisher::closed_role(identifier);
  if (!closed_role || !process(pid, before)) return std::nullopt;
  cf_owner<CFNumberRef> number;
  *number.out() = CFNumberCreate(nullptr, kCFNumberIntType, &pid);
  if (!number.get()) return std::nullopt;
  const void* key = kSecGuestAttributePid;
  const void* value = number.get();
  cf_owner<CFDictionaryRef> attributes;
  *attributes.out() = CFDictionaryCreate(nullptr, &key, &value, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  cf_owner<SecCodeRef> live;
  cf_owner<SecStaticCodeRef> code;
  cf_owner<SecRequirementRef> requirement;
  cf_owner<CFStringRef> expression;
  const std::string text = std::string("identifier \"") + identifier + "\"";
  *expression.out() = CFStringCreateWithCString(nullptr, text.c_str(), kCFStringEncodingUTF8);
  if (!number.get() || !attributes.get() || !expression.get() ||
      SecRequirementCreateWithString(expression.get(), kSecCSDefaultFlags, requirement.out()) != errSecSuccess ||
      SecCodeCopyGuestWithAttributes(nullptr, attributes.get(), kSecCSDefaultFlags, live.out()) != errSecSuccess ||
      SecCodeCheckValidity(live.get(), kSecCSStrictValidate, requirement.get()) != errSecSuccess ||
      SecCodeCopyStaticCode(live.get(), kSecCSDefaultFlags, code.out()) != errSecSuccess ||
      SecStaticCodeCheckValidity(code.get(), static_cast<SecCSFlags>(kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode),
                                 requirement.get()) != errSecSuccess) return std::nullopt;
  cf_owner<CFDictionaryRef> information;
  if (SecCodeCopySigningInformation(code.get(), kSecCSSigningInformation, information.out()) != errSecSuccess || !information.get()) return std::nullopt;
  if (fixed_path) {
    const auto executable = CFDictionaryGetValue(information.get(), kSecCodeInfoMainExecutable);
    if (!executable || CFGetTypeID(executable) != CFURLGetTypeID()) return std::nullopt;
    std::array<UInt8, 4096> path{};
    if (!CFURLGetFileSystemRepresentation(static_cast<CFURLRef>(executable), true, path.data(), path.size()) ||
        std::strcmp(reinterpret_cast<const char*>(path.data()), fixed_path) != 0) return std::nullopt;
  }
  auto leaf = ergoptiplus::installed_publisher::detail::leaf(code.get(), *closed_role);
  if (!leaf || !process(pid, after) || !same_birth(before, after) ||
      SecCodeCheckValidity(live.get(), kSecCSStrictValidate, requirement.get()) != errSecSuccess) return std::nullopt;
  return leaf;

}

inline bool headless_parent(pid_t parent) {
  std::array<int, 3> query{CTL_KERN, KERN_PROCARGS2, parent};
  size_t length = 0;
  if (sysctl(query.data(), query.size(), nullptr, &length, nullptr, 0) != 0 || length < sizeof(int) || length > 262144) return false;
  std::vector<char> data(length);
  if (sysctl(query.data(), query.size(), data.data(), &length, nullptr, 0) != 0 || length > data.size()) return false;
  int count = 0;
  std::memcpy(&count, data.data(), sizeof(count));
  if (count != 2) return false;
  size_t offset = sizeof(count);
  auto next_string = [&]() -> std::optional<std::string> {
    if (offset >= length) return std::nullopt;
    const auto end = static_cast<const char*>(std::memchr(data.data() + offset, '\0', length - offset));
    if (!end) return std::nullopt;
    std::string result(data.data() + offset, static_cast<size_t>(end - (data.data() + offset)));
    offset = static_cast<size_t>(end - data.data()) + 1;
    return result;
  };
  if (!next_string()) return false; // Native executable path, not an authority input.
  while (offset < length && data[offset] == '\0') ++offset;
  const auto executable = next_string();
  const auto role = next_string();
  return executable && !executable->empty() && role && *role == "--installed-physical-source";
}
} // namespace detail
} // namespace ergoptiplus::installed_capture
