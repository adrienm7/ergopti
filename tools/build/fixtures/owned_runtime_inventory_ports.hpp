// Bounded modeled native ports for the actual assembled producer's portable tests.
// These ports qualify no Darwin queue, physical device, enumeration or framework.
#pragma once
#include <cstdint>
#include <algorithm>
#include <chrono>
#include <deque>
#include <map>
#include <unordered_map>
#include <Block.h>
#include <cstring>
#include <functional>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <vector>
namespace producer_ports {
inline std::uint64_t clock = 100;
inline unsigned cached_reads = 0, updated_reads = 0, releases = 0;
inline bool allocation_refused = false;
struct element { unsigned page, usage, cookie; bool relative = false, array = false; };
struct value { element* leaf; std::int64_t integer; std::uint64_t timestamp; };
struct device {
  std::uint64_t identity = 41;
  std::int64_t keyboard_type = 40;
  std::vector<element*> elements;
  std::vector<value> baseline;
  bool enumerated = true, identity_available = true;
};
}
using IOHIDDeviceRef = producer_ports::device*;
using IOHIDElementRef = producer_ports::element*;
using IOHIDValueRef = producer_ports::value*;
using io_service_t = IOHIDDeviceRef;
using CFTypeRef = const void*;
using CFNumberRef = const std::int64_t*;
using CFDataRef = const std::vector<std::uint8_t>*;
using CFArrayRef = const std::vector<IOHIDElementRef>*;
using CFIndex = long;
using IOOptionBits = unsigned;
struct CFRange { CFIndex location, length; };
inline constexpr unsigned kIOHIDOptionsTypeNone = 0, kIOHIDDeviceGetValueWithoutUpdate = 0;
inline constexpr unsigned kIOHIDDeviceGetValueWithUpdate = 1;
inline constexpr unsigned kIOHIDElementTypeInput_Misc = 1, kIOHIDElementTypeInput_ScanCodes = 4;
inline constexpr int kIOReturnSuccess = 0, KERN_SUCCESS = 0, kCFNumberSInt64Type = 0;
inline constexpr const void* kCFAllocatorDefault = nullptr;
#define CFSTR(value) value
#define kIOHIDSubinterfaceIDKey "SubinterfaceID"
#define kIOHIDReportDescriptorKey "ReportDescriptor"
inline std::uint64_t mach_absolute_time() { return ++producer_ports::clock; }
inline io_service_t IOHIDDeviceGetService(IOHIDDeviceRef device) { return device; }
inline int IORegistryEntryGetRegistryEntryID(io_service_t device, std::uint64_t* identity) {
  if (!device->identity_available) return 1;
  *identity = device->identity; return 0;
}
inline CFTypeRef IORegistryEntryCreateCFProperty(io_service_t device, const char*, const void*, int) {
  return &device->keyboard_type;
}
inline unsigned CFGetTypeID(CFTypeRef) { return 1; }
inline unsigned CFNumberGetTypeID() { return 1; }
inline bool CFNumberIsFloatType(CFNumberRef) { return false; }
inline bool CFNumberGetValue(CFNumberRef number, int, std::int64_t* output) { *output = *number; return true; }
inline CFArrayRef IOHIDDeviceCopyMatchingElements(IOHIDDeviceRef device, const void*, unsigned) {
  if (producer_ports::allocation_refused) throw std::bad_alloc();
  return device->enumerated ? &device->elements : nullptr;
}
inline CFIndex CFArrayGetCount(CFArrayRef array) { return array->size(); }
inline const void* CFArrayGetValueAtIndex(CFArrayRef array, CFIndex index) { return array->at(index); }
inline void CFRelease(const void*) { ++producer_ports::releases; }
inline unsigned IOHIDElementGetUsagePage(IOHIDElementRef element) { return element->page; }
inline unsigned IOHIDElementGetUsage(IOHIDElementRef element) { return element->usage; }
inline unsigned IOHIDElementGetCookie(IOHIDElementRef element) { return element->cookie; }
inline unsigned IOHIDElementGetType(IOHIDElementRef) { return 2; }
inline bool IOHIDElementIsRelative(IOHIDElementRef element) { return element->relative; }
inline bool IOHIDElementIsArray(IOHIDElementRef element) { return element->array; }
inline unsigned IOHIDElementGetReportSize(IOHIDElementRef) { return 1; }
inline unsigned IOHIDElementGetReportCount(IOHIDElementRef) { return 1; }
inline std::int64_t IOHIDElementGetLogicalMin(IOHIDElementRef) { return 0; }
inline std::int64_t IOHIDElementGetLogicalMax(IOHIDElementRef) { return 1; }
inline int IOHIDDeviceGetValueWithOptions(IOHIDDeviceRef device, IOHIDElementRef leaf,
                                         IOHIDValueRef* output, unsigned options) {
  options ? ++producer_ports::updated_reads : ++producer_ports::cached_reads;
  for (auto& value : device->baseline) if (value.leaf == leaf) { *output = &value; return 0; }
  *output = nullptr; return 1;
}
inline IOHIDElementRef IOHIDValueGetElement(IOHIDValueRef value) { return value->leaf; }
inline std::int64_t IOHIDValueGetIntegerValue(IOHIDValueRef value) { return value->integer; }
inline std::uint64_t IOHIDValueGetTimeStamp(IOHIDValueRef value) { return value->timestamp; }
inline CFTypeRef IOHIDDeviceGetProperty(IOHIDDeviceRef, const char*) { return nullptr; }
inline unsigned CFDataGetTypeID() { return 2; }
inline CFIndex CFDataGetLength(CFDataRef data) { return data->size(); }
inline CFRange CFRangeMake(CFIndex offset, CFIndex size) { return {offset, size}; }
inline void CFDataGetBytes(CFDataRef data, CFRange range, std::uint8_t* output) {
  std::memcpy(output, data->data() + range.location, range.length);
}
using uuid_t = unsigned char[16];
inline void uuid_generate(uuid_t value) { static unsigned next = 1; std::memset(value, 0, 16); value[0] = next++; }
inline void uuid_unparse_lower(const uuid_t, char* output) { std::strcpy(output, "modeled-producer-incarnation"); }
namespace nod {
template <typename> class signal;
template <typename... Arguments> class signal<void(Arguments...)> {
  std::vector<std::function<void(Arguments...)>> callbacks;
public:
  template <typename Callback> void connect(Callback callback) { callbacks.emplace_back(callback); }
  void operator()(Arguments... arguments) { for (auto& callback : callbacks) callback(arguments...); }
};
}
#include <type_safe/strong_typedef.hpp>
#include "actual_pqrs_gsl.hpp"
namespace type_safe {
inline std::uint64_t get(std::uint64_t value) { return value; }
inline const std::string& get(const std::string& value) { return value; }
}
namespace pqrs {

namespace cf { class run_loop_thread; }
namespace dispatcher {
using duration = std::chrono::milliseconds;
struct dispatcher {};
struct task { duration when; unsigned sequence; std::weak_ptr<bool> live; std::function<void()> callback; };
inline duration now{};
inline unsigned sequence = 0;
inline std::vector<task> tasks;
inline void pump(duration until) {
  while (true) {
    auto it = std::min_element(tasks.begin(), tasks.end(), [](const auto& a, const auto& b) {
      return a.when < b.when || (a.when == b.when && a.sequence < b.sequence);
    });
    if (it == tasks.end() || it->when > until) break;
    auto next = std::move(*it); tasks.erase(it); now = next.when;
    if (const auto live = next.live.lock(); live && *live) next.callback();
  }
  now = until;
}
namespace extra {
class dispatcher_client {
  std::shared_ptr<bool> live_ = std::make_shared<bool>(true);
public:
  std::weak_ptr<dispatcher> weak_dispatcher_;
  explicit dispatcher_client(std::weak_ptr<dispatcher> weak = {}) : weak_dispatcher_(weak) {}
  virtual ~dispatcher_client() { *live_ = false; }
  duration when_now() const { return now; }
  template <typename Callback> void enqueue_to_dispatcher(Callback callback, duration when = now) {
    tasks.push_back({when, ++sequence, live_, std::move(callback)});
  }
  template <typename Callback> void detach_from_dispatcher(Callback callback) { *live_ = false; callback(); }
  struct wait { std::function<void()> drain; void notify() {} void wait_notice() { drain(); } };
  std::shared_ptr<wait> make_thread_wait();
};
}
class extra_timer {
public:
  inline static std::vector<extra_timer*> instances;
  template <typename Client> explicit extra_timer(Client&) { instances.push_back(this); }
  ~extra_timer() { std::erase(instances, this); }
  template <typename Callback> void start(Callback callback, duration cadence) {
    callback_ = std::move(callback); cadence_ = cadence;
  }
  void stop() { callback_ = {}; }
  void fire() { if (callback_) callback_(); }
  duration cadence_{};
  std::function<void()> callback_;
};
namespace extra { using timer = extra_timer; }
}
namespace cf {
class run_loop_thread {
public:
  inline static std::deque<void (^)(void)> blocks;
  void enqueue(void (^block)(void)) { blocks.push_back(static_cast<void (^)(void)>(Block_copy(block))); }
  static void pump() {
    while (!blocks.empty()) { auto block = blocks.front(); blocks.pop_front(); block(); Block_release(block); }
  }
  void add_source(void*) {}
  void remove_source(void*) {}
};
}
inline std::shared_ptr<dispatcher::extra::dispatcher_client::wait>
dispatcher::extra::dispatcher_client::make_thread_wait() {
  return std::make_shared<wait>(wait{[] { cf::run_loop_thread::pump(); }});
}
} // namespace pqrs

