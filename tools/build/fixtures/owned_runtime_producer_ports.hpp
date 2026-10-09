// Bounded modeled native ports for the actual assembled producer's portable tests.
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
namespace pqrs {
template <typename T> using not_null_shared_ptr_t = std::shared_ptr<T>;
namespace cf { struct run_loop_thread {}; }
namespace dispatcher {
struct dispatcher {};
namespace extra {
struct dispatcher_client {
  explicit dispatcher_client(std::weak_ptr<dispatcher>) {}
  virtual ~dispatcher_client() = default;
  template <typename Callback> void detach_from_dispatcher(Callback callback) { callback(); }
};
}
}
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
