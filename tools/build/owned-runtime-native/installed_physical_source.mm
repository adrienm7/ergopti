// tools/build/owned-runtime-native/installed_physical_source.mm
// Native image/task custody for the fixed signed headless capture bridge.

#import <Foundation/Foundation.h>
#include <Security/Security.h>
#include "InstalledRuntimePublisher.hpp"
extern "C" {
#include <lua.h>
#include <lauxlib.h>
}
#include <dlfcn.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>

extern "C" int luaopen_ergopti_installed_source_native(lua_State *state);

namespace {
constexpr size_t chunk_limit = 4096;
constexpr size_t acknowledgement_limit = 65536;
constexpr const char *metatable_name = "ergopti.installed_source.native_owner";
NSString *const app_identifier = @"com.ergoptiplus.app";
NSString *const module_identifier = @"com.ergoptiplus.app.installed-physical-source";

NSData *signed_leaf(SecStaticCodeRef code, NSString *identifier) {
  const auto role = ergoptiplus::installed_publisher::closed_role(identifier.UTF8String);
  if (!role) return nil;
  const auto leaf = ergoptiplus::installed_publisher::detail::leaf(code, *role);
  return leaf ? [NSData dataWithBytes:leaf->data() length:leaf->size()] : nil;
}

NSData *path_leaf(NSString *path, NSString *identifier) {
  SecStaticCodeRef code = nullptr;
  if (SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:path], kSecCSDefaultFlags, &code) != errSecSuccess || !code) return nil;
  NSData *leaf = signed_leaf(code, identifier);
  CFRelease(code);
  return leaf;
}

bool process_identity(pid_t pid, proc_bsdinfo &identity) {
  return pid > 1 && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &identity, sizeof(identity)) == sizeof(identity)
      && identity.pbi_pid == (uint32_t)pid && identity.pbi_start_tvusec < 1000000;
}

bool same_birth(const proc_bsdinfo &left, const proc_bsdinfo &right) {
  return left.pbi_pid == right.pbi_pid && left.pbi_start_tvsec == right.pbi_start_tvsec
      && left.pbi_start_tvusec == right.pbi_start_tvusec && left.pbi_uid == right.pbi_uid;
}

NSData *live_leaf(pid_t pid, NSString *identifier, NSString *expected_path) {
  proc_bsdinfo before{}, after{};
  if (!process_identity(pid, before)) return nil;
  NSDictionary *attributes = @{ (__bridge NSString *)kSecGuestAttributePid: @(pid) };
  SecCodeRef live = nullptr;
  if (SecCodeCopyGuestWithAttributes(nullptr, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &live) != errSecSuccess || !live) return nil;
  SecStaticCodeRef code = nullptr;
  CFDictionaryRef information = nullptr;
  NSData *leaf = nil;
  if (SecCodeCheckValidity(live, kSecCSStrictValidate, nullptr) == errSecSuccess
      && SecCodeCopyStaticCode(live, kSecCSDefaultFlags, &code) == errSecSuccess && code
      && SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information) == errSecSuccess && information) {
    NSDictionary *fields = (__bridge NSDictionary *)information;
    NSURL *executable = fields[(__bridge NSString *)kSecCodeInfoMainExecutable];
    if ([executable isKindOfClass:[NSURL class]] && [executable.path isEqualToString:expected_path]) {
      leaf = signed_leaf(code, identifier);
    }
  }
  if (information) CFRelease(information);
  if (code) CFRelease(code);
  CFRelease(live);
  return process_identity(pid, after) && same_birth(before, after) ? leaf : nil;
}

bool same_file(const struct stat &left, const struct stat &right) {
  return left.st_dev == right.st_dev && left.st_ino == right.st_ino
      && left.st_mode == right.st_mode && left.st_uid == right.st_uid && left.st_gid == right.st_gid
      && left.st_size == right.st_size && left.st_nlink == right.st_nlink
      && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
      && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec;
}

bool nonblocking(int descriptor) {
  int flags = fcntl(descriptor, F_GETFL);
  return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0;
}
} // namespace