namespace pqrs {
namespace osx {
namespace chrono { using absolute_time_point = std::uint64_t; }
using iokit_return = int;
class iokit_hid_value {
  producer_ports::value value_;
public:
  explicit iokit_hid_value(IOHIDValueRef value) : value_(*value) {}
  std::optional<unsigned> get_usage_page() const { return value_.leaf->page; }
  std::optional<unsigned> get_usage() const { return value_.leaf->usage; }
  std::int64_t get_integer_value() const { return value_.integer; }
  std::uint64_t get_time_stamp() const { return value_.timestamp; }
  void set_time_stamp(std::uint64_t timestamp) { value_.timestamp = timestamp; }
};
struct borrowed_value { IOHIDValueRef pointer; IOHIDValueRef operator*() const { return pointer; } };
class iokit_hid_device_events_monitor {
public:
  struct parameters {
    bool observe_input_reports = false;
    std::function<void()> input_report_filter_started;
    std::function<bool(unsigned, std::span<const std::uint8_t>)> input_report_filter;
  };
  nod::signal<void()> started, stopped;
  nod::signal<void(std::shared_ptr<std::vector<borrowed_value>>)> input_values_arrived;
  nod::signal<void(unsigned, std::span<const std::uint8_t>, std::uint64_t)> input_report_arrived;
  nod::signal<void(const std::string&, int)> error_occurred;
  inline static iokit_hid_device_events_monitor* current = nullptr;
  iokit_hid_device_events_monitor(std::weak_ptr<pqrs::dispatcher::dispatcher>,
      std::shared_ptr<pqrs::cf::run_loop_thread>, IOHIDDeviceRef, parameters) { current = this; }
  ~iokit_hid_device_events_monitor() { current = nullptr; }
  void async_start(IOOptionBits, std::chrono::milliseconds) { started(); }
  void async_stop() { stopped(); }
  bool seized() const { return false; }
  void deliver(std::vector<producer_ports::value>& values) {
    auto wrapped = std::make_shared<std::vector<borrowed_value>>();
    for (auto& value : values) wrapped->push_back({&value});
    input_values_arrived(wrapped);
  }
};
}
}
#include "actual_registry_identity.hpp"
#include "actual_device_id.hpp"
namespace krbn {
struct device_identifiers { bool virtual_device = false; bool get_is_virtual_device() const { return virtual_device; } };
struct device_properties {
  pqrs::osx::iokit_registry_entry_id::value_t identity;
  std::string product;
  device_identifiers identifiers;
  auto get_device_id() const { return identity; }
  auto get_product() const { return product; }
  const auto& get_device_identifiers() const { return identifiers; }
};
namespace hid_report_only_events {
inline bool is_target_device(const device_identifiers&) { return false; }
struct report_handler {
  void reset_filter_state() {}
  void reset() {}
  template <typename... T> bool should_accept_report(T...) { return false; }
  template <typename... T> std::vector<pqrs::osx::iokit_hid_value> handle(T...) { return {}; }
};
template <typename... T> std::shared_ptr<report_handler> make_report_handler(T...) { return {}; }
}
}

