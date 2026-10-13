// Retained native maintenance admission. Only original held client/endpoint friends mint it.
#pragma once
#include "InstalledRuntimeMaintenancePeer.hpp"
#include <CommonCrypto/CommonDigest.h>

namespace ergoptiplus::installed_maintenance {
class maintenance_client;
class core_endpoint;
namespace admission_detail {
namespace publisher=ergoptiplus::installed_publisher;
namespace capture=ergoptiplus::installed_capture::detail;
inline constexpr const char* core_path="/Library/Application Support/ErgoptiPlus/Runtime/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core";
inline bool same_directory(const struct stat& a,const struct stat& b) {
  return S_ISDIR(a.st_mode) && S_ISDIR(b.st_mode) && a.st_dev==b.st_dev && a.st_ino==b.st_ino
      && a.st_mode==b.st_mode && a.st_uid==b.st_uid && a.st_gid==b.st_gid;
}
inline bool same_observation(const detail::observation& a,const detail::observation& b) {
  return std::memcmp(&a.token,&b.token,sizeof(a.token))==0 && a.pid==b.pid && a.euid==b.euid && a.egid==b.egid
      && a.self_euid==b.self_euid && a.self_egid==b.self_egid && a.self.identifier==b.self.identifier
      && a.peer.identifier==b.peer.identifier && a.self.leaf==b.self.leaf && a.peer.leaf==b.peer.leaf;
}
inline bool orientation(const detail::observation& fresh,bool client) {
  return getuid()==0 && geteuid()==0 && fresh.euid==0 && fresh.self_euid==0 && fresh.self_egid==getegid()
      && audit_token_to_pid(fresh.token)==fresh.pid && audit_token_to_euid(fresh.token)==fresh.euid
      && audit_token_to_egid(fresh.token)==fresh.egid
      && fresh.self.identifier==(client?"com.ergoptiplus.app.runtime-installer":"com.ergoptiplus.remap.core")
      && fresh.peer.identifier==(client?"com.ergoptiplus.remap.core":"com.ergoptiplus.app.runtime-installer");
}
inline bool audit_image(const detail::observation& fresh,publisher::role role,const std::string& path,const std::vector<uint8_t>& expected) {
  capture::cf_owner<CFDataRef> token;
  *token.out()=CFDataCreate(nullptr,reinterpret_cast<const UInt8*>(&fresh.token),sizeof(fresh.token));
  if (!token.get()) return false;
  const void* key=kSecGuestAttributeAudit;const void* value=token.get();
  capture::cf_owner<CFDictionaryRef> attributes;
  *attributes.out()=CFDictionaryCreate(nullptr,&key,&value,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
  capture::cf_owner<SecCodeRef> live;capture::cf_owner<SecStaticCodeRef> code;
  if (!attributes.get() || SecCodeCopyGuestWithAttributes(nullptr,attributes.get(),kSecCSDefaultFlags,live.out())!=errSecSuccess
      || !live.get() || SecCodeCheckValidity(live.get(),kSecCSStrictValidate,nullptr)!=errSecSuccess
      || SecCodeCopyStaticCode(live.get(),kSecCSDefaultFlags,code.out())!=errSecSuccess || !code.get()) return false;
  const auto leaf=publisher::detail::leaf(code.get(),role);
  capture::cf_owner<CFDictionaryRef> fields;
  if (!leaf || *leaf!=expected || *leaf!=fresh.peer.leaf
      || SecCodeCopySigningInformation(code.get(),kSecCSSigningInformation,fields.out())!=errSecSuccess || !fields.get()) return false;
  const auto main=CFDictionaryGetValue(fields.get(),kSecCodeInfoMainExecutable);
  std::array<UInt8,PROC_PIDPATHINFO_MAXSIZE> actual{};
  return main && CFGetTypeID(main)==CFURLGetTypeID()
      && CFURLGetFileSystemRepresentation(static_cast<CFURLRef>(main),true,actual.data(),actual.size())
      && path==reinterpret_cast<const char*>(actual.data())
      && SecCodeCheckValidity(live.get(),kSecCSStrictValidate,nullptr)==errSecSuccess;
}
// The original CMS/closed tree is checked before and after collecting held-file hashes.
// Post-Core-loss is a retained byte observation, never admission of a named replacement.
class retained_images final {
  struct image {size_t index;std::array<unsigned char,CC_SHA256_DIGEST_LENGTH> digest;};
  static bool hash(int fd,off_t size,std::array<unsigned char,CC_SHA256_DIGEST_LENGTH>& result) {
    if (size<0) return false;
    CC_SHA256_CTX state{};if (!CC_SHA256_Init(&state)) return false;
    std::array<unsigned char,65536> buffer{};off_t offset=0;
    while (offset<size) {
      const auto amount=std::min<off_t>(static_cast<off_t>(buffer.size()),size-offset);
      ssize_t count;do {count=pread(fd,buffer.data(),static_cast<size_t>(amount),offset);} while (count<0 && errno==EINTR);
      if (count<=0 || !CC_SHA256_Update(&state,buffer.data(),static_cast<CC_LONG>(count))) return false;
      offset+=count;
    }
    unsigned char tail=0;ssize_t count;do {count=pread(fd,&tail,1,size);} while (count<0 && errno==EINTR);
    return count==0 && CC_SHA256_Final(result.data(),&state);
  }
public:
  bool capture(publisher::owner& owner) {
    if (owner_ || !owner.current()) return false;
    for (size_t i=0;i<owner.nodes_.size();++i) {
      const auto& node=owner.nodes_[i];if (!S_ISREG(node.identity.st_mode)) continue;
      image held{i,{}};
      if (!hash(node.fd,node.identity.st_size,held.digest)) return false;
      images_.push_back(held);
    }
    if (images_.empty() || !owner.current()) return false;
    owner_=&owner;return true;
  }
  bool current() const {
    if (!owner_ || owner_->released_ || owner_->close_refused_ || images_.empty()) return false;
    for (const auto& node:owner_->nodes_) {
      struct stat now{};
      if (node.fd<0 || fstat(node.fd,&now)!=0 || !publisher::detail::empty_acl(node.fd)) return false;
      if (S_ISDIR(node.identity.st_mode)) {if (!same_directory(now,node.identity)) return false;}
      else if (!S_ISREG(now.st_mode) || now.st_dev!=node.identity.st_dev || now.st_ino!=node.identity.st_ino
          || now.st_mode!=node.identity.st_mode || now.st_uid!=node.identity.st_uid || now.st_gid!=node.identity.st_gid
          || now.st_size!=node.identity.st_size || now.st_mtimespec.tv_sec!=node.identity.st_mtimespec.tv_sec
          || now.st_mtimespec.tv_nsec!=node.identity.st_mtimespec.tv_nsec) return false;
    }
    for (const auto& image:images_) {
      const auto& node=owner_->nodes_[image.index];std::array<unsigned char,CC_SHA256_DIGEST_LENGTH> actual{};
      if (!hash(node.fd,node.identity.st_size,actual) || actual!=image.digest) return false;
    }
    return true;
  }
private:
  publisher::owner* owner_=nullptr;
  std::vector<image> images_;
};
} // namespace admission_detail

class staged_admission final : public std::enable_shared_from_this<staged_admission> {
  friend class maintenance_client;
  friend class core_endpoint;
  staged_admission()=default;
  static std::shared_ptr<staged_admission> acquire_client(const detail::observation& fresh) noexcept {return acquire(fresh,true);}
  static std::shared_ptr<staged_admission> acquire_core(const detail::observation& fresh) noexcept {return acquire(fresh,false);}
  static std::shared_ptr<staged_admission> acquire(const detail::observation& fresh,bool client) noexcept {
    std::shared_ptr<staged_admission> result;
    try {
      if (!admission_detail::orientation(fresh,client)) return nullptr;
      result=std::shared_ptr<staged_admission>(new staged_admission);result->custody_=result;
      result->client_=client;result->initial_=fresh;
      result->helper_pid_=client?getpid():fresh.pid;result->core_pid_=client?fresh.pid:getpid();
      const auto path=detail::native_executable(result->helper_pid_);
      if (!path || !detail::stage_route(*path)
          || !detail::capture::process(result->helper_pid_,result->helper_)
          || !detail::capture::process(result->core_pid_,result->core_)
          || result->helper_.pbi_uid!=0 || result->core_.pbi_uid!=0) {result->close();return nullptr;}
      result->path_=*path;result->stage_=detail::stage_hold::acquire(*path);
      if (!result->stage_ || !result->stage_->current()
          || !result->images_.capture(*result->stage_->publisher_) || !result->cleanup_current(fresh)) {result->close();return nullptr;}
      return result;
    } catch (...) {if (result) result->close();return nullptr;}
  }
  bool stage_current() {
    auto& stage=*stage_;
    if (stage.close_attempted_ || stage.close_refused_ || stage.count_!=stage.nodes_.size()) return false;
    for (size_t i=0;i<stage.count_;++i) {
      const auto& node=stage.nodes_[i];struct stat held{},named{};
      if (node.fd<0 || fstat(node.fd,&held)!=0 || !detail::publisher::detail::empty_acl(node.fd)) return false;
      const int status=i==0?lstat("/",&named):fstatat(stage.nodes_[i-1].fd,stage.names_[i].c_str(),&named,AT_SYMLINK_NOFOLLOW);
      if (status!=0) return false;
      if (i<4) {if (!admission_detail::same_directory(held,node.identity) || !admission_detail::same_directory(named,node.identity)) return false;}
      else if (!detail::publisher::detail::same(held,node.identity) || !detail::publisher::detail::same(named,node.identity)) return false;
    }
    return true;
  }
  bool helper_current() {
    proc_bsdinfo before{},after{};
    const auto leaf=detail::capture::live_leaf(helper_pid_,"com.ergoptiplus.app.runtime-installer",path_.c_str());
    return stage_ && stage_current() && detail::capture::process(helper_pid_,before)
        && detail::capture::same_birth(helper_,before) && leaf && *leaf==stage_->leaf()
        && detail::native_executable(helper_pid_)==std::optional<std::string>(path_)
        && detail::capture::process(helper_pid_,after) && detail::capture::same_birth(before,after) && stage_current();
  }
  bool cleanup_current(const detail::observation& fresh) noexcept {
    try {
      std::lock_guard<std::recursive_mutex> held(mutex_);
      if (closed_ || refused_ || !stage_ || !admission_detail::orientation(fresh,client_)
          || !admission_detail::same_observation(initial_,fresh) || !stage_->publisher_->custody_current() || !helper_current()) return false;
      proc_bsdinfo core_before{},core_after{};
      const auto core=detail::capture::live_leaf(core_pid_,"com.ergoptiplus.remap.core",admission_detail::core_path);
      const auto& approved=stage_->leaf();
      return detail::capture::process(core_pid_,core_before) && detail::capture::same_birth(core_,core_before)
          && core && *core==approved && fresh.self.leaf==approved && fresh.peer.leaf==approved
          && admission_detail::audit_image(fresh,client_?detail::publisher::role::core:detail::publisher::role::installer,
              client_?admission_detail::core_path:path_,approved)
          && detail::capture::process(core_pid_,core_after) && detail::capture::same_birth(core_before,core_after)
          && helper_current() && stage_->publisher_->custody_current();
    } catch (...) {return false;}
  }
  bool current(const detail::observation& fresh) noexcept {return cleanup_current(fresh);}
  bool retained_images_current_after_core_exit() noexcept {
    try {std::lock_guard<std::recursive_mutex> held(mutex_);return client_ && !closed_ && !refused_ && helper_current() && images_.current() && helper_current();}
    catch (...) {return false;}
  }
  bool close() noexcept {
    try {
      std::lock_guard<std::recursive_mutex> held(mutex_);
      if (!closed_) {closed_=true;if (stage_ && !stage_->release()) refused_=true;}
      if (!refused_) custody_.reset();return !refused_;
    } catch (...) {refused_=true;return false;}
  }
  bool retired() noexcept {std::lock_guard<std::recursive_mutex> held(mutex_);return closed_ && !refused_;}
  std::recursive_mutex mutex_;
  std::shared_ptr<staged_admission> custody_;
  std::shared_ptr<detail::stage_hold> stage_;
  admission_detail::retained_images images_;
  detail::observation initial_{};
  std::string path_;
  proc_bsdinfo helper_{},core_{};
  pid_t helper_pid_=0,core_pid_=0;
  bool client_=false,closed_=false,refused_=false;
};
} // namespace ergoptiplus::installed_maintenance