@interface ErgoptiInstalledSourceOwner : NSObject {
  std::unique_ptr<ergoptiplus::installed_publisher::owner> _publisher;
}
@property(nonatomic, strong) NSString *launcher;
@property(nonatomic, strong) NSString *outerBundle;
@property(nonatomic, strong) NSString *embeddedBundle;
@property(nonatomic, strong) NSString *module;
@property(nonatomic, strong) NSString *embeddedIdentifier;
@property(nonatomic, strong) NSData *leaf;
@property(nonatomic, strong) NSTask *task;
@property(nonatomic, strong) NSPipe *input;
@property(nonatomic, strong) NSPipe *output;
@property(nonatomic, strong) NSPipe *errors;
@property(nonatomic) int image;
@property(nonatomic) struct stat imageIdentity;
@property(nonatomic) struct proc_bsdinfo taskIdentity;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL finalRequested;
@property(nonatomic) BOOL imageCloseAttempted;
@property(nonatomic) BOOL imageCloseRefused;
@property(nonatomic) BOOL failed;
@property(nonatomic) BOOL closeAttempted;
@property(nonatomic) BOOL closeRefused;
+ (instancetype)acquire;
- (BOOL)current;
- (BOOL)streamCurrent;
- (BOOL)start;
- (void)requestStop;
- (BOOL)retired;
- (void)shutdown;
- (BOOL)closed;
@end

@implementation ErgoptiInstalledSourceOwner
+ (instancetype)acquire {
  if (getuid() == 0 || getuid() != geteuid()) return nil;
  auto publisher = ergoptiplus::installed_publisher::owner::acquire();
  if (!publisher) return nil;
  NSBundle *embedded = [NSBundle mainBundle];
  if (![embedded.bundleIdentifier isEqualToString:@"com.ergoptiplus.app.hammerspoon"]) return nil;
  NSString *suffix = @"/Contents/Frameworks/Hammerspoon.app";
  NSString *embeddedPath = embedded.bundlePath;
  if (![embeddedPath hasSuffix:suffix]) return nil;
  NSString *outerPath = [embeddedPath substringToIndex:embeddedPath.length - suffix.length];
  NSBundle *outer = [NSBundle bundleWithPath:outerPath];
  if (![outer.bundleIdentifier isEqualToString:app_identifier]) return nil;
  Dl_info moduleInformation{};
  if (dladdr((const void *)&luaopen_ergopti_installed_source_native, &moduleInformation) == 0 || !moduleInformation.dli_fname) return nil;
  NSString *module = [NSString stringWithUTF8String:moduleInformation.dli_fname];
  NSString *expectedModule = [outerPath stringByAppendingPathComponent:@"Contents/Resources/static/ergopti_plus/macos/adapters/native/installed_physical_source.so"];
  if (![module isEqualToString:expectedModule]) return nil;
  const auto& approved = publisher->observed_leaf();
  NSData *leaf = [NSData dataWithBytes:approved.data() length:approved.size()];
  if (!leaf || ![path_leaf(outerPath, app_identifier) isEqualToData:leaf]
      || ![path_leaf(embeddedPath, embedded.bundleIdentifier) isEqualToData:leaf]
      || ![path_leaf(module, module_identifier) isEqualToData:leaf]
      || ![live_leaf(getpid(), embedded.bundleIdentifier, embedded.executablePath) isEqualToData:leaf]) return nil;
  ErgoptiInstalledSourceOwner *owner = [[self alloc] init];
  owner.image = -1;
  owner->_publisher = std::move(publisher);
  owner.launcher = outer.executablePath; owner.outerBundle = outerPath;
  owner.embeddedBundle = embeddedPath; owner.embeddedIdentifier = embedded.bundleIdentifier;
  owner.module = module; owner.leaf = leaf;
  owner.image = open(owner.launcher.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK);
  if (owner.image < 0 || fstat(owner.image, &owner->_imageIdentity) != 0
      || !S_ISREG(owner->_imageIdentity.st_mode) || owner->_imageIdentity.st_nlink != 1 || ![owner current]) return nil;
  return owner;
}

