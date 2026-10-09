// tools/build/fixtures/owned_runtime_queue_ports.hpp
// Explicit modeled native and scheduler ports for the genuine vendor monitor.
// These ports qualify no Darwin queue, physical device, enumeration or framework.
#pragma once
#include <cstdint>
#include <cstring>
#include <functional>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <vector>
#include <deque>
#include <algorithm>
#include <Block.h>
#include <stdexcept>
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
namespace type_safe { template <typename T> T get(T value) { return value; } }
// Native queue failure and scheduling are inputs, never production readiness bits.
namespace queue_ports {
inline bool creation_fails = false;
inline unsigned creates = 0, adds = 0, queue_starts = 0, queue_stops = 0;
inline unsigned opens = 0, closes = 0, queue_reads = 0;
inline int open_result = 0;
inline std::vector<std::string> order;
inline std::deque<std::function<void()>> run_loop_jobs, dispatcher_jobs;
// Keep the genuine registered callback and explicit borrowed fixture values.
// Retaining this modeled context proves no native callback retirement.
struct queue {
  IOHIDDeviceRef device = nullptr;
  void (*callback)(void*, int, void*) = nullptr;
  void* context = nullptr;
  std::deque<IOHIDValueRef> values;
};
inline queue native_queue{};
inline void run_loop() {
  for (unsigned count = 0; !run_loop_jobs.empty(); ++count) {
    if (count == 256) throw std::runtime_error("Modeled run loop did not settle");
    auto work = std::move(run_loop_jobs.front()); run_loop_jobs.pop_front(); work();
  }
}
inline void dispatcher() {
  for (unsigned count = 0; !dispatcher_jobs.empty(); ++count) {
    if (count == 256) throw std::runtime_error("Modeled dispatcher did not settle");
    auto work = std::move(dispatcher_jobs.front()); dispatcher_jobs.pop_front(); work();
  }
}
inline void settle() { run_loop(); dispatcher(); }
inline void reset() {
  if (!run_loop_jobs.empty() || !dispatcher_jobs.empty()) throw std::runtime_error("Pending model work");
  creation_fails = false; creates = adds = queue_starts = queue_stops = opens = closes = queue_reads = 0;
  open_result = 0; native_queue = {}; order.clear();
}
}
using IOHIDQueueRef = queue_ports::queue*;
using IOReturn = int;
using IOHIDReportType = int;
inline constexpr int kIOReturnError = -1, kIOHIDReportTypeInput = 1;
inline constexpr unsigned kIOHIDOptionsTypeSeizeDevice = 1;
inline const char* kCFRunLoopCommonModes = "modeled-common-modes";
inline void* CFRunLoopGetCurrent() { return nullptr; }
inline IOHIDQueueRef IOHIDQueueCreate(const void*, IOHIDDeviceRef device, CFIndex, IOOptionBits) {
  ++queue_ports::creates; queue_ports::order.push_back("create");
  if (queue_ports::creation_fails) return nullptr;
  queue_ports::native_queue = {}; queue_ports::native_queue.device = device; return &queue_ports::native_queue;
}
inline void IOHIDQueueAddElement(IOHIDQueueRef, IOHIDElementRef) { ++queue_ports::adds; }
template <typename Callback> inline void IOHIDQueueRegisterValueAvailableCallback(IOHIDQueueRef queue, Callback callback, void* context) {
  queue->callback = callback; queue->context = context;
}
inline void IOHIDQueueScheduleWithRunLoop(IOHIDQueueRef, void*, const char*) {}
inline void IOHIDQueueUnscheduleFromRunLoop(IOHIDQueueRef, void*, const char*) {}
inline void IOHIDQueueStart(IOHIDQueueRef) { ++queue_ports::queue_starts; queue_ports::order.push_back("queue-start"); }
inline void IOHIDQueueStop(IOHIDQueueRef) { ++queue_ports::queue_stops; }
inline IOHIDValueRef IOHIDQueueCopyNextValueWithTimeout(IOHIDQueueRef queue, double) {
  ++queue_ports::queue_reads;
  if (queue->values.empty()) return nullptr;
  auto value = queue->values.front(); queue->values.pop_front(); return value;
}
inline IOReturn IOHIDDeviceOpen(IOHIDDeviceRef, IOOptionBits) {
  ++queue_ports::opens; queue_ports::order.push_back("device-open"); return queue_ports::open_result;
}
inline IOReturn IOHIDDeviceClose(IOHIDDeviceRef, IOOptionBits) { ++queue_ports::closes; return kIOReturnSuccess; }
template <typename Callback> inline void IOHIDDeviceRegisterRemovalCallback(IOHIDDeviceRef, Callback, void*) {}
template <typename Callback> inline void IOHIDDeviceRegisterInputReportCallback(IOHIDDeviceRef, uint8_t*, CFIndex, Callback, void*) {}
inline void IOHIDDeviceScheduleWithRunLoop(IOHIDDeviceRef, void*, const char*) {}
inline void IOHIDDeviceUnscheduleFromRunLoop(IOHIDDeviceRef, void*, const char*) {}
namespace pqrs {
template <typename T> using not_null_shared_ptr_t = std::shared_ptr<T>;
namespace cf {
template <typename T> class cf_ptr {
  T value_ = nullptr;
public:
  cf_ptr() = default;
  cf_ptr(T value) : value_(value) {}
  explicit operator bool() const { return value_ != nullptr; }
  T operator*() const { return value_; }
  cf_ptr& operator=(std::nullptr_t) { value_ = nullptr; return *this; }
};
template <typename T> cf_ptr<T> adopt_cf_ptr(T value) { return cf_ptr<T>(value); }
struct run_loop_thread {
  void* get_run_loop() const { return nullptr; }
  void enqueue(void (^work)()) {
    auto copy = std::shared_ptr<void>((void*)Block_copy(work), [](void* pointer) { Block_release(pointer); });
    queue_ports::run_loop_jobs.emplace_back([copy] { ((void (^)())copy.get())(); });
  }
};
}
namespace dispatcher {
struct dispatcher {};
namespace extra {
struct dispatcher_client {
  explicit dispatcher_client(std::weak_ptr<dispatcher>) {}
  virtual ~dispatcher_client() = default;
  template <typename Callback> void detach_from_dispatcher(Callback callback) { callback(); }
  void detach_from_dispatcher() {}
  template <typename Callback> void enqueue_to_dispatcher(Callback callback) { queue_ports::dispatcher_jobs.emplace_back(callback); }
  struct wait { void notify() {} void wait_notice() {} };
  auto make_thread_wait() { return std::make_shared<wait>(); }
};
class timer {
  bool active_ = false;
  std::function<void()> callback_;
public:
  inline static std::vector<timer*> timers;
  explicit timer(dispatcher_client&) { timers.push_back(this); }
  ~timer() { timers.erase(std::remove(timers.begin(), timers.end(), this), timers.end()); }
  template <typename Callback> void start(Callback callback, std::chrono::milliseconds) {
    active_ = true; callback_ = callback; callback_();
  }
  void stop() { active_ = false; }
  static void tick() { for (auto* item : timers) if (item->active_) item->callback_(); }
};
}
}
namespace osx {
namespace chrono {
using absolute_time_point = std::uint64_t;
inline absolute_time_point mach_absolute_time_point() { return mach_absolute_time(); }
}
class iokit_return {
  IOReturn value_;
public:
  iokit_return(IOReturn value) : value_(value) {}
  explicit operator bool() const { return value_ == kIOReturnSuccess; }
  friend bool operator==(iokit_return a, iokit_return b) { return a.value_ == b.value_; }
};
class iokit_hid_device {
  IOHIDDeviceRef device_;
public:
  explicit iokit_hid_device(IOHIDDeviceRef device) : device_(device) {}
  cf::cf_ptr<IOHIDDeviceRef> get_device() const { return device_; }
  std::optional<std::int64_t> find_max_input_report_size() const { return std::nullopt; }
  cf::cf_ptr<IOHIDQueueRef> make_queue(CFIndex depth) const {
    return cf::adopt_cf_ptr(IOHIDQueueCreate(kCFAllocatorDefault, device_, depth, kIOHIDOptionsTypeNone));
  }
  std::vector<cf::cf_ptr<IOHIDElementRef>> make_elements() const {
    std::vector<cf::cf_ptr<IOHIDElementRef>> result;
    for (auto* element : device_->elements) result.emplace_back(element);
    return result;
  }
};
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
}
}

namespace krbn {
struct device_identifiers { bool get_is_virtual_device() const { return false; } };
struct device_properties {
  std::uint64_t identity;
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
