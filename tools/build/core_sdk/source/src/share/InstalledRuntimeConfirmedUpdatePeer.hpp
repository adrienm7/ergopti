// Distinct native confirmed-update observation. A record is never an owner.
#pragma once
#include "InstalledRuntimeMaintenancePeer.hpp"
#include "InstalledRuntimeMaintenanceAdmission.hpp"
#include "InstalledRuntimeUpdateApprovalCodec.hpp"
#include <sys/sysctl.h>
#include <limits>

namespace ergoptiplus::installed_maintenance {
class confirmed_update_admission;
inline bool remote_confirmed_update_matches(const detail::observation&) noexcept;
namespace update_detail {
namespace publisher = ergoptiplus::installed_publisher;
namespace capture = ergoptiplus::installed_capture::detail;

inline bool invocation(pid_t pid, const std::string& executable) {
  std::array<int,3> query{CTL_KERN,KERN_PROCARGS2,pid};
  size_t length=0;
  if (sysctl(query.data(),query.size(),nullptr,&length,nullptr,0)!=0 || length<sizeof(int)+3 || length>131072) return false;
  std::vector<char> bytes(length);
  if (sysctl(query.data(),query.size(),bytes.data(),&length,nullptr,0)!=0 || length<sizeof(int)+3 || length>bytes.size()) return false;
  int count=0; std::memcpy(&count,bytes.data(),sizeof(count));
  if (count!=2) return false;
  size_t offset=sizeof(count);
  const auto string=[&]() -> std::optional<std::string> {
    if (offset>=length) return std::nullopt;
    const auto end=static_cast<const char*>(std::memchr(bytes.data()+offset,'\0',length-offset));
    if (!end) return std::nullopt;
    const size_t size=static_cast<size_t>(end-(bytes.data()+offset));
    std::string value(bytes.data()+offset,size); offset+=size+1; return value;
  };
  const auto native=string();
  if (!native || *native!=executable) return false;
  while (offset<length && bytes[offset]=='\0') ++offset;
  const auto first=string(), second=string();
  return first && second && *first==executable && *second=="--owned-update-installed-runtime";
}

inline std::string hex(const unsigned char* bytes,size_t size) {
  constexpr char digits[]="0123456789abcdef";
  std::string result(size*2,'\0');
  for (size_t i=0;i<size;++i) { result[2*i]=digits[bytes[i]>>4];result[2*i+1]=digits[bytes[i]&15]; }
  return result;
}
inline std::string leaf_hash(const std::vector<uint8_t>& leaf) {
  std::array<unsigned char,CC_SHA256_DIGEST_LENGTH> digest{};
  if (leaf.empty() || leaf.size()>std::numeric_limits<CC_LONG>::max()
      || !CC_SHA256(leaf.data(),static_cast<CC_LONG>(leaf.size()),digest.data())) return {};
  constexpr char alphabet[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string result; result.reserve(44);
  for (size_t first=0;first<digest.size();first+=3) {
    const size_t remaining=digest.size()-first;
    const uint32_t value=(uint32_t(digest[first])<<16)
        | (remaining>1?uint32_t(digest[first+1])<<8:0) | (remaining>2?digest[first+2]:0);
    result.push_back(alphabet[(value>>18)&63]);result.push_back(alphabet[(value>>12)&63]);
    result.push_back(remaining>1?alphabet[(value>>6)&63]:'=');result.push_back(remaining>2?alphabet[value&63]:'=');
  }
  return result;
}

// Same closed two-slice/path policy as the frozen native Swift publisher. This
// byte validator supplies no signature, consent, process or effect authority.
inline bool closed_executable(const std::string& bytes) {
  const auto word=[&](size_t at,bool little) -> std::optional<uint32_t> {
    if (at>bytes.size() || bytes.size()-at<4) return std::nullopt;
    uint32_t value=0;
    for (size_t i=0;i<4;++i) value=(value<<8)|static_cast<unsigned char>(bytes[at+(little?3-i:i)]);
    return value;
  };
  const auto wide=[&](size_t at,bool little) -> std::optional<uint64_t> {
    const auto a=word(at,little),b=word(at+4,little);
    if (!a || !b) return std::nullopt;
    return little ? (uint64_t(*b)<<32)|*a : (uint64_t(*a)<<32)|*b;
  };
  const auto path_allowed=[](const std::string& path,bool rpath) {
    if (path.empty() || path.front()!='/' || path.find("//")!=std::string::npos) return false;
    size_t at=1;
    while (at<path.size()) {
      auto end=path.find('/',at); if (end==std::string::npos) end=path.size();
      const auto part=path.substr(at,end-at); if (part=="." || part=="..") return false;at=end+1;
    }
    if (rpath) return path=="/usr/lib/swift" || path=="/System/Library/Frameworks";
    return path.compare(0,9,"/usr/lib/")==0 || path.compare(0,27,"/System/Library/Frameworks/")==0;
  };
  const auto thin=[&](size_t start,size_t size,uint32_t cpu) {
    if (size<32 || start>bytes.size() || size>bytes.size()-start) return false;
    const auto magic=word(start,false);
    if (!magic || (*magic!=0xcffaedfe && *magic!=0xfeedfacf)) return false;
    const bool little=*magic==0xcffaedfe;
    const auto commands=word(start+16,little),count=word(start+20,little);
    if (word(start+4,little)!=cpu || word(start+12,little)!=2 || !commands || *commands>128
        || !count || *count>65536 || *count>size-32) return false;
    size_t cursor=start+32,end=cursor+*count;
    for (uint32_t i=0;i<*commands;++i) {
      if (cursor>end || end-cursor<8) return false;
      const auto command=word(cursor,little),length=word(cursor+4,little);
      if (!command || !length || *length<8 || *length%8 || *length>end-cursor) return false;
      const bool load=*command==0xc || *command==0x80000018 || *command==0x8000001f || *command==0x80000023 || *command==0x20;
      if (load || *command==0x8000001c || *command==0xe) {
        const uint32_t minimum=load?24:12;
        const auto name=word(cursor+8,little);
        if (*length<minimum || !name || *name<minimum || *name>=*length) return false;
        const auto begin=bytes.data()+cursor+*name;
        const auto zero=static_cast<const char*>(std::memchr(begin,'\0',*length-*name));
        if (!zero || zero==begin) return false;
        std::string path(begin,static_cast<size_t>(zero-begin));
        if (*command==0xe) { if (path!="/usr/lib/dyld") return false; }
        else if (!path_allowed(path,*command==0x8000001c)) return false;
      } else {
        constexpr std::array<uint32_t,18> ordinary{0x19,0x2,0xb,0x1b,0x1d,0x26,0x29,0x32,0x24,0x80000022,
            0x22,0x80000028,0x80000033,0x80000034,0x1a,0x16,0x2a,0x2b};
        if (*command==0 || std::find(ordinary.begin(),ordinary.end(),*command)==ordinary.end()) return false;
      }
      cursor+=*length;
    }
    return cursor==end;
  };
  const auto magic=word(0,false);
  if (bytes.size()<48 || !magic || (*magic!=0xcafebabe && *magic!=0xcafebabf && *magic!=0xbebafeca && *magic!=0xbfbafeca)) return false;
  const bool little=*magic==0xbebafeca || *magic==0xbfbafeca, fat64=*magic==0xcafebabf || *magic==0xbfbafeca;
  if (word(4,little)!=2) return false;
  const size_t stride=fat64?32:20, header=8+2*stride;
  uint32_t first_cpu=0; size_t first_begin=0,first_end=0;
  for (size_t i=0;i<2;++i) {
    const size_t record=8+i*stride;
    const auto cpu=word(record,little);
    const auto offset=fat64?wide(record+8,little):std::optional<uint64_t>(word(record+8,little));
    const auto size=fat64?wide(record+16,little):std::optional<uint64_t>(word(record+12,little));
    if (!cpu || (*cpu!=0x01000007 && *cpu!=0x0100000c) || (i && *cpu==first_cpu)
        || !offset || !size || *offset<header || *offset>bytes.size() || *size>bytes.size()-*offset) return false;
    const size_t begin=static_cast<size_t>(*offset),end=begin+static_cast<size_t>(*size);
    if (i && begin<first_end && first_begin<end) return false;
    if (!thin(begin,static_cast<size_t>(*size),*cpu)) return false;
    if (!i) { first_cpu=*cpu;first_begin=begin;first_end=end; }
  }
  return true;
}

class approval_hold final : public std::enable_shared_from_this<approval_hold> {
  friend class ergoptiplus::installed_maintenance::confirmed_update_admission;
  friend bool ergoptiplus::installed_maintenance::remote_confirmed_update_matches(const detail::observation&) noexcept;
  struct node { int fd=-1;size_t parent=0;std::string name;struct stat identity{};bool census=false;std::vector<std::string> children; };
  approval_hold()=default;
  static std::shared_ptr<approval_hold> acquire(const detail::observation& fresh) {
    auto result=std::shared_ptr<approval_hold>(new approval_hold);
    result->custody_=result;
    try {
      result->old_=publisher::owner::acquire();
      const auto path=detail::native_executable(fresh.pid);
      if (!result->old_ || !path || !detail::stage_route(*path)) { result->release();return nullptr; }
      result->helper_=*path;
      result->stage_=path->substr(0,path->find("/Helper.app/"));
      result->bundle_=result->stage_+"/Helper.app";
      result->payload_=result->bundle_+"/Contents/Resources/OwnedRuntime";
      if (!result->anchor() || !result->read_journal() || !result->current(fresh)) { result->release();return nullptr; }
      return result;
    } catch (...) { result->release();return nullptr; }
  }
  bool release() noexcept {
    try {
      std::lock_guard<std::recursive_mutex> lock(mutex_);
      if (!close_attempted_) {
        close_attempted_=true;
        for (auto it=nodes_.rbegin();it!=nodes_.rend();++it) {
          const int fd=it->fd;it->fd=-1;if (fd>=0 && close(fd)!=0) close_refused_=true;
        }
        if (old_ && !old_->release()) close_refused_=true;
      }
      if (!close_refused_) custody_.reset();
      return !close_refused_;
    } catch (...) { close_refused_=true;return false; }
  }
  bool enroll(int fd,size_t parent,const std::string& name,bool directory) {
    if (fd<0) return false;
    publisher::detail::acquired_fd acquired(fd,close_refused_);
    struct stat value{};
    if (fstat(fd,&value)!=0 || value.st_uid!=0 || (value.st_mode&06022)!=0 || !publisher::detail::empty_acl(fd)
        || (directory?!S_ISDIR(value.st_mode):(!S_ISREG(value.st_mode) || value.st_nlink!=1 || value.st_size<=0 || value.st_size>268435456))) return false;
    nodes_.push_back({fd,parent,name,value,false,{}});acquired.release();return true;
  }
  bool walk(size_t parent) {
    const auto children=publisher::detail::names(nodes_[parent].fd,close_refused_);
    if (!children) return false;
    nodes_[parent].children=*children;nodes_[parent].census=true;
    for (const auto& name:*children) {
      if (nodes_.size()>=65536) return false;
      struct stat named{};
      if (fstatat(nodes_[parent].fd,name.c_str(),&named,AT_SYMLINK_NOFOLLOW)!=0 || (!S_ISDIR(named.st_mode) && !S_ISREG(named.st_mode))) return false;
      const bool directory=S_ISDIR(named.st_mode);
      if (!enroll(openat(nodes_[parent].fd,name.c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK|(directory?O_DIRECTORY:0)),parent,name,directory)
          || !publisher::detail::same(nodes_.back().identity,named)) return false;
      if (directory && !walk(nodes_.size()-1)) return false;
    }
    return true;
  }
  bool anchor() {
    if (!enroll(open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC),0,"",true)) return false;
    size_t parent=0;
    for (const char* name:{"Library","Application Support","ErgoptiPlus"}) {
      if (!enroll(openat(nodes_[parent].fd,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC),parent,name,true)) return false;
      parent=nodes_.size()-1;
    }
    root_=parent;
    if (!enroll(openat(nodes_[root_].fd,"Runtime",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC),root_,"Runtime",true)) return false;
    runtime_=nodes_.size()-1;
    const auto name=stage_.substr(stage_.find_last_of('/')+1);
    if (!enroll(openat(nodes_[root_].fd,name.c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC),root_,name,true)) return false;
    if (!walk(nodes_.size()-1)) return false;
    if (!enroll(openat(nodes_[root_].fd,".runtime-update-journal",O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK),root_,".runtime-update-journal",false)) return false;
    journal_=nodes_.size()-1;
    const auto& shape=nodes_[journal_].identity;
    return (shape.st_mode&07777)==0600 && shape.st_size<=8192;
  }
  bool whole(int fd,std::string& bytes) const {
    size_t offset=0;
    while (offset<bytes.size()) {
      const auto count=pread(fd,bytes.data()+offset,bytes.size()-offset,static_cast<off_t>(offset));
      if (count<0 && errno==EINTR) continue;
      if (count<=0) return false;offset+=static_cast<size_t>(count);
    }
    char tail=0;ssize_t count;
    do { count=pread(fd,&tail,1,static_cast<off_t>(bytes.size())); } while (count<0 && errno==EINTR);
    return count==0;
  }
  bool read_journal() {
    bytes_.resize(static_cast<size_t>(nodes_[journal_].identity.st_size));
    if (!whole(nodes_[journal_].fd,bytes_)) return false;
    record_=scalar_parser(bytes_).parse();return record_.has_value();
  }
  bool tree_current() {
    for (size_t i=0;i<nodes_.size();++i) {
      const auto& node=nodes_[i];struct stat held{},named{};
      if (node.fd<0 || fstat(node.fd,&held)!=0 || !publisher::detail::same(held,node.identity) || !publisher::detail::empty_acl(node.fd)) return false;
      const int status=i==0?lstat("/",&named):fstatat(nodes_[node.parent].fd,node.name.c_str(),&named,AT_SYMLINK_NOFOLLOW);
      if (status!=0 || !publisher::detail::same(named,node.identity)) return false;
      if (node.census) {
        const auto children=publisher::detail::names(node.fd,close_refused_);
        if (!children || *children!=node.children) return false;
      }
    }
    std::string actual(bytes_.size(),'\0');
    return whole(nodes_[journal_].fd,actual) && actual==bytes_ && !close_refused_;
  }
  bool guest(const detail::observation& fresh,std::vector<uint8_t>& leaf) {
    capture::cf_owner<CFDataRef> token;
    *token.out()=CFDataCreate(nullptr,reinterpret_cast<const UInt8*>(&fresh.token),sizeof(fresh.token));
    const void* key=kSecGuestAttributeAudit;const void* value=token.get();
    capture::cf_owner<CFDictionaryRef> attributes;
    if (!token.get()) return false;
    *attributes.out()=CFDictionaryCreate(nullptr,&key,&value,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    capture::cf_owner<SecCodeRef> live;capture::cf_owner<SecStaticCodeRef> code;
    if (!attributes.get() || SecCodeCopyGuestWithAttributes(nullptr,attributes.get(),kSecCSDefaultFlags,live.out())!=errSecSuccess
        || !live.get() || SecCodeCheckValidity(live.get(),kSecCSStrictValidate,nullptr)!=errSecSuccess
        || SecCodeCopyStaticCode(live.get(),kSecCSDefaultFlags,code.out())!=errSecSuccess || !code.get()) return false;
    const auto observed=publisher::detail::leaf(code.get(),publisher::role::installer);
    if (!observed || *observed!=fresh.peer.leaf || !detail::actual_guest(fresh,helper_,*observed)) return false;
    capture::cf_owner<CFDictionaryRef> fields;
    if (SecCodeCopySigningInformation(code.get(),kSecCSSigningInformation,fields.out())!=errSecSuccess || !fields.get()) return false;
    const auto raw=CFDictionaryGetValue(fields.get(),kSecCodeInfoCdHashes);
    if (!raw || CFGetTypeID(raw)!=CFArrayGetTypeID() || CFArrayGetCount(static_cast<CFArrayRef>(raw))!=2) return false;
    std::array<std::string,2> hashes;
    for (CFIndex i=0;i<2;++i) {
      const auto item=CFArrayGetValueAtIndex(static_cast<CFArrayRef>(raw),i);
      if (!item || CFGetTypeID(item)!=CFDataGetTypeID()) return false;
      const auto data=static_cast<CFDataRef>(item);const auto size=CFDataGetLength(data);
      if (size!=20 && size!=32) return false;
      hashes[static_cast<size_t>(i)]=hex(CFDataGetBytePtr(data),static_cast<size_t>(size));
    }
    std::sort(hashes.begin(),hashes.end());
    if (hashes[0]==hashes[1] || hashes[0]!=record_->text[6] || hashes[1]!=record_->text[7]) return false;
    leaf=*observed;return SecCodeCheckValidity(live.get(),kSecCSStrictValidate,nullptr)==errSecSuccess;
  }
  bool executable(const std::string& path,publisher::role role,const std::vector<uint8_t>& leaf) {
    std::string code_path=path;
    if (role==publisher::role::installer) code_path=bundle_;
    else if (role==publisher::role::core || role==publisher::role::console) {
      const auto macos=path.find("/Contents/MacOS/");
      if (macos==std::string::npos) return false;
      code_path=path.substr(0,macos);
    }
    const auto signature=publisher::detail::path_leaf(code_path.c_str(),role);
    if (!signature || *signature!=leaf) return false;
    // The entire staged tree is held. Find this exact native path in that tree.
    std::string relative=path.substr(stage_.size()+1);size_t parent=0;
    for (size_t i=0;i<nodes_.size();++i) {
      std::string observed=nodes_[i].name;size_t at=nodes_[i].parent;
      while (at>root_) { observed=nodes_[at].name+"/"+observed;at=nodes_[at].parent; }
      const std::string expected=stage_.substr(stage_.find_last_of('/')+1)+"/"+relative;
      if (observed!=expected) continue;
      parent=i;break;
    }
    if (parent<=root_ || !S_ISREG(nodes_[parent].identity.st_mode)) return false;
    std::string image(static_cast<size_t>(nodes_[parent].identity.st_size),'\0');
    return whole(nodes_[parent].fd,image) && closed_executable(image);
  }
  bool current(const detail::observation& fresh) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (close_attempted_ || close_refused_ || !record_ || !old_ || !old_->current() || !tree_current()) return false;
    const auto& r=*record_;
    proc_bsdinfo helper_before{},core_before{},helper_after{},core_after{};
    if (fresh.pid!=r.number[2] || getpid()!=r.number[8] || helper_!=r.text[5]
        || !capture::process(fresh.pid,helper_before) || helper_before.pbi_uid!=0 || helper_before.pbi_gid!=fresh.egid
        || helper_before.pbi_start_tvsec!=r.number[3] || helper_before.pbi_start_tvusec!=r.number[4]
        || !capture::process(getpid(),core_before) || core_before.pbi_uid!=0
        || core_before.pbi_start_tvsec!=r.number[9] || core_before.pbi_start_tvusec!=r.number[10]
        || static_cast<uint32_t>(nodes_[runtime_].identity.st_dev)!=r.number[13]
        || nodes_[runtime_].identity.st_ino!=r.number[14] || !invocation(fresh.pid,helper_)) return false;
    std::vector<uint8_t> new_leaf;
    const auto core=capture::live_leaf(getpid(),"com.ergoptiplus.remap.core",
        "/Library/Application Support/ErgoptiPlus/Runtime/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core");
    if (!core || *core!=old_->observed_leaf() || *core!=fresh.self.leaf || leaf_hash(*core)!=r.text[11]
        || !guest(fresh,new_leaf) || leaf_hash(new_leaf)!=r.text[12]
        || !executable(helper_,publisher::role::installer,new_leaf)
        || !executable(payload_+"/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core",publisher::role::core,new_leaf)
        || !executable(payload_+"/ErgoptiPlus-Remap-Console.app/Contents/MacOS/ErgoptiPlus-Remap-Console",publisher::role::console,new_leaf)
        || !executable(payload_+"/bin/ergoptiplus_remap_cli",publisher::role::cli,new_leaf)) return false;
    return capture::process(fresh.pid,helper_after) && capture::same_birth(helper_before,helper_after)
        && capture::process(getpid(),core_after) && capture::same_birth(core_before,core_after)
        && detail::native_executable(fresh.pid)==std::optional<std::string>(helper_) && invocation(fresh.pid,helper_)
        && old_->current() && tree_current();
  }
  std::recursive_mutex mutex_;
  std::vector<node> nodes_;
  std::unique_ptr<publisher::owner> old_;
  std::shared_ptr<approval_hold> custody_;
  std::optional<approval_record> record_;
  std::string bytes_,helper_,stage_,bundle_,payload_;
  size_t root_=0,runtime_=0,journal_=0;
  bool close_attempted_=false,close_refused_=false;
};
} // namespace update_detail

// Only the distinct Core retained native socket sampler consumes this predicate.
inline bool remote_confirmed_update_matches(const detail::observation& fresh) noexcept {
  std::shared_ptr<update_detail::approval_hold> held;
  bool admitted=false;
  try {
    if (getuid()!=0 || geteuid()!=0 || fresh.euid!=0 || fresh.self_euid!=0 || fresh.self_egid!=getegid()
        || fresh.self.identifier!="com.ergoptiplus.remap.core" || fresh.peer.identifier!="com.ergoptiplus.app.runtime-installer"
        || audit_token_to_pid(fresh.token)!=fresh.pid || audit_token_to_euid(fresh.token)!=fresh.euid
        || audit_token_to_egid(fresh.token)!=fresh.egid) return false;
    held=update_detail::approval_hold::acquire(fresh);
    admitted=held && held->current(fresh);
  } catch (...) { admitted=false; }
  const bool closed=held && held->release();
  return admitted && closed;
}

// Distinct original NEW staged helper + OLD installed publisher approval custody.
class confirmed_update_admission final : public std::enable_shared_from_this<confirmed_update_admission> {
  friend class maintenance_client;
  friend class core_endpoint;
  confirmed_update_admission()=default;
  static std::shared_ptr<confirmed_update_admission> acquire_client(const detail::observation& fresh) noexcept {return acquire(fresh,true);}
  static std::shared_ptr<confirmed_update_admission> acquire_core(const detail::observation& fresh) noexcept {return acquire(fresh,false);}
  static std::shared_ptr<confirmed_update_admission> acquire(const detail::observation& fresh,bool client) noexcept {
    std::shared_ptr<confirmed_update_admission> result;
    try {
      if (!admission_detail::orientation(fresh,client)) return nullptr;
      result=std::shared_ptr<confirmed_update_admission>(new confirmed_update_admission);result->custody_=result;
      result->client_=client;result->initial_=fresh;
      result->helper_pid_=client?getpid():fresh.pid;result->core_pid_=client?fresh.pid:getpid();
      if (!detail::capture::process(result->helper_pid_,result->helper_birth_)
          || !detail::capture::process(result->core_pid_,result->core_birth_)
          || result->helper_birth_.pbi_uid!=0 || result->core_birth_.pbi_uid!=0) {result->close();return nullptr;}
      const auto path=detail::native_executable(result->helper_pid_);
      if (!path || !detail::stage_route(*path)) {result->close();return nullptr;}
      result->hold_=std::shared_ptr<update_detail::approval_hold>(new update_detail::approval_hold);
      auto& hold=*result->hold_;hold.custody_=result->hold_;
      hold.old_=detail::publisher::owner::acquire();
      hold.helper_=*path;hold.stage_=path->substr(0,path->find("/Helper.app/"));
      hold.bundle_=hold.stage_+"/Helper.app";hold.payload_=hold.bundle_+"/Contents/Resources/OwnedRuntime";
      if (!hold.old_ || !hold.anchor() || !hold.read_journal() || !result->images_.capture(*hold.old_)
          || !result->cleanup_current(fresh)) {result->close();return nullptr;}
      return result;
    } catch (...) {if (result) result->close();return nullptr;}
  }
  bool retained_tree_current(bool after_exit) {
    auto& hold=*hold_;
    if (hold.close_attempted_ || hold.close_refused_ || !hold.record_) return false;
    for (size_t i=0;i<hold.nodes_.size();++i) {
      const auto& node=hold.nodes_[i];struct stat held{},named{};
      if (node.fd<0 || fstat(node.fd,&held)!=0 || !detail::publisher::detail::empty_acl(node.fd)) return false;
      if (after_exit && i==hold.runtime_) {
        if (!admission_detail::same_directory(held,node.identity)) return false;
        continue; // Original Runtime vnode remains held; never inspect or admit its replacement.
      }
      const int status=i==0?lstat("/",&named):fstatat(hold.nodes_[node.parent].fd,node.name.c_str(),&named,AT_SYMLINK_NOFOLLOW);
      if (status!=0) return false;
      if (i<=hold.root_) {
        if (!admission_detail::same_directory(held,node.identity) || !admission_detail::same_directory(named,node.identity)) return false;
      } else if (!detail::publisher::detail::same(held,node.identity) || !detail::publisher::detail::same(named,node.identity)) return false;
      if (node.census) {
        const auto children=detail::publisher::detail::names(node.fd,hold.close_refused_);
        if (!children || *children!=node.children) return false;
      }
    }
    std::string bytes(hold.bytes_.size(),'\0');
    return hold.whole(hold.nodes_[hold.journal_].fd,bytes) && bytes==hold.bytes_ && !hold.close_refused_;
  }
  bool helper_signature(std::vector<uint8_t>& leaf) {
    namespace capture=detail::capture;
    capture::cf_owner<CFNumberRef> pid;
    *pid.out()=CFNumberCreate(nullptr,kCFNumberIntType,&helper_pid_);
    const void* key=kSecGuestAttributePid;const void* value=pid.get();
    capture::cf_owner<CFDictionaryRef> attributes;
    if (!pid.get()) return false;
    *attributes.out()=CFDictionaryCreate(nullptr,&key,&value,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    capture::cf_owner<SecCodeRef> live;capture::cf_owner<SecStaticCodeRef> code;
    if (!attributes.get() || SecCodeCopyGuestWithAttributes(nullptr,attributes.get(),kSecCSDefaultFlags,live.out())!=errSecSuccess
        || !live.get() || SecCodeCheckValidity(live.get(),kSecCSStrictValidate,nullptr)!=errSecSuccess
        || SecCodeCopyStaticCode(live.get(),kSecCSDefaultFlags,code.out())!=errSecSuccess || !code.get()) return false;
    const auto actual=detail::publisher::detail::leaf(code.get(),detail::publisher::role::installer);
    capture::cf_owner<CFDictionaryRef> fields;
    if (!actual || SecCodeCopySigningInformation(code.get(),kSecCSSigningInformation,fields.out())!=errSecSuccess || !fields.get()) return false;
    const auto main=CFDictionaryGetValue(fields.get(),kSecCodeInfoMainExecutable);
    std::array<UInt8,PROC_PIDPATHINFO_MAXSIZE> path{};
    if (!main || CFGetTypeID(main)!=CFURLGetTypeID()
        || !CFURLGetFileSystemRepresentation(static_cast<CFURLRef>(main),true,path.data(),path.size())
        || hold_->helper_!=reinterpret_cast<const char*>(path.data())) return false;
    const auto raw=CFDictionaryGetValue(fields.get(),kSecCodeInfoCdHashes);
    if (!raw || CFGetTypeID(raw)!=CFArrayGetTypeID() || CFArrayGetCount(static_cast<CFArrayRef>(raw))!=2) return false;
    std::array<std::string,2> hashes;
    for (CFIndex i=0;i<2;++i) {
      const auto item=CFArrayGetValueAtIndex(static_cast<CFArrayRef>(raw),i);
      if (!item || CFGetTypeID(item)!=CFDataGetTypeID()) return false;
      const auto data=static_cast<CFDataRef>(item);const auto size=CFDataGetLength(data);
      if (size!=20 && size!=32) return false;
      hashes[static_cast<size_t>(i)]=update_detail::hex(CFDataGetBytePtr(data),static_cast<size_t>(size));
    }
    std::sort(hashes.begin(),hashes.end());const auto& record=*hold_->record_;
    if (hashes[0]==hashes[1] || hashes[0]!=record.text[6] || hashes[1]!=record.text[7]
        || update_detail::leaf_hash(*actual)!=record.text[12]) return false;
    leaf=*actual;return SecCodeCheckValidity(live.get(),kSecCSStrictValidate,nullptr)==errSecSuccess;
  }
  bool helper_current(bool after_exit) {
    auto& hold=*hold_;const auto& record=*hold.record_;
    proc_bsdinfo before{},after{};std::vector<uint8_t> leaf;
    if (!retained_tree_current(after_exit) || helper_pid_!=record.number[2] || hold.helper_!=record.text[5]
        || !detail::capture::process(helper_pid_,before) || !detail::capture::same_birth(helper_birth_,before)
        || before.pbi_uid!=0 || before.pbi_start_tvsec!=record.number[3] || before.pbi_start_tvusec!=record.number[4]
        || !update_detail::invocation(helper_pid_,hold.helper_) || !helper_signature(leaf)
        || !hold.executable(hold.helper_,detail::publisher::role::installer,leaf)
        || !hold.executable(hold.payload_+"/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core",detail::publisher::role::core,leaf)
        || !hold.executable(hold.payload_+"/ErgoptiPlus-Remap-Console.app/Contents/MacOS/ErgoptiPlus-Remap-Console",detail::publisher::role::console,leaf)
        || !hold.executable(hold.payload_+"/bin/ergoptiplus_remap_cli",detail::publisher::role::cli,leaf)) return false;
    if (!new_leaf_.empty() && leaf!=new_leaf_) return false;
    if (new_leaf_.empty()) new_leaf_=leaf;
    return detail::capture::process(helper_pid_,after) && detail::capture::same_birth(before,after)
        && detail::native_executable(helper_pid_)==std::optional<std::string>(hold.helper_)
        && update_detail::invocation(helper_pid_,hold.helper_) && retained_tree_current(after_exit);
  }
  bool cleanup_current(const detail::observation& fresh) noexcept {
    try {
      std::lock_guard<std::recursive_mutex> held(mutex_);
      if (closed_ || refused_ || !hold_ || !admission_detail::orientation(fresh,client_)
          || !admission_detail::same_observation(initial_,fresh) || !hold_->old_->custody_current() || !helper_current(false)) return false;
      const auto& record=*hold_->record_;const auto& old_leaf=hold_->old_->observed_leaf();
      proc_bsdinfo before{},after{};
      const auto core=detail::capture::live_leaf(core_pid_,"com.ergoptiplus.remap.core",admission_detail::core_path);
      return core_pid_==record.number[8] && detail::capture::process(core_pid_,before)
          && detail::capture::same_birth(core_birth_,before) && before.pbi_uid==0
          && before.pbi_start_tvsec==record.number[9] && before.pbi_start_tvusec==record.number[10]
          && static_cast<uint32_t>(hold_->nodes_[hold_->runtime_].identity.st_dev)==record.number[13]
          && hold_->nodes_[hold_->runtime_].identity.st_ino==record.number[14]
          && core && *core==old_leaf && update_detail::leaf_hash(old_leaf)==record.text[11]
          && fresh.self.leaf==(client_?new_leaf_:old_leaf) && fresh.peer.leaf==(client_?old_leaf:new_leaf_)
          && admission_detail::audit_image(fresh,client_?detail::publisher::role::core:detail::publisher::role::installer,
              client_?admission_detail::core_path:hold_->helper_,client_?old_leaf:new_leaf_)
          && detail::capture::process(core_pid_,after) && detail::capture::same_birth(before,after)
          && helper_current(false) && hold_->old_->custody_current();
    } catch (...) {return false;}
  }
  bool current(const detail::observation& fresh) noexcept {return cleanup_current(fresh);}
  bool retained_images_current_after_core_exit() noexcept {
    try {
      std::lock_guard<std::recursive_mutex> held(mutex_);
      return client_ && !closed_ && !refused_ && hold_ && helper_current(true) && images_.current() && helper_current(true);
    } catch (...) {return false;}
  }
  bool close() noexcept {
    try {
      std::lock_guard<std::recursive_mutex> held(mutex_);
      if (!closed_) {closed_=true;if (hold_ && !hold_->release()) refused_=true;}
      if (!refused_) custody_.reset();return !refused_;
    } catch (...) {refused_=true;return false;}
  }
  bool retired() noexcept {std::lock_guard<std::recursive_mutex> held(mutex_);return closed_ && !refused_;}
  std::recursive_mutex mutex_;
  std::shared_ptr<confirmed_update_admission> custody_;
  std::shared_ptr<update_detail::approval_hold> hold_;
  admission_detail::retained_images images_;
  detail::observation initial_{};
  proc_bsdinfo helper_birth_{},core_birth_{};
  std::vector<uint8_t> new_leaf_;
  pid_t helper_pid_=0,core_pid_=0;
  bool client_=false,closed_=false,refused_=false;
};
} // namespace ergoptiplus::installed_maintenance
