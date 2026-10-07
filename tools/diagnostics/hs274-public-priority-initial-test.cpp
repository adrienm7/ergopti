// tools/diagnostics/hs274-public-priority-initial-test.cpp
// Public SDK qualification only; production capture and session posture are unchanged.
#include "hs274-priority-initial-policy.hpp"
#include <chrono>
#include <cstddef>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>

// Independent expectations frozen before the policy/native implementation.
static unsigned checked = 0;
static void expect(bool condition, const char* label) {
  ++checked;
  if (!condition) throw std::runtime_error(label);
}
static hs274_priority_initial::packet sample(std::uint32_t capabilities = 15) {
  hs274_priority_initial::packet value{};
  value.to = capabilities;
  return value;
}
static hs274_priority_initial::capability_class closed_sample(std::uint32_t bits) {
  hs274_priority_initial::observation state;
  state.subscribe();
  state.receive(sample(bits), true);
  state.begin_retirement();
  state.complete_retirement(true, true, true, true);
  return state.result();
}
static void independent_controls() {
  using namespace hs274_priority_initial;
  expect(closed_sample(0) == capability_class::cpu_inactive, "genuine negative initial");
  expect(closed_sample(1) == capability_class::cpu_without_graphics, "CPU alone is dark compatible");
  expect(closed_sample(5) == capability_class::cpu_without_graphics, "audio does not prove graphics");
  expect(closed_sample(9) == capability_class::cpu_without_graphics, "network does not prove graphics");
  expect(closed_sample(13) == capability_class::cpu_without_graphics, "background capability is dark compatible");
  expect(closed_sample(3) == capability_class::graphics_capable, "graphics capability independent of display");
  expect(closed_sample(7) == capability_class::graphics_capable, "graphics and audio capability");
  expect(closed_sample(11) == capability_class::graphics_capable, "graphics and network capability");
  expect(closed_sample(15) == capability_class::graphics_capable, "all known capability bits");
  expect(closed_sample(2) == capability_class::refused, "graphics without CPU malformed");
  expect(closed_sample(8) == capability_class::refused, "network without CPU malformed");
  expect(closed_sample(17) == capability_class::refused, "unqualified AOT/unknown bit");
  expect(closed_sample(UINT32_MAX) == capability_class::refused, "unknown mask bits");
  for (unsigned variation = 0; variation < 7; ++variation) {
    auto value = sample();
    if (variation == 0) value.flags = 1;
    if (variation == 1) value.flags = 2;
    if (variation == 2) value.from = 1;
    if (variation == 3) value.reserved = 1;
    if (variation == 4) value.reserved_tail[3] = 1;
    if (variation == 5) value.max_wait = 1;
    if (variation == 6) value.flags = 3;
    observation state;
    state.subscribe(); state.receive(value, true);
    state.begin_retirement(); state.complete_retirement(true, true, true, true);
    expect(state.result() == capability_class::refused, "malformed initial/transition refuses");
  }
  {
    observation state;
    state.receive(sample(), true);
    expect(state.failed(), "pre-subscription callback refuses");
  }
  {
    observation state;
    state.subscribe(); state.subscribe();
    expect(state.failed(), "subscription reentry refuses");
  }
  {
    observation state;
    state.subscribe(); state.receive(sample(), false);
    expect(state.failed(), "original provider replacement refuses");
  }
  {
    observation state;
    state.subscribe(); state.receive(sample(), true); state.receive(sample(), true);
    expect(state.failed(), "duplicate initial refuses");
  }
  {
    observation state;
    state.subscribe(); state.receive(sample(), true);
    expect(state.result() == capability_class::refused, "unretired outcome is not admitted");
    state.begin_retirement(); state.receive(sample(), true);
    expect(state.failed(), "late retiring callback refuses");
  }
  {
    observation state;
    state.subscribe(); state.receive(sample(), true); state.begin_retirement();
    state.complete_retirement(true, true, true, true); state.receive(sample(), true);
    expect(state.failed(), "post-retirement callback refuses");
  }
  for (unsigned variation = 0; variation < 4; ++variation) {
    observation state;
    state.subscribe(); state.receive(sample(), true); state.begin_retirement();
    state.complete_retirement(variation != 0, variation != 1, variation != 2, variation != 3);
    expect(state.result() == capability_class::refused, "provider/currentness or incomplete cleanup refuses");
  }
  {
    observation state;
    state.subscribe(); state.observe_legacy();
    expect(state.failed(), "legacy power event creates one-shot observation gap without ACK");
  }
  {
    observation state;
    state.subscribe(); state.begin_retirement(); state.complete_retirement(true, true, true, true);
    expect(state.result() == capability_class::refused, "absence of initial notification stays unknown");
  }
  {
    observation state;
    state.subscribe(); state.receive(sample(), true); state.begin_retirement();
    state.complete_retirement(true, true, true, true); state.complete_retirement(true, true, true, true);
    expect(state.failed(), "cleanup completion reentry refuses");
  }
  expect(checked == 34, "independently declared control count");
  std::cout << "PASS public priority initial controls assertions=35; native_framework_calls=unexecuted\n";
}

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOKitKeys.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPM.h>
#include <mach/mach.h>