namespace inventory_ports {
struct dictionary { unsigned index; };
struct iterator { std::vector<IOHIDDeviceRef> services; std::size_t cursor = 0; bool valid = true, invalidate_on_exhaustion = false; };
struct notification_port { bool destroyed = false; unsigned index; };
struct watcher {
  std::vector<IOHIDDeviceRef> initial, terminated;
  bool port_ok = true, source_ok = true, match_ok = true, terminate_ok = true, iterator_valid = true, invalidate_on_exhaustion = false, scan_ok = true;
  void (*matched_callback)(void*, std::uintptr_t) = nullptr;
  void (*terminated_callback)(void*, std::uintptr_t) = nullptr;
  void* refcon = nullptr;
};
inline std::array<watcher, 7> watchers;
inline std::vector<std::unique_ptr<iterator>> iterators;
inline std::vector<std::unique_ptr<notification_port>> ports;
inline std::unordered_map<IOHIDDeviceRef, bool> create_failures;
inline unsigned next_port = 0;
inline unsigned destroys = 0;
inline void quiesce() { do { pqrs::cf::run_loop_thread::pump(); pqrs::dispatcher::pump(pqrs::dispatcher::now); } while (!pqrs::cf::run_loop_thread::blocks.empty()); }
}
using CFDictionaryRef = inventory_ports::dictionary*;
using io_iterator_t = std::uintptr_t;
using IONotificationPortRef = inventory_ports::notification_port*;
inline constexpr unsigned IO_OBJECT_NULL = 0;
inline constexpr unsigned kIOFirstMatchNotification = 1, kIOTerminatedNotification = 2;
inline constexpr int kIOReturnError = 1;
#define kIOHIDDeviceKey "HIDDevice"
#define kIOHIDDeviceUsagePageKey "UsagePage"
#define kIOHIDDeviceUsageKey "Usage"
inline void CFRetain(const void*) {}
inline void CFDictionarySetValue(CFDictionaryRef, const char*, const void*) {}
inline CFDictionaryRef IOServiceMatching(const char*) { return nullptr; }
inline IONotificationPortRef IONotificationPortCreate(int) {
  const unsigned index = inventory_ports::next_port++ % inventory_ports::watchers.size();
  if (index >= inventory_ports::watchers.size() || !inventory_ports::watchers[index].port_ok) return nullptr;
  auto value = std::make_unique<inventory_ports::notification_port>(); value->index = index; auto result = value.get();
  inventory_ports::ports.push_back(std::move(value)); return result;
}
inline void* IONotificationPortGetRunLoopSource(IONotificationPortRef value) {
  return inventory_ports::watchers[value->index].source_ok ? value : nullptr;
}
inline void IONotificationPortDestroy(IONotificationPortRef value) {
  value->destroyed = true; ++inventory_ports::destroys;
  auto& watcher = inventory_ports::watchers[value->index];
  watcher.matched_callback = watcher.terminated_callback = nullptr; watcher.refcon = nullptr;
}
inline int IOServiceAddMatchingNotification(IONotificationPortRef, unsigned notification,
    CFDictionaryRef dictionary, void (*callback)(void*, io_iterator_t), void* refcon, io_iterator_t* output) {
  auto& watcher = inventory_ports::watchers[dictionary->index];
  if ((notification == kIOFirstMatchNotification && !watcher.match_ok) ||
      (notification == kIOTerminatedNotification && !watcher.terminate_ok)) return 1;
  watcher.refcon = refcon;
  (notification == kIOFirstMatchNotification ? watcher.matched_callback : watcher.terminated_callback) = callback;
  auto value = std::make_unique<inventory_ports::iterator>(); value->valid = watcher.iterator_valid; value->invalidate_on_exhaustion = watcher.invalidate_on_exhaustion;
  value->services = notification == kIOFirstMatchNotification ? watcher.initial : watcher.terminated;
  *output = reinterpret_cast<std::uintptr_t>(value.get()); inventory_ports::iterators.push_back(std::move(value)); return 0;
}
inline int IOServiceGetMatchingServices(int, CFDictionaryRef dictionary, io_iterator_t* output) {
  auto value = std::make_unique<inventory_ports::iterator>();
  const auto& watcher = inventory_ports::watchers[dictionary->index];
  if (!watcher.scan_ok) return 1;
  value->valid = watcher.iterator_valid; value->invalidate_on_exhaustion = watcher.invalidate_on_exhaustion;
  value->services = watcher.initial;
  *output = reinterpret_cast<std::uintptr_t>(value.get()); inventory_ports::iterators.push_back(std::move(value)); return 0;
}
inline IOHIDDeviceRef IOHIDDeviceCreate(const void*, void* service) {
  auto device = static_cast<IOHIDDeviceRef>(service);
  return inventory_ports::create_failures[device] ? nullptr : device;
}
namespace pqrs::cf {
template <typename T> class cf_ptr {
  T pointer_ = nullptr;
public:
  cf_ptr() = default; cf_ptr(std::nullptr_t) {} explicit cf_ptr(T value) : pointer_(value) {}
  T operator*() const { return pointer_; }
  explicit operator bool() const { return pointer_ != nullptr; }
};
template <typename T> cf_ptr<T> adopt_cf_ptr(T pointer) { return cf_ptr<T>(pointer); }
inline cf_ptr<CFNumberRef> make_cf_number(unsigned) { return {}; }
}
namespace pqrs::hid {
namespace manufacturer_string { using value_t = std::string; }
namespace product_string { using value_t = std::string; }
namespace usage_page { using value_t = unsigned; }
namespace usage { using value_t = unsigned; }
}
namespace pqrs::osx {

namespace iokit_mach_port { inline constexpr int null = 0; }
class kern_return {
  int value_;
public:
  kern_return(int value) : value_(value) {}
  explicit operator bool() const { return value_ == 0; }
};
class iokit_object_ptr {
  void* value_ = nullptr;
public:
  iokit_object_ptr() = default; explicit iokit_object_ptr(void* value) : value_(value) {}
  void* operator*() const { return value_; }
  explicit operator bool() const { return value_ != nullptr; }
};
class iokit_iterator {
  io_iterator_t value_ = 0;
public:
  iokit_iterator() = default; explicit iokit_iterator(io_iterator_t value) : value_(value) {}
  iokit_object_ptr get() const { return iokit_object_ptr(reinterpret_cast<void*>(value_)); }
  bool valid() const { return value_ && reinterpret_cast<inventory_ports::iterator*>(value_)->valid; }
  iokit_object_ptr next() const {
    auto value = reinterpret_cast<inventory_ports::iterator*>(value_);
    if (!value || value->cursor == value->services.size()) { if (value && value->invalidate_on_exhaustion) value->valid = false; return {}; }
    return iokit_object_ptr(value->services[value->cursor++]);
  }
};
inline iokit_iterator adopt_iokit_iterator(io_iterator_t value) { return iokit_iterator(value); }
class iokit_registry_entry {
  iokit_object_ptr value_;
public:
  explicit iokit_registry_entry(iokit_object_ptr value) : value_(value) {}
  const iokit_object_ptr& get() const { return value_; }
  std::optional<iokit_registry_entry_id::value_t> find_registry_entry_id() const {
    auto device = static_cast<IOHIDDeviceRef>(*value_);
    if (!device->identity_available) return {};
    return iokit_registry_entry_id::value_t(device->identity);
  }
};
}

namespace inventory_ports {
inline void notify(unsigned index, bool terminated, std::vector<IOHIDDeviceRef> services) {
  auto& watcher = watchers.at(index);
  auto callback = terminated ? watcher.terminated_callback : watcher.matched_callback;
  if (!callback || !watcher.refcon) throw std::logic_error("No live modeled native notification owner");
  auto iterator = std::make_unique<inventory_ports::iterator>(); iterator->services = std::move(services);
  iterator->valid = watcher.iterator_valid; iterator->invalidate_on_exhaustion = watcher.invalidate_on_exhaustion;
  const auto raw = reinterpret_cast<std::uintptr_t>(iterator.get());
  iterators.push_back(std::move(iterator)); callback(watcher.refcon, raw);
}
}
