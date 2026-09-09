// tools/diagnostics/hs274-hid-stream.cpp
// Observe native HID delivery from the pinned signed provider on disposable CI.

#include <ApplicationServices/ApplicationServices.h>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <pqrs/karabiner/driverkit/virtual_hid_device_service.hpp>
#include <string>
#include <unistd.h>
#include <vector>

namespace {
struct Observation {
  CGEventType type;
  int64_t keycode;
  int64_t user_data;
  int64_t source_pid;
  int64_t numeric_field_87;
};

CGEventRef observe(CGEventTapProxy, CGEventType type, CGEventRef event, void* context) {
  if ((type == kCGEventKeyDown || type == kCGEventKeyUp) &&
      CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) == 49) {
    auto& observations = *static_cast<std::vector<Observation>*>(context);
    observations.push_back({type, 49,
                            CGEventGetIntegerValueField(event, kCGEventSourceUserData),
                            CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID),
                            CGEventGetIntegerValueField(event, static_cast<CGEventField>(87))});
  }
  return event;
}

template <typename Predicate>
bool pump_until(Predicate predicate, double seconds) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
  while (!predicate() && std::chrono::steady_clock::now() < deadline) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
  }
  return predicate();
}
} // namespace

int main(int argc, char** argv) {
  const char* actions = std::getenv("GITHUB_ACTIONS");
  if (argc != 2 || geteuid() != 0 || !actions || std::string(actions) != "true") {
    std::cerr << "HID observation requires root on a disposable Actions runner\n";
    return 2;
  }
  std::vector<Observation> observations;
  const CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
  auto tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap,
                              kCGEventTapOptionListenOnly, mask, observe, &observations);
  if (!tap) {
    std::cerr << "Native HID event tap acquisition failed\n";
    return 2;
  }
  auto source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
  if (!source) {
    CFRelease(tap);
    return 2;
  }
  CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
  CGEventTapEnable(tap, true);

  std::atomic<bool> ready(false);
  std::atomic<bool> transport_error(false);
  pqrs::dispatcher::extra::initialize_shared_dispatcher();
  using Client = pqrs::karabiner::driverkit::virtual_hid_device_service::client;
  auto client = std::make_unique<Client>();
  client->connected.connect([&client] {
    pqrs::karabiner::driverkit::virtual_hid_device_service::virtual_hid_keyboard_parameters parameters;
    parameters.set_country_code(pqrs::hid::country_code::us);
    client->async_virtual_hid_keyboard_initialize(parameters);
  });
  client->virtual_hid_keyboard_ready.connect([&ready](bool value) { ready = value; });
  client->error_occurred.connect([&transport_error](auto&& error) {
    transport_error = true;
    std::cerr << "HID transport error: " << error << '\n';
  });
  client->warning_reported.connect([&transport_error](auto&& message) {
    transport_error = true;
    std::cerr << "HID transport warning: " << message << '\n';
  });
  client->async_start();
  const bool acquired = pump_until([&ready] { return ready.load(); }, 15);
  bool down_observed = false;
  bool up_observed = false;
  unsigned reports_queued = 0;
  if (acquired) {
    pqrs::karabiner::driverkit::virtual_hid_device_driver::hid_report::keyboard_input down;
    down.keys.insert(type_safe::get(pqrs::hid::usage::keyboard_or_keypad::keyboard_spacebar));
    client->async_post_report(down);
    ++reports_queued;
    down_observed = pump_until([&observations] {
      return !observations.empty() && observations.front().type == kCGEventKeyDown;
    }, 2);
    // Always queue release, including an unobserved key-down or transport error.
    pqrs::karabiner::driverkit::virtual_hid_device_driver::hid_report::keyboard_input release;
    client->async_post_report(release);
    ++reports_queued;
    up_observed = pump_until([&observations] {
      return !observations.empty() && observations.back().type == kCGEventKeyUp;
    }, 2);
  }
  client.reset();
  pqrs::dispatcher::extra::terminate_shared_dispatcher();
  CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
  CFMachPortInvalidate(tap);
  CFRelease(source);
  CFRelease(tap);

  const bool pair = observations.size() == 2 && down_observed && up_observed;
  std::ofstream receipt(argv[1]);
  receipt << std::boolalpha
          << "{\n  \"hs274_fixed\": false,\n  \"physical_keyboard_validated\": false,\n"
          << "  \"virtual_keyboard_ready\": " << acquired
          << ",\n  \"reports_queued\": " << reports_queued
          << ",\n  \"transport_error\": " << transport_error.load()
          << ",\n  \"space_pair_observed\": " << pair << ",\n  \"events\": [";
  for (size_t i = 0; i < observations.size(); ++i) {
    const auto& event = observations[i];
    receipt << (i ? "," : "") << "\n    {\"type\": " << event.type
            << ", \"keycode\": " << event.keycode << ", \"user_data\": " << event.user_data
            << ", \"source_pid\": " << event.source_pid
            << ", \"numeric_field_87\": " << event.numeric_field_87 << "}";
  }
  receipt << "\n  ]\n}\n";
  receipt.close();
  return receipt && pair && !transport_error ? 0 : 1;
}