// Fixed macOS 15 public vocabulary; newer/unknown capability shapes refuse.
static_assert(kIOPMSystemCapabilityCPU == 1 && kIOPMSystemCapabilityGraphics == 2 &&
              kIOPMSystemCapabilityAudio == 4 && kIOPMSystemCapabilityNetwork == 8);
static_assert(sizeof(IOPMSystemCapabilityChangeParameters) == 40);
static_assert(offsetof(IOPMSystemCapabilityChangeParameters, fromCapabilities) == 16);
static_assert(offsetof(IOPMSystemCapabilityChangeParameters, toCapabilities) == 20);

struct native_context {
  hs274_priority_initial::observation policy;
  io_service_t original = IO_OBJECT_NULL;
  std::uint64_t original_id = 0;
  CFRunLoopRef loop = nullptr;
  bool in_callback = false;
};

static io_service_t root_service() {
  return IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
}

static bool same_provider(const native_context& owner, io_service_t provider) {
  std::uint64_t identity = 0;
  return owner.original && owner.original_id && provider &&
      IOObjectIsEqualTo(owner.original, provider) && IOObjectConformsTo(provider, "IOPMrootDomain") &&
      IORegistryEntryGetRegistryEntryID(provider, &identity) == KERN_SUCCESS && identity == owner.original_id;
}

static bool provider_current(const native_context& owner) {
  const auto current = root_service();
  if (!current) return false;
  const bool same = same_provider(owner, current);
  const bool closed = IOObjectRelease(current) == KERN_SUCCESS;
  return same && closed;
}

static void receive(void* parameter, io_service_t provider, natural_t message, void* argument) {
  auto& owner = *static_cast<native_context*>(parameter);
  if (owner.in_callback) {
    owner.policy.refuse();
    CFRunLoopStop(owner.loop);
    return;
  }
  owner.in_callback = true;
  const bool current = same_provider(owner, provider);
  if (!current || !argument) owner.policy.refuse();
  else if (message != kIOMessageSystemCapabilityChange) {
    // Kernel-to-user copying leaves the kernel zero reply unchanged.
    // Never inspect the copied legacy payload or send ACK.
    owner.policy.observe_legacy();
  } else {
    IOPMSystemCapabilityChangeParameters actual{};
    std::memcpy(&actual, argument, sizeof(actual));
    hs274_priority_initial::packet held{};
    held.notify_ref = actual.notifyRef;
    held.max_wait = actual.maxWaitForReply;
    held.flags = actual.changeFlags;
    held.reserved = actual.__reserved1;
    held.from = actual.fromCapabilities;
    held.to = actual.toCapabilities;
    for (unsigned index = 0; index < 4; ++index) held.reserved_tail[index] = actual.__reserved2[index];
    owner.policy.receive(held, current);
  }
  owner.in_callback = false;
  CFRunLoopStop(owner.loop);
}

static const char* class_name(hs274_priority_initial::capability_class value) {
  using hs274_priority_initial::capability_class;
  if (value == capability_class::cpu_inactive) return "cpu_inactive";
  if (value == capability_class::cpu_without_graphics) return "cpu_without_graphics";
  if (value == capability_class::graphics_capable) return "graphics_capable";
  return "refused";
}

