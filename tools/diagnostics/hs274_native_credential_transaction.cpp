// tools/diagnostics/hs274_native_credential_transaction.cpp
// SOURCE-ONLY TEST-ONLY proposal. Not registered or executed.
// A retained native transaction temp inode is the only allowed final inode.
// Darwin Security/CSSM APIs are required; there is no alternate backend.
#include <Security/Security.h>
#include <Security/cssmapi.h>
#include <Security/cssmapple.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <limits.h>
#include <dirent.h>
#include <fcntl.h>
#include <cerrno>
#include <cstdint>
#include <unistd.h>
#include <array>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <algorithm>

namespace ergopti_test_only {
// All errors retain the private route as cleanup debt. No path-based deletion
// or native object destruction is allowed after an unqualified route change.
[[noreturn]] void refuse() { std::_Exit(70); }
void require(bool condition) { if (!condition) refuse(); }
void status(OSStatus value) { require(value == errSecSuccess); }
void receive_exact(int channel, unsigned char* bytes, size_t size);
void reject_pending_input(int channel);

struct File {
  int descriptor;
  struct stat observed;
};
bool fixed(const struct stat& a, const struct stat& b) {
  return a.st_dev == b.st_dev && a.st_ino == b.st_ino &&
         a.st_uid == b.st_uid && a.st_gid == b.st_gid &&
         a.st_mode == b.st_mode && a.st_nlink == b.st_nlink;
}
File opened(int root, const std::string& name, bool empty = false) {
  struct stat named{};
  require(fstatat(root, name.c_str(), &named, AT_SYMLINK_NOFOLLOW) == 0);
  require(S_ISREG(named.st_mode) && named.st_uid == geteuid() && named.st_nlink == 1);
  require((named.st_mode & 07777) == 0600 && (empty ? named.st_size == 0 : named.st_size > 0));
  int fd = openat(root, name.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
  require(fd >= 0);
  struct stat held{};
  require(fstat(fd, &held) == 0 && fixed(held, named) &&
          held.st_size == named.st_size &&
          held.st_mtimespec.tv_sec == named.st_mtimespec.tv_sec &&
          held.st_mtimespec.tv_nsec == named.st_mtimespec.tv_nsec &&
          held.st_ctimespec.tv_sec == named.st_ctimespec.tv_sec &&
          held.st_ctimespec.tv_nsec == named.st_ctimespec.tv_nsec);
  return {fd, held};
}
std::vector<std::string> names(int root) {
  int copy = openat(root, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  require(copy >= 0);
  DIR* directory = fdopendir(copy);
  require(directory != nullptr);
  std::vector<std::string> result;
  errno = 0;
  while (auto entry = readdir(directory)) {
    std::string name(entry->d_name);
    if (name == "." || name == "..") continue;
    require(result.size() < 3 && name.find('/') == std::string::npos);
    result.push_back(name);
  }
  require(errno == 0 && closedir(directory) == 0);
  std::sort(result.begin(), result.end());
  return result;
}
// This inventory anchors physical objects via held duplicates. It does not
// expose a kernel file-description generation ID: same-vnode, same-flags
// close/reopen of an original descriptor number is not distinguishable by these
// public calls. This unresolved limitation blocks native qualification.
struct DescriptorInventory {
  struct Entry { int original; int anchor; int flags; struct stat observed; };
  std::vector<Entry> originals;
  std::vector<int> before;
  int bound;
  DescriptorInventory() {
    struct rlimit limit{};
    require(getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur <= 65536);
    bound = static_cast<int>(limit.rlim_cur);
    // Fixed producer has no caller callback or concurrent application writer.
    // Library-internal threads and any incidental FD mutation remain native
    // preconditions, not assumed proven by this source-only proposal.
    for (int fd = 0; fd < bound; ++fd) {
      errno = 0;
      int flags = fcntl(fd, F_GETFL);
      if (flags == -1) { require(errno == EBADF); continue; }
      require(originals.size() < 64);
      struct stat observed{}; require(fstat(fd, &observed) == 0);
      originals.push_back({fd, -1, flags, observed});
    }
    for (auto& entry : originals) {
      entry.anchor = fcntl(entry.original, F_DUPFD_CLOEXEC, 3);
      require(entry.anchor >= 0);
      struct stat held{}, actual{};
      require(fstat(entry.anchor, &held) == 0 &&
              fstat(entry.original, &actual) == 0 &&
              fixed(entry.observed, held) && fixed(entry.observed, actual) &&
              fcntl(entry.original, F_GETFL) == entry.flags);
    }
    for (int fd = 0; fd < bound; ++fd) {
      errno = 0;
      if (fcntl(fd, F_GETFD) != -1) before.push_back(fd);
      else require(errno == EBADF);
    }
  }
  void guard() const {
    for (const auto& entry : originals) {
      struct stat held{}, actual{};
      require(fstat(entry.anchor, &held) == 0 &&
              fstat(entry.original, &actual) == 0 &&
              fixed(entry.observed, held) && fixed(entry.observed, actual) &&
              fcntl(entry.original, F_GETFL) == entry.flags);
    }
    for (int fd : before) require(fcntl(fd, F_GETFD) != -1);
  }
  int native_temporary(const std::string& root, std::string& leaf) const {
    guard();
    int native = -1;
    for (int fd = 0; fd < bound; ++fd) {
      if (std::binary_search(before.begin(), before.end(), fd)) continue;
      errno = 0;
      int flags = fcntl(fd, F_GETFL);
      if (flags == -1) { require(errno == EBADF); continue; }
      struct stat value{}; require(fstat(fd, &value) == 0);
      if (!S_ISREG(value.st_mode) || (flags & O_ACCMODE) != O_WRONLY) continue;
      char path[PATH_MAX]{};
      require(fcntl(fd, F_GETPATH, path) == 0);
      std::string actual(path), prefix = root + "/";
      if (actual.compare(0, prefix.size(), prefix) != 0) continue;
      require(native == -1 && value.st_uid == geteuid() &&
              value.st_nlink == 1 && (value.st_mode & 07777) == 0600 &&
              value.st_size == 0);
      leaf = actual.substr(prefix.size());
      require(!leaf.empty() && leaf.find('/') == std::string::npos &&
              leaf != "fixture.keychain-db" && leaf[0] != '.');
      native = fd;
    }
    // There is deliberately no directory-delta or pathname fallback.
    require(native >= 0); guard();
    int retained = fcntl(native, F_DUPFD_CLOEXEC, 3); require(retained >= 0);
    struct stat source{}, held{};
    require(fstat(native, &source) == 0 && fstat(retained, &held) == 0 &&
            fixed(source, held) && source.st_size == 0 && held.st_size == 0 &&
            (fcntl(native, F_GETFL) & O_ACCMODE) == O_WRONLY &&
            (fcntl(retained, F_GETFL) & O_ACCMODE) == O_WRONLY);
    guard(); return retained;
  }
  void release() {
    guard();
    for (auto& entry : originals) {
      require(close(entry.anchor) == 0); entry.anchor = -1;
    }
  }
};

struct Root {
  struct Ancestor { int descriptor; std::string path; struct stat observed; };
  std::vector<Ancestor> ancestors;
  int descriptor;
  std::string path;
  struct stat observed;
  std::string lock_name;
  File keychain;
  File lock;
  File temporary;
  File native_temporary;
  std::vector<unsigned char> original_bytes;
  std::vector<unsigned char> committed_bytes;
  std::string temporary_name;
  bool acquired = false;
  bool committed = false;

  explicit Root(std::string input) : path(std::move(input)) {
    char* actual = realpath(path.c_str(), nullptr);
    require(actual != nullptr && path == actual);
    free(actual);
    descriptor = open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    require(descriptor >= 0 && fstat(descriptor, &observed) == 0);
    require(S_ISDIR(observed.st_mode) && observed.st_uid == geteuid() &&
            (observed.st_mode & 07777) == 0700);
    struct statfs filesystem{};
    require(fstatfs(descriptor, &filesystem) == 0 && (filesystem.f_flags & MNT_LOCAL));
    require(names(descriptor).empty());
    std::vector<std::string> prefixes{"/"};
    for (size_t position = 1; position < path.size(); ++position)
      if (path[position] == '/') prefixes.push_back(path.substr(0, position));
    prefixes.push_back(path); require(prefixes.size() <= 32);
    for (const auto& prefix : prefixes) {
      struct stat named{}, held{}; require(lstat(prefix.c_str(), &named) == 0 && S_ISDIR(named.st_mode));
      int fd = open(prefix.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW); require(fd >= 0);
      require(fstat(fd, &held) == 0 && ancestor_stamp(named, held));
      ancestors.push_back({fd, prefix, named});
    }
    route();
    std::array<unsigned char, CC_SHA1_DIGEST_LENGTH> digest{};
    const char* leaf = "fixture.keychain-db";
    // Match FileDL's native lock-leaf derivation; not a cryptographic trust hash.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA1(leaf, static_cast<CC_LONG>(strlen(leaf)), digest.data());
#pragma clang diagnostic pop
    static constexpr char hex[] = "0123456789ABCDEF";
    lock_name = ".fl";
    for (size_t i = 0; i < 4; ++i) {
      lock_name += hex[digest[i] >> 4]; lock_name += hex[digest[i] & 15];
    }
  }
  static bool ancestor_stamp(const struct stat& a, const struct stat& b) {
    // Exact original _stamp ancestor policy: dev/inode/UID/permission bits.
    // Directory times/link counts legitimately change as unrelated names do.
    return S_ISDIR(a.st_mode) && S_ISDIR(b.st_mode) && a.st_dev == b.st_dev &&
           a.st_ino == b.st_ino && a.st_uid == b.st_uid &&
           (a.st_mode & 07777) == (b.st_mode & 07777);
  }
  void route() const {
    for (const auto& parent : ancestors) {
      struct stat held{}, named{};
      require(fstat(parent.descriptor, &held) == 0 && lstat(parent.path.c_str(), &named) == 0 &&
              ancestor_stamp(parent.observed, held) && ancestor_stamp(parent.observed, named));
    }
    struct stat held{}, named{};
    require(fstat(descriptor, &held) == 0 && lstat(path.c_str(), &named) == 0);
    require(fixed(held, observed) && fixed(named, observed));
    char* actual = realpath(path.c_str(), nullptr);
    require(actual != nullptr && path == actual); free(actual);
  }
  void file(const File& held, const std::string& name, bool empty = false) const {
    struct stat descriptor_value{}, named{};
    require(fstat(held.descriptor, &descriptor_value) == 0 &&
            fstatat(descriptor, name.c_str(), &named, AT_SYMLINK_NOFOLLOW) == 0);
    require(fixed(held.observed, descriptor_value) && fixed(held.observed, named));
    for (const auto* value : {&descriptor_value, &named}) {
      require(value->st_size == held.observed.st_size &&
              value->st_mtimespec.tv_sec == held.observed.st_mtimespec.tv_sec &&
              value->st_mtimespec.tv_nsec == held.observed.st_mtimespec.tv_nsec &&
              value->st_ctimespec.tv_sec == held.observed.st_ctimespec.tv_sec &&
              value->st_ctimespec.tv_nsec == held.observed.st_ctimespec.tv_nsec);
    }
    if (empty) require(descriptor_value.st_size == 0 && named.st_size == 0);
  }
  std::vector<unsigned char> bytes(const File& input) const {
    struct stat before{}, after{};
    require(fstat(input.descriptor, &before) == 0 && S_ISREG(before.st_mode) &&
            before.st_size > 0 && before.st_size <= 4 * 1024 * 1024);
    std::vector<unsigned char> result(static_cast<size_t>(before.st_size));
    size_t offset = 0;
    while (offset < result.size()) {
      ssize_t count = pread(input.descriptor, result.data() + offset, result.size() - offset, offset);
      require(count > 0); offset += static_cast<size_t>(count);
    }
    require(fstat(input.descriptor, &after) == 0 && fixed(before, after) &&
            before.st_size == after.st_size &&
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec);
    return result;
  }
  void guard() const {
    route(); file(lock, lock_name, true);
    if (!committed) {
      file(keychain, "fixture.keychain-db"); require(bytes(keychain) == original_bytes);
    } else {
      file(temporary, "fixture.keychain-db"); require(bytes(temporary) == committed_bytes);
    }
    if (acquired && !committed) {
      file(temporary, temporary_name, true);
      file(native_temporary, temporary_name, true);
    }
    if (committed) file(native_temporary, "fixture.keychain-db");
    std::vector<std::string> expected{"fixture.keychain-db", lock_name};
    if (acquired && !committed) expected.push_back(temporary_name);
    std::sort(expected.begin(), expected.end());
    require(names(descriptor) == expected);
  }
  void acquire_temporary(DescriptorInventory& inventory) {
    route(); file(keychain, "fixture.keychain-db"); file(lock, lock_name);
    int actual = inventory.native_temporary(path, temporary_name);
    struct stat value{}; require(fstat(actual, &value) == 0);
    native_temporary = {actual, value};
    temporary = opened(descriptor, temporary_name, true);
    require(fixed(native_temporary.observed, temporary.observed));
    acquired = true; guard(); inventory.release(); guard();
  }
  void accept_commit() {
    route(); file(lock, lock_name);
    struct stat final{}, temporary_value{}, old{};
    require(fstat(temporary.descriptor, &temporary_value) == 0 &&
            fstatat(descriptor, "fixture.keychain-db", &final, AT_SYMLINK_NOFOLLOW) == 0 &&
            fstat(keychain.descriptor, &old) == 0);
    require(fixed(temporary.observed, temporary_value) && fixed(temporary_value, final) &&
            S_ISREG(final.st_mode) && final.st_size > 0 && old.st_nlink == 0);
    struct stat missing{};
    require(fstatat(descriptor, temporary_name.c_str(), &missing, AT_SYMLINK_NOFOLLOW) == -1 && errno == ENOENT);
    require(bytes(keychain) == original_bytes);
    committed_bytes = bytes(temporary);
    require(committed_bytes != original_bytes);
    struct stat native_value{};
    require(fstat(native_temporary.descriptor, &native_value) == 0 &&
            fixed(native_temporary.observed, native_value) &&
            fixed(native_value, final));
    temporary.observed = temporary_value;
    native_temporary.observed = native_value;
    committed = true; guard();
  }
};

// Public deprecated CSSM APIs are intentional and confined to this TEST-ONLY
// native provider. Actual SDK availability remains a required native check.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
struct NativeOwner {
  Root root;
  SecKeychainRef keychain = nullptr;
  CSSM_DL_DB_HANDLE database{};
  CSSM_BOOL was_autocommit = CSSM_FALSE;
  bool transaction = false;
  SecIdentityRef identity = nullptr;
  SecKeyRef key = nullptr;
  SecCertificateRef certificate = nullptr;
  explicit NativeOwner(const std::string& path, const std::string& password) : root(path) {
    // ORIGINAL FIRST-admission policy, not mutable-phase recapture and not
    // a fallback from the unsupported initial native-FD prototype. Like the
    // original fixed create-keychain helper, trust only this fixed synchronous
    // creator's first result in the initially empty private route; retain it
    // with named/held O_NOFOLLOW currentness before any subsequent mutation.
    // Concurrent replacement inside Create/before first admission is the same
    // original attribution limit, not a new universal ownership guarantee.
    root.route(); require(names(root.descriptor).empty());
    status(SecKeychainCreate((path + "/fixture.keychain-db").c_str(),
                            static_cast<UInt32>(password.size()), password.data(), false,
                            nullptr, &keychain));
    require(keychain && CFGetTypeID(keychain) == SecKeychainGetTypeID()); root.route();
    root.keychain = opened(root.descriptor, "fixture.keychain-db");
    root.file(root.keychain, "fixture.keychain-db"); root.route();
    root.original_bytes = root.bytes(root.keychain);
    // Local FileDL's fixed SHA1-derived lock leaf is native-produced and empty.
    int lockfd = openat(root.descriptor, root.lock_name.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    require(lockfd >= 0);
    struct stat lockstat{};
    require(fstat(lockfd, &lockstat) == 0 && S_ISREG(lockstat.st_mode) &&
            lockstat.st_uid == geteuid() && (lockstat.st_mode & 07777) == 0600 &&
            lockstat.st_nlink == 1 && lockstat.st_size == 0);
    root.lock = {lockfd, lockstat}; root.guard();
    status(SecKeychainGetDLDBHandle(keychain, &database)); root.guard();
    require(database.DLHandle != CSSM_INVALID_HANDLE && database.DBHandle != CSSM_INVALID_HANDLE);
    require(CSSM_DL_PassThrough(database, CSSM_APPLEFILEDL_TOGGLE_AUTOCOMMIT,
                              nullptr, reinterpret_cast<void**>(&was_autocommit)) == CSSM_OK);
    require(was_autocommit == CSSM_TRUE); transaction = true; root.guard();
    DescriptorInventory inventory; root.guard(); inventory.guard();
    require(CSSM_DL_PassThrough(database, CSSM_APPLEFILEDL_TAKE_FILE_LOCK, nullptr, nullptr) == CSSM_OK);
    root.acquire_temporary(inventory);
    SecKeychainSettings settings{SEC_KEYCHAIN_SETTINGS_VERS1, true, true, 21600};
    root.guard(); status(SecKeychainSetSettings(keychain, &settings)); root.guard();
    status(SecKeychainUnlock(keychain, static_cast<UInt32>(password.size()), password.data(), true)); root.guard();
  }
  void import_identity(const std::vector<unsigned char>& package,
                       const std::vector<unsigned char>& leaf,
                       const std::string& password) {
    root.guard();
    require(!package.empty() && package.size() <= 65536 && !leaf.empty() && leaf.size() <= 8192);
    auto package_data = CFDataCreate(kCFAllocatorDefault, package.data(), package.size());
    auto expected_leaf = CFDataCreate(kCFAllocatorDefault, leaf.data(), leaf.size());
    auto passphrase = CFStringCreateWithBytes(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(password.data()), password.size(), kCFStringEncodingUTF8, false);
    require(package_data && expected_leaf && passphrase); root.guard();
    SecTrustedApplicationRef codesign = nullptr;
    status(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &codesign));
    require(codesign && CFGetTypeID(codesign) == SecTrustedApplicationGetTypeID()); root.guard();
    const void* trusted_values[]{codesign};
    auto trusted = CFArrayCreate(kCFAllocatorDefault, trusted_values, 1, &kCFTypeArrayCallBacks);
    require(trusted); SecAccessRef access = nullptr;
    status(SecAccessCreate(CFSTR("ErgoptiPlus Disposable Runtime Signing TEST ONLY"), trusted, &access));
    require(access && CFGetTypeID(access) == SecAccessGetTypeID()); root.guard();
    const void* option_keys[]{kSecImportExportPassphrase, kSecImportExportKeychain, kSecImportExportAccess};
    const void* option_values[]{passphrase, keychain, access};
    auto options = CFDictionaryCreate(kCFAllocatorDefault, option_keys, option_values, 3,
                                     &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    require(options); CFArrayRef items = nullptr; root.guard();
    status(SecPKCS12Import(package_data, options, &items)); root.guard();
    require(items && CFGetTypeID(items) == CFArrayGetTypeID() && CFArrayGetCount(items) == 1);
    auto item = reinterpret_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(items, 0));
    require(item && CFGetTypeID(item) == CFDictionaryGetTypeID());
    identity = reinterpret_cast<SecIdentityRef>(const_cast<void*>(CFDictionaryGetValue(item, kSecImportItemIdentity)));
    require(identity && CFGetTypeID(identity) == SecIdentityGetTypeID()); CFRetain(identity);
    auto chain = reinterpret_cast<CFArrayRef>(CFDictionaryGetValue(item, kSecImportItemCertChain));
    require(chain && CFGetTypeID(chain) == CFArrayGetTypeID() && CFArrayGetCount(chain) == 1);
    status(SecIdentityCopyCertificate(identity, &certificate));
    require(certificate && CFGetTypeID(certificate) == SecCertificateGetTypeID());
    auto actual_leaf = SecCertificateCopyData(certificate);
    require(actual_leaf && CFGetTypeID(actual_leaf) == CFDataGetTypeID() && CFEqual(actual_leaf, expected_leaf));
    auto chain_certificate = CFArrayGetValueAtIndex(chain, 0);
    require(chain_certificate && CFGetTypeID(chain_certificate) == SecCertificateGetTypeID() &&
            CFEqual(chain_certificate, certificate)); root.guard();
    bind_key();
    CFRelease(actual_leaf); CFRelease(items); CFRelease(options); CFRelease(access);
    CFRelease(trusted); CFRelease(codesign); CFRelease(passphrase); CFRelease(expected_leaf); CFRelease(package_data);
    root.guard();
  }
  void partition_policy(const std::string& password) {
    // Public CSSM equivalents of Apple's password-authorized single-entry edit.
    root.guard(); require(key && identity && !root.committed);
    SecAccessRef access = nullptr;
    status(SecKeychainItemCopyAccess(reinterpret_cast<SecKeychainItemRef>(key), &access));
    require(access && CFGetTypeID(access) == SecAccessGetTypeID());
    CFArrayRef acl_list = nullptr; status(SecAccessCopyACLList(access, &acl_list));
    require(acl_list && CFGetTypeID(acl_list) == CFArrayGetTypeID() &&
            CFArrayGetCount(acl_list) > 0 && CFArrayGetCount(acl_list) <= 64);
    SecACLRef partition = nullptr;
    for (CFIndex i = 0; i < CFArrayGetCount(acl_list); ++i) {
      auto acl = reinterpret_cast<SecACLRef>(const_cast<void*>(CFArrayGetValueAtIndex(acl_list, i)));
      require(acl && CFGetTypeID(acl) == SecACLGetTypeID());
      CSSM_ACL_AUTHORIZATION_TAG tags[64]{}; uint32 count = 64;
      status(SecACLGetAuthorizations(acl, tags, &count)); require(count <= 64);
      for (uint32 j = 0; j < count; ++j) if (tags[j] == CSSM_ACL_AUTHORIZATION_PARTITION_ID) {
        require(partition == nullptr && count == 1); partition = acl;
      }
    }
    require(partition); root.guard();
    const void* allowed[]{CFSTR("apple-tool:"), CFSTR("apple:"), CFSTR("codesign:")};
    auto values = CFArrayCreate(kCFAllocatorDefault, allowed, 3, &kCFTypeArrayCallBacks);
    const void* keys[]{CFSTR("Partitions")}; const void* vals[]{values};
    auto dictionary = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 1,
                                         &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    require(values && dictionary);
    auto xml = CFPropertyListCreateData(kCFAllocatorDefault, dictionary,
                                        kCFPropertyListXMLFormat_v1_0, 0, nullptr);
    require(xml && CFDataGetLength(xml) > 0 && CFDataGetLength(xml) <= 8192);
    static constexpr char digits[] = "0123456789abcdef";
    std::string encoded;
    for (CFIndex i = 0; i < CFDataGetLength(xml); ++i) {
      unsigned char value = CFDataGetBytePtr(xml)[i];
      encoded += digits[value >> 4]; encoded += digits[value & 15];
    }
    auto description = CFStringCreateWithBytes(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(encoded.data()), encoded.size(), kCFStringEncodingASCII, false);
    require(description);
    CFArrayRef applications = nullptr; CFStringRef previous_description = nullptr;
    CSSM_ACL_KEYCHAIN_PROMPT_SELECTOR selector{};
    status(SecACLCopySimpleContents(partition, &applications, &previous_description, &selector));
    status(SecACLSetSimpleContents(partition, applications, description, &selector)); root.guard();
    CSSM_ACL_OWNER_PROTOTYPE* owner = nullptr; CSSM_ACL_ENTRY_INFO* entries = nullptr; uint32 count = 0;
    status(SecAccessGetOwnerAndACL(access, &owner, &count, &entries));
    require(owner && entries && count > 0 && count <= 64);
    const CSSM_ACL_ENTRY_INFO* selected = nullptr;
    for (uint32 i = 0; i < count; ++i) {
      const auto& prototype = entries[i].EntryPublicInfo;
      require(prototype.Authorization.NumberOfAuthTags <= 64);
      if (prototype.Authorization.NumberOfAuthTags == 1 &&
          prototype.Authorization.AuthTags &&
          prototype.Authorization.AuthTags[0] == CSSM_ACL_AUTHORIZATION_PARTITION_ID) {
        require(selected == nullptr &&
                strnlen(prototype.EntryTag, sizeof(prototype.EntryTag)) == strlen(CSSM_APPLE_ACL_TAG_PARTITION_ID) &&
                strcmp(prototype.EntryTag, CSSM_APPLE_ACL_TAG_PARTITION_ID) == 0);
        selected = &entries[i];
      }
    }
    require(selected); root.guard();
    CSSM_CSP_HANDLE provider = CSSM_INVALID_HANDLE; const CSSM_KEY* native_key = nullptr;
    status(SecKeyGetCSPHandle(key, &provider)); status(SecKeyGetCSSMKey(key, &native_key));
    require(provider != CSSM_INVALID_HANDLE && native_key);
    CSSM_LIST_ELEMENT sample_elements[3]{};
    sample_elements[0].ElementType = CSSM_LIST_ELEMENT_WORDID;
    sample_elements[0].WordID = CSSM_SAMPLE_TYPE_KEYCHAIN_LOCK;
    sample_elements[0].NextElement = &sample_elements[1];
    sample_elements[1].ElementType = CSSM_LIST_ELEMENT_WORDID;
    sample_elements[1].WordID = CSSM_SAMPLE_TYPE_PASSWORD;
    sample_elements[1].NextElement = &sample_elements[2];
    sample_elements[2].ElementType = CSSM_LIST_ELEMENT_DATUM;
    sample_elements[2].Element.Word = CSSM_DATA{password.size(),
        reinterpret_cast<uint8*>(const_cast<char*>(password.data()))};
    CSSM_SAMPLE sample{};
    sample.TypedSample = CSSM_LIST{CSSM_LIST_TYPE_UNKNOWN, &sample_elements[0], &sample_elements[2]};
    CSSM_ACCESS_CREDENTIALS credentials{}; credentials.Samples = CSSM_SAMPLEGROUP{1, &sample};
    CSSM_ACL_ENTRY_INPUT input{}; input.Prototype = selected->EntryPublicInfo;
    CSSM_ACL_EDIT edit{CSSM_ACL_EDIT_MODE_REPLACE, selected->EntryHandle, &input};
    root.guard();
    require(CSSM_ChangeKeyAcl(provider, &credentials, &edit, native_key) == CSSM_OK); root.guard();
    // All other entries and the owner are untouched: the public native call is
    // precisely one REPLACE with the previously observed partition handle.
    CFRelease(description); CFRelease(xml); CFRelease(dictionary); CFRelease(values);
    if (applications) CFRelease(applications);
    if (previous_description) CFRelease(previous_description);
    CFRelease(acl_list); CFRelease(access); root.guard();
  }
  void bind_key() {
    root.guard();
    status(SecIdentityCopyPrivateKey(identity, &key));
    require(key && CFGetTypeID(key) == SecKeyGetTypeID());
    SecKeychainRef actual = nullptr;
    status(SecKeychainItemCopyKeychain(reinterpret_cast<SecKeychainItemRef>(key), &actual));
    require(actual && CFGetTypeID(actual) == SecKeychainGetTypeID() && CFEqual(actual, keychain));
    CSSM_DL_DB_HANDLE key_database{};
    status(SecKeychainItemGetDLDBHandle(reinterpret_cast<SecKeychainItemRef>(key), &key_database));
    require(key_database.DLHandle == database.DLHandle && key_database.DBHandle == database.DBHandle);
    CFRelease(actual); root.guard();
  }
  void verify_policy() {
    root.guard();
    SecAccessRef access = nullptr;
    status(SecKeychainItemCopyAccess(reinterpret_cast<SecKeychainItemRef>(key), &access));
    require(access && CFGetTypeID(access) == SecAccessGetTypeID());
    CFArrayRef list = nullptr; status(SecAccessCopySelectedACLList(access, CSSM_ACL_AUTHORIZATION_PARTITION_ID, &list));
    require(list && CFGetTypeID(list) == CFArrayGetTypeID() && CFArrayGetCount(list) == 1);
    auto acl = reinterpret_cast<SecACLRef>(const_cast<void*>(CFArrayGetValueAtIndex(list, 0)));
    require(acl && CFGetTypeID(acl) == SecACLGetTypeID());
    CFArrayRef applications = nullptr; CFStringRef description = nullptr;
    CSSM_ACL_KEYCHAIN_PROMPT_SELECTOR selector{};
    status(SecACLCopySimpleContents(acl, &applications, &description, &selector));
    require(description && CFGetTypeID(description) == CFStringGetTypeID());
    char encoded[16385]{};
    require(CFStringGetCString(description, encoded, sizeof(encoded), kCFStringEncodingASCII));
    size_t size = strlen(encoded); require(size > 0 && size <= 16384 && size % 2 == 0);
    std::vector<unsigned char> decoded;
    auto digit = [](char c) -> unsigned {
      if (c >= '0' && c <= '9') return static_cast<unsigned>(c - '0');
      if (c >= 'a' && c <= 'f') return static_cast<unsigned>(c - 'a' + 10);
      if (c >= 'A' && c <= 'F') return static_cast<unsigned>(c - 'A' + 10);
      refuse();
    };
    for (size_t i = 0; i < size; i += 2) decoded.push_back(static_cast<unsigned char>(digit(encoded[i]) * 16 + digit(encoded[i+1])));
    auto data = CFDataCreate(kCFAllocatorDefault, decoded.data(), decoded.size()); require(data);
    auto payload = CFPropertyListCreateWithData(kCFAllocatorDefault, data, kCFPropertyListImmutable, nullptr, nullptr);
    require(payload && CFGetTypeID(payload) == CFDictionaryGetTypeID());
    auto dictionary = reinterpret_cast<CFDictionaryRef>(payload);
    require(CFDictionaryGetCount(dictionary) == 1);
    auto values = reinterpret_cast<CFArrayRef>(CFDictionaryGetValue(dictionary, CFSTR("Partitions")));
    require(values && CFGetTypeID(values) == CFArrayGetTypeID() && CFArrayGetCount(values) == 3);
    const CFStringRef allowed[]{CFSTR("apple-tool:"), CFSTR("apple:"), CFSTR("codesign:")};
    for (CFIndex i = 0; i < 3; ++i) {
      auto value = CFArrayGetValueAtIndex(values, i);
      require(value && CFGetTypeID(value) == CFStringGetTypeID() && CFEqual(value, allowed[i]));
    }
    CFRelease(payload); CFRelease(data); CFRelease(description);
    if (applications) CFRelease(applications);
    CFRelease(list); CFRelease(access); root.guard();
  }
  void verify_class(CFStringRef item_class, CFTypeRef expected) {
    require(root.committed && !transaction); root.guard();
    const void* owned[]{keychain};
    auto search = CFArrayCreate(kCFAllocatorDefault, owned, 1, &kCFTypeArrayCallBacks); require(search);
    const void* query_keys[]{kSecClass, kSecMatchSearchList, kSecMatchLimit, kSecReturnRef};
    const void* query_values[]{item_class, search, kSecMatchLimitAll, kCFBooleanTrue};
    auto query = CFDictionaryCreate(kCFAllocatorDefault, query_keys, query_values, 4,
                                    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    require(query); CFTypeRef result = nullptr;
    OSStatus outcome = SecItemCopyMatching(query, &result); root.guard();
    if (!expected) require(outcome == errSecItemNotFound && result == nullptr);
    else {
      status(outcome); require(result && CFGetTypeID(result) == CFArrayGetTypeID());
      auto values = reinterpret_cast<CFArrayRef>(result);
      require(CFArrayGetCount(values) == 1 &&
              CFEqual(CFArrayGetValueAtIndex(values, 0), expected));
    }
    if (result) CFRelease(result);
    CFRelease(query); CFRelease(search); root.guard();
  }
  void verify_complete_inventory() {
    // Complete public item classes, not only sign-capable keys. Native FileDL
    // internal database metadata is not a public SecItem credential object.
    verify_class(kSecClassKey, key);
    verify_class(kSecClassCertificate, certificate);
    verify_class(kSecClassIdentity, identity);
    verify_class(kSecClassGenericPassword, nullptr);
    verify_class(kSecClassInternetPassword, nullptr);
    verify_policy(); root.guard();
  }
  void release_known_objects() {
    // No destructor/rollback runs on refusal. Native process termination is
    // acknowledged by the wrapper; CF release is not claimed to retire global
    // Security.framework caches or asynchronous securityd resources here.
    root.guard(); require(root.committed && !transaction);
    CFRelease(identity); identity = nullptr; root.guard();
    CFRelease(key); key = nullptr; root.guard();
    CFRelease(certificate); certificate = nullptr; root.guard();
    CFRelease(keychain); keychain = nullptr; root.guard();
  }
  void commit() {
    root.guard();
    require(CSSM_DL_PassThrough(database, CSSM_APPLEFILEDL_COMMIT, nullptr, nullptr) == CSSM_OK);
    root.accept_commit(); transaction = false;
    require(CSSM_DL_PassThrough(database, CSSM_APPLEFILEDL_TOGGLE_AUTOCOMMIT,
                              reinterpret_cast<const void*>(static_cast<uintptr_t>(was_autocommit)), nullptr) == CSSM_OK);
    root.guard();
  }
  // This proof handoff conveys the actual retained native output descriptor,
  // not its scalar inode. Parent must acknowledge custody before native release.
  void transfer_final_descriptor(int channel) {
    require(root.committed && !transaction); root.guard();
    reject_pending_input(channel); root.guard();
    std::array<unsigned char, 33> challenge{}; challenge[0] = 'F';
    status(SecRandomCopyBytes(kSecRandomDefault, 32, challenge.data() + 1)); root.guard();
    iovec vector{challenge.data(), challenge.size()};
    alignas(cmsghdr) std::array<unsigned char, CMSG_SPACE(sizeof(int))> ancillary{};
    msghdr message{}; message.msg_iov = &vector; message.msg_iovlen = 1;
    message.msg_control = ancillary.data(); message.msg_controllen = ancillary.size();
    auto control = CMSG_FIRSTHDR(&message);
    control->cmsg_level = SOL_SOCKET; control->cmsg_type = SCM_RIGHTS;
    control->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(control), &root.temporary.descriptor, sizeof(int));
    require(sendmsg(channel, &message, 0) == static_cast<ssize_t>(challenge.size())); root.guard();
    std::array<unsigned char, 33> acknowledgement{};
    receive_exact(channel, acknowledgement.data(), acknowledgement.size());
    require(acknowledgement[0] == 'A' &&
            memcmp(acknowledgement.data() + 1, challenge.data() + 1, 32) == 0);
    reject_pending_input(channel);
    root.guard();
  }
};
#pragma clang diagnostic pop
} // namespace ergopti_test_only

namespace ergopti_test_only {
void receive_exact(int channel, unsigned char* bytes, size_t size) {
  size_t offset = 0;
  while (offset < size) {
    iovec vector{bytes + offset, size - offset};
    alignas(cmsghdr) std::array<unsigned char, CMSG_SPACE(8 * sizeof(int))> ancillary{};
    msghdr message{}; message.msg_iov = &vector; message.msg_iovlen = 1;
    message.msg_control = ancillary.data(); message.msg_controllen = ancillary.size();
    ssize_t count = recvmsg(channel, &message, 0);
    if (count == -1 && errno == EINTR) continue;
    require(count > 0 && static_cast<size_t>(count) <= size - offset &&
            message.msg_controllen == 0 && (message.msg_flags & (MSG_CTRUNC | MSG_TRUNC)) == 0);
    offset += static_cast<size_t>(count);
  }
}
void reject_pending_input(int channel) {
  unsigned char extra{}; iovec vector{&extra, 1};
  alignas(cmsghdr) std::array<unsigned char, CMSG_SPACE(8 * sizeof(int))> ancillary{};
  msghdr message{}; message.msg_iov = &vector; message.msg_iovlen = 1;
  message.msg_control = ancillary.data(); message.msg_controllen = ancillary.size();
  errno = 0; ssize_t count = recvmsg(channel, &message, MSG_DONTWAIT);
  require(count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK));
}
uint32_t length(const unsigned char* bytes) {
  return (uint32_t(bytes[0]) << 24) | (uint32_t(bytes[1]) << 16) |
         (uint32_t(bytes[2]) << 8) | uint32_t(bytes[3]);
}
void fixed_channel() {
  struct stat channel{}; require(fstat(0, &channel) == 0 && S_ISSOCK(channel.st_mode));
  int type = 0; socklen_t size = sizeof(type);
  require(getsockopt(0, SOL_SOCKET, SO_TYPE, &type, &size) == 0 && type == SOCK_STREAM);
  sockaddr_un local{}, peer{}; socklen_t local_size = sizeof(local), peer_size = sizeof(peer);
  require(getsockname(0, reinterpret_cast<sockaddr*>(&local), &local_size) == 0 &&
          getpeername(0, reinterpret_cast<sockaddr*>(&peer), &peer_size) == 0 &&
          local.sun_family == AF_UNIX && peer.sun_family == AF_UNIX &&
          local.sun_path[0] == '\0' && peer.sun_path[0] == '\0');
  uid_t uid; gid_t gid;
  require(getpeereid(0, &uid, &gid) == 0 && uid == geteuid() && gid == getegid());
  pid_t owner = 0; size = sizeof(owner);
  require(getsockopt(0, SOL_LOCAL, LOCAL_PEERPID, &owner, &size) == 0 &&
          size == sizeof(owner) && owner == getppid());
}
} // namespace ergopti_test_only

int main(int argc, char** argv) {
  using namespace ergopti_test_only;
  // Root is the sole nonsecret argument. No caller-selected endpoint, profile,
  // native library/provider, keychain leaf, partition policy or channel exists.
  require(argc == 2 && argv[1] && argv[1][0] == '/'); fixed_channel();
  umask(077); // Native creation must produce0600; no named-file normalization.
  std::array<unsigned char, 16> frame{}; receive_exact(0, frame.data(), frame.size());
  require(memcmp(frame.data(), "ERP1", 4) == 0);
  uint32_t password_size = length(frame.data() + 4), package_size = length(frame.data() + 8),
           leaf_size = length(frame.data() + 12);
  require(password_size == 43 && package_size > 0 && package_size <= 65536 &&
          leaf_size > 0 && leaf_size <= 8192);
  std::string password(password_size, '\0');
  std::vector<unsigned char> package(package_size), leaf(leaf_size);
  receive_exact(0, reinterpret_cast<unsigned char*>(password.data()), password.size());
  require(password.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_") == std::string::npos);
  receive_exact(0, package.data(), package.size()); receive_exact(0, leaf.data(), leaf.size());
  reject_pending_input(0);
  NativeOwner native(argv[1], password);
  native.import_identity(package, leaf, password); native.partition_policy(password);
  native.commit(); native.verify_complete_inventory(); native.transfer_final_descriptor(0);
  native.release_known_objects();
  // Avoid unqualified path-based library destruction after the last qualified
  // route check. The wrapper MUST wait/reap this physical child before cleanup.
  std::_Exit(0);
}