- (BOOL)current {
  @synchronized(self) {
    if (_finalRequested || _failed || _imageCloseAttempted || _image < 0 || getuid() == 0 || getuid() != geteuid()
        || !_publisher || !_publisher->current()) return NO;
    struct stat held{}, named{};
    if (fstat(_image, &held) != 0 || lstat(_launcher.fileSystemRepresentation, &named) != 0
        || !same_file(held, _imageIdentity) || !same_file(named, _imageIdentity)
        || ![live_leaf(getpid(), _embeddedIdentifier, [NSBundle mainBundle].executablePath) isEqualToData:_leaf]
        || ![path_leaf(_outerBundle, app_identifier) isEqualToData:_leaf]
        || ![path_leaf(_module, module_identifier) isEqualToData:_leaf]) return NO;
    if (_started && !_stopping && !_closeAttempted) {
      proc_bsdinfo child{};
      if (!_task.running || !process_identity(_task.processIdentifier, child)
          || !same_birth(child, _taskIdentity) || child.pbi_ppid != (uint32_t)getpid()
          || ![live_leaf(_task.processIdentifier, app_identifier, _launcher) isEqualToData:_leaf]) return NO;
    }
    return _publisher->current();
  }
}

- (BOOL)streamCurrent {
  @synchronized(self) {
    if (_stopping || ![self current] || !_started) return NO;
    {
      proc_bsdinfo child{};
      if (!_task.running || !process_identity(_task.processIdentifier, child)
          || !same_birth(child, _taskIdentity) || child.pbi_ppid != (uint32_t)getpid()
          || ![live_leaf(_task.processIdentifier, app_identifier, _launcher) isEqualToData:_leaf]) return NO;
    }
    return YES;
  }
}