static bool native_initial() {
  native_context owner;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  const auto mode = CFSTR("ErgoptiPriorityInitialQualification");
  IONotificationPortRef port = nullptr;
  CFRunLoopSourceRef source = nullptr;
  io_object_t notifier = IO_OBJECT_NULL;
  mach_port_t receive_port = MACH_PORT_NULL;
  bool original_receive = false;
  bool source_owned = false;
  bool notifier_closed = false;
  bool source_invalidated = false;
  bool port_destroyed = false;

  owner.loop = CFRunLoopGetCurrent();
  CFRetain(owner.loop);
  owner.original = root_service();
  if (!owner.original || !IOObjectConformsTo(owner.original, "IOPMrootDomain") ||
      IORegistryEntryGetRegistryEntryID(owner.original, &owner.original_id) != KERN_SUCCESS ||
      !owner.original_id || !provider_current(owner)) owner.policy.refuse();
  if (!owner.policy.failed()) {
    port = IONotificationPortCreate(kIOMainPortDefault);
    if (!port) owner.policy.refuse();
  }
  if (!owner.policy.failed()) {
    receive_port = IONotificationPortGetMachPort(port);
    mach_port_type_t rights = 0;
    original_receive = MACH_PORT_VALID(receive_port) &&
        mach_port_type(mach_task_self(), receive_port, &rights) == KERN_SUCCESS &&
        (rights & MACH_PORT_TYPE_RECEIVE);
    source = IONotificationPortGetRunLoopSource(port);
    if (!source || !CFRunLoopSourceIsValid(source) || !original_receive) owner.policy.refuse();
    if (source) { CFRetain(source); source_owned = true; }
  }
  if (!owner.policy.failed()) {
    CFRunLoopAddSource(owner.loop, source, mode);
    owner.policy.subscribe();
    if (IOServiceAddInterestNotification(port, owner.original, kIOPriorityPowerStateInterest,
                                        receive, &owner, &notifier) != KERN_SUCCESS || !notifier ||
        !provider_current(owner)) owner.policy.refuse();
  }
  while (!owner.policy.failed() && !owner.policy.has_initial() && std::chrono::steady_clock::now() < deadline) {
    CFRunLoopRunInMode(mode, 0.05, true);
  }
  if (!owner.policy.has_initial() || !provider_current(owner)) owner.policy.refuse();

  // No callback runs concurrently: this source is scheduled only on this
  // thread, and no callback recursively runs a loop. Keep owner alive through
  // deregistration, actual source invalidation, receive-right closure and drain.
  owner.policy.begin_retirement();
  if (notifier) {
    notifier_closed = IOObjectRelease(notifier) == KERN_SUCCESS;
    notifier = IO_OBJECT_NULL;
  }
  if (source_owned) {
    CFRunLoopRemoveSource(owner.loop, source, mode);
    CFRunLoopSourceInvalidate(source);
    source_invalidated = !CFRunLoopSourceIsValid(source) && !CFRunLoopContainsSource(owner.loop, source, mode);
  }
  if (port) {
    IONotificationPortDestroy(port);
    port = nullptr;
    mach_port_type_t rights = 0;
    const auto status = mach_port_type(mach_task_self(), receive_port, &rights);
    port_destroyed = original_receive && (status == KERN_INVALID_NAME ||
        (status == KERN_SUCCESS && !(rights & MACH_PORT_TYPE_RECEIVE)));
  }
  CFRunLoopRunInMode(mode, 0.01, true);
  if (owner.in_callback) owner.policy.refuse();
  const bool current = provider_current(owner);
  if (source_owned) CFRelease(source);
  owner.policy.complete_retirement(current, source_invalidated, notifier_closed, port_destroyed);
  if (owner.original && IOObjectRelease(owner.original) != KERN_SUCCESS) owner.policy.refuse();
  owner.original = IO_OBJECT_NULL;
  CFRelease(owner.loop);
  owner.loop = nullptr;

  if (owner.policy.result() == hs274_priority_initial::capability_class::refused) return false;
  std::cout << "PASS public priority initial class=" << class_name(owner.policy.result())
            << "; subscription_retired=observed; physical_transitions=unexecuted; session_lock_authority=unresolved\n";
  return true;
}
#endif

int main(int argc, char** argv) {
  try {
    if (argc != 2) return 64;
    const std::string mode(argv[1]);
    if (mode == "--controls" || mode == "--qualify") independent_controls();
    if (mode == "--controls") return 0;
    if (mode != "--native" && mode != "--qualify") return 64;
#if defined(__APPLE__)
    if (native_initial()) return 0;
    std::cerr << "REFUSED public priority initial source/payload/retirement qualification\n";
    return 1;
#else
    std::cerr << "UNAVAILABLE actual macOS public SDK subscription; native_framework_calls=unexecuted\n";
    return 77;
#endif
  } catch (const std::exception& error) {
    std::cerr << "REFUSED public priority initial control: " << error.what() << '\n';
    return 1;
  }
}
