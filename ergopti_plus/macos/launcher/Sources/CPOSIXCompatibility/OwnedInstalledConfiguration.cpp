// Normal-launcher C ABI consumes the canonical native configuration policy.
#include "include/OwnedInstalledConfiguration.h"
#include "../../../../../../tools/build/InstalledUserConfiguration.hpp"
#include <unordered_map>

struct ergopti_owned_configuration {
  std::shared_ptr<ergoptiplus::installed_configuration::owner> native;
};
namespace {
std::recursive_mutex registry_mutex;
std::unordered_map<ergopti_owned_configuration*, std::unique_ptr<ergopti_owned_configuration>> registry;
ergopti_owned_configuration* original(ergopti_owned_configuration* value) {
  auto found = registry.find(value);
  return found == registry.end() || !found->second->native ? nullptr : found->second.get();
}
}

extern "C" ergopti_owned_configuration* ergopti_owned_configuration_acquire(void) {
  ergopti_owned_configuration* key = nullptr;
  try {
    std::lock_guard<std::recursive_mutex> held(registry_mutex);
    auto storage = std::make_unique<ergopti_owned_configuration>();
    key = storage.get();
    // Registry/control allocations precede every native descriptor acquisition.
    registry.emplace(key, std::move(storage));
    // Exact stored construction slot, still unpublished; admitted lookup rightly refuses it.
    auto token = key;
    token->native = ergoptiplus::installed_configuration::owner::acquire_launcher();
    if (!token->native) { registry.erase(key); return nullptr; }
    return key;
  } catch (...) {
    // Any actual native custody is rooted in the registry or canonical holder.
    return nullptr;
  }
}
extern "C" int ergopti_owned_configuration_observe_route(ergopti_owned_configuration* value, ergopti_owned_configuration_route* output) {
  try {
    std::lock_guard<std::recursive_mutex> held(registry_mutex);
    auto token = original(value);
    if (!token || !output || !token->native->namespace_current()) return 0;
    *output = {token->native->root().c_str(), token->native->generation(), token->native->uid(), token->native->creating_pid()};
    return token->native->namespace_current() ? 1 : 0;
  } catch (...) { return 0; }
}
extern "C" int ergopti_owned_configuration_capture(ergopti_owned_configuration* value) {
  try { std::lock_guard<std::recursive_mutex> held(registry_mutex); auto token = original(value); return token && token->native->capture_publication() ? 1 : 0; }
  catch (...) { return 0; }
}
extern "C" int ergopti_owned_configuration_current(ergopti_owned_configuration* value) {
  try { std::lock_guard<std::recursive_mutex> held(registry_mutex); auto token = original(value); return token && token->native->file_current() ? 1 : 0; }
  catch (...) { return 0; }
}
extern "C" int ergopti_owned_configuration_namespace_current(ergopti_owned_configuration* value) {
  try { std::lock_guard<std::recursive_mutex> held(registry_mutex); auto token = original(value); return token && token->native->namespace_current() ? 1 : 0; }
  catch (...) { return 0; }
}
extern "C" int ergopti_owned_configuration_release(ergopti_owned_configuration* value) {
  try { std::lock_guard<std::recursive_mutex> held(registry_mutex); auto token = original(value); return token && token->native->release() ? 1 : 0; }
  catch (...) { return 0; }
}
extern "C" int ergopti_owned_configuration_retired(ergopti_owned_configuration* value) {
  try { std::lock_guard<std::recursive_mutex> held(registry_mutex); auto token = original(value); return token && token->native->retired() ? 1 : 0; }
  catch (...) { return 0; }
}
extern "C" int ergopti_owned_configuration_destroy(ergopti_owned_configuration* value) {
  try {
    std::lock_guard<std::recursive_mutex> held(registry_mutex);
    auto token = original(value);
    if (!token || !token->native->retired()) return 0;
    // Stable token storage is a permanent tombstone: stale raw pointers cannot alias successors.
    token->native.reset(); return 1;
  } catch (...) { return 0; }
}
