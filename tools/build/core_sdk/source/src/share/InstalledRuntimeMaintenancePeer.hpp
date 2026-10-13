// Distinct native staged-helper observation for the retained Core maintenance socket.
// Identity is neither administrator consent nor installed/capture/cohort retirement.
#pragma once
#include "InstalledRuntimeProcessIdentity.hpp"
#include "InstalledRuntimeMaintenanceObservation.hpp"
#include <bsm/libbsm.h>
#include <sys/proc_info.h>
#include <array>
#include <mutex>
#include <stdexcept>

namespace ergoptiplus::installed_maintenance {
class staged_admission;
namespace detail {

namespace publisher = ergoptiplus::installed_publisher;
namespace capture = ergoptiplus::installed_capture::detail;

inline std::optional<std::string> native_executable(pid_t pid) {
  std::array<char, PROC_PIDPATHINFO_MAXSIZE> path{};
  const auto count = proc_pidpath(pid, path.data(), static_cast<uint32_t>(path.size()));
  if (count <= 0 || static_cast<size_t>(count) >= path.size() || path.front() != '/') return std::nullopt;
  const auto end = static_cast<const char*>(std::memchr(path.data(), '\0', path.size()));
  if (!end || end == path.data()) return std::nullopt;
  const auto length=static_cast<size_t>(end-path.data());
  if (static_cast<size_t>(count)!=length && static_cast<size_t>(count)!=length+1) return std::nullopt;
  return std::string(path.data(), static_cast<size_t>(end - path.data()));
}
inline bool stage_route(const std::string& path) {
  const std::string prefix = "/Library/Application Support/ErgoptiPlus/.runtime-installer-";
  const std::string suffix = "/Helper.app/Contents/MacOS/ErgoptiPlus-Runtime-Installer";
  if (path.size() != prefix.size() + 36 + suffix.size() || path.compare(0,prefix.size(),prefix) != 0
      || path.compare(prefix.size()+36,suffix.size(),suffix) != 0) return false;
  for (size_t offset=0; offset<36; ++offset) {
    const auto character=path[prefix.size()+offset];
    if (offset==8 || offset==13 || offset==18 || offset==23) { if (character!='-') return false; }
    else if (!((character>='0' && character<='9') || (character>='a' && character<='f') || (character>='A' && character<='F'))) return false;
  }
  return true;
}

// Published acquisition storage roots every native descriptor before effects.
// A refused close remains exact retained debt and is never retried blindly.
class stage_hold final : public std::enable_shared_from_this<stage_hold> {
  friend class ergoptiplus::installed_maintenance::staged_admission;
public:
  stage_hold(const stage_hold&)=delete;
  stage_hold& operator=(const stage_hold&)=delete;
  static std::shared_ptr<stage_hold> acquire(const std::string& native_path) noexcept {
    std::shared_ptr<stage_hold> result;
    try {
      if (!stage_route(native_path)) return nullptr;
      result=std::shared_ptr<stage_hold>(new stage_hold(native_path));
      result->custody_=result;
      result->publisher_=publisher::owner::acquire();
      if (!result->publisher_ || !result->anchor() || !result->current()) {
        result->release(); return nullptr;
      }
      return result;
    } catch (...) { if (result) result->release(); return nullptr; }
  }
  const std::vector<uint8_t>& leaf() const { return publisher_->observed_leaf(); }
  bool current() noexcept {
    try {
      std::lock_guard<std::recursive_mutex> held(mutex_);
      if (close_attempted_ || close_refused_ || !publisher_ || !publisher_->current() || count_!=nodes_.size()) return false;
      if (!tree_current()) return false;
      const auto helper=publisher::detail::path_leaf(path_.c_str(),publisher::role::installer);
      return helper && *helper==publisher_->observed_leaf() && publisher_->current() && tree_current();
    } catch (...) { return false; }
  }
  bool release() noexcept {
    try {
      std::lock_guard<std::recursive_mutex> held(mutex_);
      if (!close_attempted_) {
        close_attempted_=true;
        for (size_t index=count_; index>0; --index) {
          auto& node=nodes_[index-1];
          if (node.fd>=0 && close(node.fd)!=0) close_refused_=true;
          node.fd=-1;
        }
        if (publisher_ && !publisher_->release()) close_refused_=true;
      }
      if (!close_refused_) custody_.reset();
      return !close_refused_;
    } catch (...) { close_refused_=true; return false; }
  }
private:
  struct node { int fd=-1; struct stat identity{}; };
  explicit stage_hold(const std::string& path):path_(path) {
    names_[0]="/"; size_t offset=1,index=1;
    while (offset<path.size()) {
      const auto separator=path.find('/',offset);
      if (index>=names_.size()) throw std::invalid_argument("Native stage shape refused");
      names_[index++]=path.substr(offset,separator==std::string::npos ? std::string::npos : separator-offset);
      if (separator==std::string::npos) break;
      offset=separator+1;
    }
    if (index!=names_.size()) throw std::invalid_argument("Native stage shape refused");
  }
  bool tree_current() const {
    for (size_t index=0; index<count_; ++index) {
      const auto& node=nodes_[index]; struct stat held_node{}, named{};
      if (node.fd<0 || fstat(node.fd,&held_node)!=0 || !publisher::detail::same(node.identity,held_node)
          || !publisher::detail::empty_acl(node.fd)) return false;
      const int status=index==0 ? lstat("/",&named)
          : fstatat(nodes_[index-1].fd,names_[index].c_str(),&named,AT_SYMLINK_NOFOLLOW);
      if (status!=0 || !publisher::detail::same(node.identity,named)) return false;
    }
    return true;
  }
  bool anchor() {
    for (size_t index=0; index<nodes_.size(); ++index) {
      const bool last=index+1==nodes_.size();
      const int flags=O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK|(last?0:O_DIRECTORY);
      auto& node=nodes_[index];
      node.fd=index==0 ? open("/",flags) : openat(nodes_[index-1].fd,names_[index].c_str(),flags);
      if (node.fd<0) return false;
      count_=index+1; // Already rooted acquired descriptor before native checks.
      if (fstat(node.fd,&node.identity)!=0 || node.identity.st_uid!=0 || (node.identity.st_mode&06022)!=0
          || !publisher::detail::empty_acl(node.fd)) return false;
      if (last) {
        if (!S_ISREG(node.identity.st_mode) || node.identity.st_nlink!=1 || node.identity.st_size<=0
            || node.identity.st_size>268435456) return false;
      } else if (!S_ISDIR(node.identity.st_mode)) return false;
    }
    return true;
  }
  std::recursive_mutex mutex_;
  std::string path_;
  std::array<std::string,9> names_;
  std::array<node,9> nodes_;
  size_t count_=0;
  bool close_attempted_=false,close_refused_=false;
  std::unique_ptr<publisher::owner> publisher_;
  std::shared_ptr<stage_hold> custody_;
};

inline bool actual_guest(const observation& fresh,const std::string& executable,const std::vector<uint8_t>& expected) {
  capture::cf_owner<CFDataRef> token;
  *token.out()=CFDataCreate(nullptr,reinterpret_cast<const UInt8*>(&fresh.token),sizeof(fresh.token));
  if (!token.get()) return false;
  const void* key=kSecGuestAttributeAudit; const void* value=token.get();
  capture::cf_owner<CFDictionaryRef> attributes;
  *attributes.out()=CFDictionaryCreate(nullptr,&key,&value,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
  capture::cf_owner<SecCodeRef> live; capture::cf_owner<SecStaticCodeRef> code;
  if (!token.get() || !attributes.get()
      || SecCodeCopyGuestWithAttributes(nullptr,attributes.get(),kSecCSDefaultFlags,live.out())!=errSecSuccess
      || !live.get() || SecCodeCheckValidity(live.get(),kSecCSStrictValidate,nullptr)!=errSecSuccess
      || SecCodeCopyStaticCode(live.get(),kSecCSDefaultFlags,code.out())!=errSecSuccess || !code.get()) return false;
  const auto leaf=publisher::detail::leaf(code.get(),publisher::role::installer);
  capture::cf_owner<CFDictionaryRef> fields;
  if (!leaf || *leaf!=expected || *leaf!=fresh.peer.leaf
      || SecCodeCopySigningInformation(code.get(),kSecCSSigningInformation,fields.out())!=errSecSuccess || !fields.get()) return false;
  const auto main=CFDictionaryGetValue(fields.get(),kSecCodeInfoMainExecutable);
  std::array<UInt8,PROC_PIDPATHINFO_MAXSIZE> observed{};
  return main && CFGetTypeID(main)==CFURLGetTypeID()
      && CFURLGetFileSystemRepresentation(static_cast<CFURLRef>(main),true,observed.data(),observed.size())
      && executable==reinterpret_cast<const char*>(observed.data())
      && SecCodeCheckValidity(live.get(),kSecCSStrictValidate,nullptr)==errSecSuccess;
}
} // namespace detail

// Consumed ONLY by Core's distinct retained native maintenance socket sampler.
// Observation is freshly kernel-sampled under its original validation mutex;
// this predicate cannot mint consent, installation, capture or full settlement.
inline bool remote_staged_maintenance_matches(const detail::observation& fresh) noexcept {
  std::shared_ptr<detail::stage_hold> hold;
  bool admitted=false;
  try {
    namespace capture=ergoptiplus::installed_capture::detail;
    if (getuid()!=0 || geteuid()!=0 || fresh.euid!=0
        || fresh.self_euid!=0 || fresh.self_egid!=getegid()
        || fresh.self.identifier!="com.ergoptiplus.remap.core" || fresh.peer.identifier!="com.ergoptiplus.app.runtime-installer"
        || audit_token_to_pid(fresh.token)!=fresh.pid || audit_token_to_euid(fresh.token)!=fresh.euid
        || audit_token_to_egid(fresh.token)!=fresh.egid) return false;
    proc_bsdinfo peer_before{},self_before{},peer_after{},self_after{};
    const auto path=detail::native_executable(fresh.pid);
    if (!path || !capture::process(fresh.pid,peer_before) || peer_before.pbi_uid!=0 || peer_before.pbi_gid!=fresh.egid
        || !capture::process(getpid(),self_before) || self_before.pbi_uid!=0) return false;
    hold=detail::stage_hold::acquire(*path);
    const auto core=hold && hold->current() ? capture::live_leaf(getpid(),"com.ergoptiplus.remap.core",
        "/Library/Application Support/ErgoptiPlus/Runtime/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core") : std::nullopt;
    admitted=core && *core==hold->leaf() && *core==fresh.self.leaf && detail::actual_guest(fresh,*path,hold->leaf())
        && capture::process(fresh.pid,peer_after) && capture::same_birth(peer_before,peer_after)
        && capture::process(getpid(),self_after) && capture::same_birth(self_before,self_after)
        && detail::native_executable(fresh.pid)==path && hold->current();
  } catch (...) { admitted=false; }
  const bool released=hold && hold->release();
  return admitted && released;
}
} // namespace ergoptiplus::installed_maintenance