- (BOOL)start {
  @synchronized(self) {
    if (![self current]) return NO;
    if (_started) {
      if (![self retired]) return NO;
      _task = nil; _input = nil; _output = nil; _errors = nil;
      _started = NO; _stopping = NO; _closeAttempted = NO;
    }
    if (_stopping) return NO;
    _input = [NSPipe pipe]; _output = [NSPipe pipe]; _errors = [NSPipe pipe];
    _task = [[NSTask alloc] init];
    _task.executableURL = [NSURL fileURLWithPath:_launcher];
    _task.arguments = @[ @"--installed-physical-source" ];
    _task.standardInput = _input; _task.standardOutput = _output; _task.standardError = _errors;
    NSError *failure = nil;
    if (![_task launchAndReturnError:&failure]) { _failed = YES; [self requestStop]; return NO; }
    _started = YES;
    if (!process_identity(_task.processIdentifier, _taskIdentity)
        || !nonblocking(_input.fileHandleForWriting.fileDescriptor)
        || fcntl(_input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != 0
        || !nonblocking(_output.fileHandleForReading.fileDescriptor)
        || !nonblocking(_errors.fileHandleForReading.fileDescriptor) || ![self streamCurrent]) {
      _failed = YES; [self requestStop]; return NO;
    }
    return YES;
  }
}

- (void)requestStop {
  @synchronized(self) {
    if (_stopping) return;
    _stopping = YES;
    // SIGTERM is the source-owned bridge's cooperative native retirement request.
    // The NSTask instance owns the exact child, never a caller numeric PID.
    if (_started && _task.running) [_task terminate];
  }
}

- (BOOL)retired {
  @synchronized(self) {
    if (!_stopping) return NO;
    if (_started) {
      if (_task.running || _task.terminationReason != NSTaskTerminationReasonExit) return NO;
      int status = _task.terminationStatus;
      // These closed bridge outcomes settle child/socket/image custody in source.
      // Any uncontrolled death or explicit debt outcome remains unresolved.
      if (status != 0 && status != 74 && status != 77) return NO;
    }
    if (!_closeAttempted) {
      _closeAttempted = YES;
      @try {
        NSMutableArray<NSFileHandle *> *handles = [NSMutableArray array];
        if (_input) [handles addObjectsFromArray:@[_input.fileHandleForWriting, _input.fileHandleForReading]];
        if (_output) [handles addObjectsFromArray:@[_output.fileHandleForReading, _output.fileHandleForWriting]];
        if (_errors) [handles addObjectsFromArray:@[_errors.fileHandleForReading, _errors.fileHandleForWriting]];
        for (NSFileHandle *handle in handles) {
          if (handle.fileDescriptor >= 0) {
            NSError *failure = nil;
            if (![handle closeAndReturnError:&failure]) _closeRefused = YES;
          }
        }
      } @catch (NSException *) { _closeRefused = YES; }
    }
    return !_closeRefused;
  }
}

- (void)shutdown {
  @synchronized(self) {
    _finalRequested = YES;
    [self requestStop];
  }
}

- (BOOL)closed {
  @synchronized(self) {
    if (!_finalRequested || ![self retired]) return NO;
    if (!_imageCloseAttempted) {
      _imageCloseAttempted = YES;
      if (_image >= 0) {
        if (close(_image) != 0) _imageCloseRefused = YES;
        _image = -1;
      }
      if (!_publisher || !_publisher->release()) _imageCloseRefused = YES;
    }
    return !_imageCloseRefused;
  }
}

- (void)dealloc {
  // Acquired-but-unstarted objects own no child. Live/debt objects are retained
  // by the native registry and are not destroyed by a Lua GC acknowledgement.
  if (!_started && _image >= 0) close(_image);
}
@end

namespace {
std::unordered_map<void *, ErgoptiInstalledSourceOwner *> registry;
ErgoptiInstalledSourceOwner *active_owner = nil;

ErgoptiInstalledSourceOwner *owner_at(lua_State *state, int count = 1) {
  if (lua_gettop(state) != count) { luaL_error(state, "Invalid installed source method arguments"); return nil; }
  void *address = lua_touserdata(state, 1);
  auto found = registry.find(address);
  if (!address || found == registry.end() || lua_rawlen(state, 1) != sizeof(void *)) return nil;
  luaL_checkudata(state, 1, metatable_name);
  return found->second;
}

int acquire(lua_State *state) {
  if (lua_gettop(state) != 0) return luaL_error(state, "Installed source acquisition accepts no arguments");
  if (active_owner && ![active_owner closed]) { lua_pushnil(state); return 1; }
  ErgoptiInstalledSourceOwner *owner = nil;
  try {
    owner = [ErgoptiInstalledSourceOwner acquire];
    if (!owner) { lua_pushnil(state); return 1; }
    // Retain native custody before allocation can refuse the public registry entry.
    active_owner = owner;
    void *address = lua_newuserdatauv(state, sizeof(void *), 0);
    registry.emplace(address, owner);
    luaL_setmetatable(state, metatable_name);
    return 1;
  } catch (...) {
    if (owner) { active_owner = owner; [owner shutdown]; }
    lua_pushnil(state); return 1;
  }
}

int owns(lua_State *state) { lua_pushboolean(state, owner_at(state) != nil); return 1; }

int current(lua_State *state) { lua_pushboolean(state, [owner_at(state) current]); return 1; }
int start(lua_State *state) { lua_pushboolean(state, [owner_at(state) start]); return 1; }
int request_stop(lua_State *state) { [owner_at(state) requestStop]; return 0; }
int retired(lua_State *state) { lua_pushboolean(state, [owner_at(state) retired]); return 1; }
int shutdown(lua_State *state) { [owner_at(state) shutdown]; return 0; }
int closed(lua_State *state) { lua_pushboolean(state, [owner_at(state) closed]); return 1; }

int read_chunk(lua_State *state) {
  ErgoptiInstalledSourceOwner *owner = owner_at(state);
  if (![owner streamCurrent]) { lua_pushnil(state); return 1; }
  char error[chunk_limit];
  ssize_t errorCount = read(owner.errors.fileHandleForReading.fileDescriptor, error, sizeof(error));
  if (errorCount > 0 || (errorCount < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
    owner.failed = YES; [owner requestStop]; lua_pushnil(state); return 1;
  }
  char bytes[chunk_limit];
  ssize_t count = read(owner.output.fileHandleForReading.fileDescriptor, bytes, sizeof(bytes));
  if (count > 0 && [owner streamCurrent]) lua_pushlstring(state, bytes, (size_t)count);
  else if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) lua_pushliteral(state, "");
  else { owner.failed = YES; [owner requestStop]; lua_pushnil(state); }
  return 1;
}

int write_acknowledgement(lua_State *state) {
  ErgoptiInstalledSourceOwner *owner = owner_at(state, 2);
  size_t length = 0;
  const char *bytes = luaL_checklstring(state, 2, &length);
  if (![owner streamCurrent] || length == 0 || length > acknowledgement_limit) { lua_pushnil(state); return 1; }
  ssize_t count = write(owner.input.fileHandleForWriting.fileDescriptor, bytes, length);
  if (count >= 0 && [owner streamCurrent]) lua_pushinteger(state, count);
  else if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) lua_pushinteger(state, 0);
  else { owner.failed = YES; [owner requestStop]; lua_pushnil(state); }
  return 1;
}

// Native completion is an observation. Only retired() acknowledges closed custody.
int completion(lua_State *state) {
  ErgoptiInstalledSourceOwner *owner = owner_at(state);
  if (!owner || !owner.started || owner.task.running) { lua_pushnil(state); return 1; }
  int status = owner.task.terminationStatus;
  lua_pushinteger(state, owner.task.terminationReason == NSTaskTerminationReasonExit ? status : 128 + status);
  return 1;
}

// This original host epoch is the producer's mach_absolute_time domain.
// Neither a Lua receipt nor a delivery-time timestamp supplies the timebase.
int clock_information(lua_State *state) {
  ErgoptiInstalledSourceOwner *owner = owner_at(state);
  mach_timebase_info_data_t information{};
  if (![owner current] || mach_timebase_info(&information) != KERN_SUCCESS
      || information.numer == 0 || information.denom == 0 || ![owner current]) {
    lua_pushnil(state); return 1;
  }
  lua_newtable(state);
  lua_pushinteger(state, 1); lua_setfield(state, -2, "version");
  lua_pushliteral(state, "mach_absolute_time"); lua_setfield(state, -2, "domain");
  lua_pushinteger(state, information.numer); lua_setfield(state, -2, "numer");
  lua_pushinteger(state, information.denom); lua_setfield(state, -2, "denom");
  return 1;
}

int collect(lua_State *state) {
  void *address = lua_touserdata(state, 1);
  auto found = registry.find(address);
  if (found != registry.end()) { [found->second shutdown]; registry.erase(found); }
  return 0;
}
} // namespace

extern "C" int luaopen_ergopti_installed_source_native(lua_State *state) {
  if (lua_version(state) != 504) return luaL_error(state, "Installed native source requires the original Lua 5.4 ABI");
  luaL_newmetatable(state, metatable_name);
  lua_pushcfunction(state, collect); lua_setfield(state, -2, "__gc");
  lua_newtable(state);
  const luaL_Reg methods[] = {{"current", current}, {"start", start}, {"read", read_chunk},
      {"write", write_acknowledgement}, {"request_stop", request_stop}, {"retired", retired},
      {"completion", completion}, {"clock", clock_information}, {"shutdown", shutdown}, {"closed", closed}, {nullptr, nullptr}};
  luaL_setfuncs(state, methods, 0); lua_setfield(state, -2, "__index"); lua_pop(state, 1);
  lua_newtable(state);
  luaL_setfuncs(state, methods, 0);
  lua_pushcfunction(state, owns); lua_setfield(state, -2, "owns");
  lua_pushcfunction(state, acquire); lua_setfield(state, -2, "acquire");
  return 1;
}
