// tools/diagnostics/hs274-hid-stream.cpp
// Observe native HID delivery from the pinned signed provider on disposable CI.

#include <ApplicationServices/ApplicationServices.h>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <filesystem>
#include <functional>
#include <iostream>
#include <mach/mach_time.h>
#include <pqrs/karabiner/driverkit/virtual_hid_device_service.hpp>
#include <string>
#include <unistd.h>
#include <vector>
#include "hs274-hid-metadata.hpp"

namespace {
struct Observation {
  CGEventType type;
  int64_t keycode;
  int64_t user_data;
  int64_t source_pid;
  int64_t numeric_field_87;
};

void write_observations(std::ostream& output, const std::vector<Observation>& observations) {
  output << "[";
  for (size_t i = 0; i < observations.size(); ++i) {
    const auto& event = observations[i];
    output << (i ? "," : "") << "\n    {\"type\": " << event.type
           << ", \"keycode\": " << event.keycode << ", \"user_data\": " << event.user_data
           << ", \"source_pid\": " << event.source_pid
           << ", \"numeric_field_87\": " << event.numeric_field_87 << "}";
  }
  output << "\n  ]";
}

CGEventRef observe(CGEventTapProxy, CGEventType type, CGEventRef event, void* context) {
  if ((type == kCGEventKeyDown || type == kCGEventKeyUp) &&
      (CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) == 49 ||
       CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) == 53)) {
    auto& observations = *static_cast<std::vector<Observation>*>(context);
    observations.push_back({type, CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode),
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
  const bool baseline = argc == 3 && std::string(argv[2]) == "--baseline-held";
  const bool ignored = argc == 3 && std::string(argv[2]) == "--ignored-hold";
  const bool hold_for_drain = ignored || (argc == 3 && std::string(argv[2]) == "--remap-hold");
  const bool remap = baseline || hold_for_drain || (argc == 3 && std::string(argv[2]) == "--remap");
  if ((argc != 2 && !remap) || geteuid() != 0 || !actions || std::string(actions) != "true") {
    std::cerr << "HID observation requires root on a disposable Actions runner\n";
    return 2;
  }
  if (hs274_metadata::device_count() != 0) {
    std::cerr << "Cannot establish an empty baseline for the CI keyboard identifiers\n";
    return 2;
  }
  std::vector<Observation> observations;
  std::vector<Observation> baseline_observations;
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
    parameters.set_vendor_id(pqrs::hid::vendor_id::value_t(hs274_metadata::vendor_id));
    parameters.set_product_id(pqrs::hid::product_id::value_t(hs274_metadata::product_id));
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
  bool space_pair_observed = false;
  bool escape_pair_observed = false;
  bool drain_released = false;
  unsigned reports_queued = 0;
  bool baseline_down_observed = false;
  std::uint64_t baseline_release_at = 0;
  hs274_metadata::Result metadata;
  auto post_pair = [&](uint16_t usage, int64_t expected_keycode) {
    const auto begin = observations.size();
    pqrs::karabiner::driverkit::virtual_hid_device_driver::hid_report::keyboard_input down;
    down.keys.insert(usage);
    client->async_post_report(down);
    ++reports_queued;
    // A tap-only mapping emits after release; waiting for output first would
    // accidentally turn this stimulus into a hold.
    pump_until([] { return false; }, 0.03);
    // Always queue release, including an unobserved key-down or transport error.
    pqrs::karabiner::driverkit::virtual_hid_device_driver::hid_report::keyboard_input release;
    client->async_post_report(release);
    ++reports_queued;
    pump_until([&observations, begin] {
      return observations.size() >= begin + 2;
    }, 2);
    return observations.size() == begin + 2 &&
           observations[begin].type == kCGEventKeyDown && observations[begin].keycode == expected_keycode &&
           observations[begin + 1].type == kCGEventKeyUp && observations[begin + 1].keycode == expected_keycode;
  };
  if (acquired) {
    if (pump_until([] { return hs274_metadata::device_count() == 1; }, 2)) {
      metadata = hs274_metadata::observe([&](uint64_t registry_id) {
        if (!remap) return true;
        bool baseline_held = false;
        auto release_baseline = [&] {
          if (!baseline_held) return;
          baseline_release_at = mach_absolute_time();
          pqrs::karabiner::driverkit::virtual_hid_device_driver::hid_report::keyboard_input release;
          client->async_post_report(release);
          ++reports_queued;
          baseline_held = false;
          pump_until([] { return false; }, 0.03);
        };
        struct release_guard {
          std::function<void()> release;
          ~release_guard() { release(); }
        } guard{release_baseline};
        const std::string ready_path = std::string(argv[1]) + ".ready.json";
        const std::string start_path = std::string(argv[1]) + ".start";
        const std::string abort_path = std::string(argv[1]) + ".abort";
        const std::string drained_path = std::string(argv[1]) + ".drained";
        if (std::filesystem::exists(ready_path) || std::filesystem::exists(start_path) ||
            std::filesystem::exists(drained_path)) return false;
        if (baseline) {
          pqrs::karabiner::driverkit::virtual_hid_device_driver::hid_report::keyboard_input down;
          down.keys.insert(type_safe::get(pqrs::hid::usage::keyboard_or_keypad::keyboard_spacebar));
          client->async_post_report(down);
          ++reports_queued;
          baseline_held = true;
          baseline_down_observed = pump_until([&] {
            for (const auto& event : observations) {
              if (event.type == kCGEventKeyDown && event.keycode == 49) return true;
            }
            return false;
          }, 2);
          if (!baseline_down_observed) return false;
        }
        std::ofstream ready(ready_path);
        ready << "{\"renamed\":true,\"registry_entry_id\":" << registry_id
              << ",\"vendor_id\":" << hs274_metadata::vendor_id
              << ",\"product_id\":" << hs274_metadata::product_id
              << ",\"hold_for_drain\":" << std::boolalpha << hold_for_drain
              << ",\"baseline_held\":" << baseline_held << "}\n";
        ready.close();
        if (!ready || !pump_until([&] {
              return std::filesystem::exists(start_path) || std::filesystem::exists(abort_path);
            }, 45) || std::filesystem::exists(abort_path)) return false;
        if (baseline) {
          release_baseline();
          baseline_observations.swap(observations);
          space_pair_observed = post_pair(type_safe::get(pqrs::hid::usage::keyboard_or_keypad::keyboard_spacebar), 49);
          return baseline_down_observed && space_pair_observed;
        }
        escape_pair_observed = post_pair(type_safe::get(pqrs::hid::usage::keyboard_or_keypad::keyboard_escape), ignored ? 53 : 49);
        space_pair_observed = post_pair(type_safe::get(pqrs::hid::usage::keyboard_or_keypad::keyboard_spacebar), 49);
        if (hold_for_drain && escape_pair_observed && space_pair_observed) {
          // Keep the renamed device alive until the reader drains and stops.
          drain_released = pump_until([&] {
            return std::filesystem::exists(drained_path) || std::filesystem::exists(abort_path);
          }, 40) && !std::filesystem::exists(abort_path) && std::filesystem::exists(drained_path);
          if (!drain_released) return false;
        }
        return escape_pair_observed && space_pair_observed;
      });
    }
    if (!remap) {
      space_pair_observed = post_pair(type_safe::get(pqrs::hid::usage::keyboard_or_keypad::keyboard_spacebar), 49);
    }
  }
  client.reset();
  pqrs::dispatcher::extra::terminate_shared_dispatcher();
  CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
  CFMachPortInvalidate(tap);
  CFRelease(source);
  CFRelease(tap);

  const bool pair = space_pair_observed && observations.size() == (remap && !baseline ? 4 : 2)
                    && (!remap || baseline || escape_pair_observed);
  std::ofstream receipt(argv[1]);
  receipt << std::boolalpha
          << "{\n  \"hs274_fixed\": false,\n  \"physical_keyboard_validated\": false,\n"
          << "  \"virtual_keyboard_ready\": " << acquired
          << ",\n  \"reports_queued\": " << reports_queued
          << ",\n  \"transport_error\": " << transport_error.load()
          << ",\n  \"metadata_owner_verified\": " << metadata.owner_verified
          << ",\n  \"registry_entry_id\": " << metadata.registry_entry_id
          << ",\n  \"metadata_write_status\": " << metadata.write_status
          << ",\n  \"metadata_readback_matches\": " << metadata.readback_matches
          << ",\n  \"metadata_restore_status\": " << metadata.restore_status
          << ",\n  \"metadata_restored\": " << metadata.restored
          << ",\n  \"metadata_work_completed\": " << metadata.work_completed
          << ",\n  \"remap_mode\": " << remap
          << ",\n  \"drain_released\": " << drain_released
          << ",\n  \"ignored_mode\": " << ignored
          << ",\n  \"baseline_mode\": " << baseline
          << ",\n  \"baseline_down_observed\": " << baseline_down_observed
          << ",\n  \"baseline_release_at\": \"" << baseline_release_at << "\""
          << ",\n  \"escape_as_space\": " << (escape_pair_observed && !ignored)
          << ",\n  \"escape_passthrough\": " << (escape_pair_observed && ignored)
          << ",\n  \"space_pair_observed\": " << pair << ",\n  \"baseline_events\": ";
  write_observations(receipt, baseline_observations);
  receipt << ",\n  \"events\": ";
  write_observations(receipt, observations);
  receipt << "\n}\n";
  receipt.close();
  return receipt && pair && !transport_error && metadata.owner_verified &&
                 metadata.write_status == KERN_SUCCESS && metadata.readback_matches &&
                 metadata.restore_status == KERN_SUCCESS && metadata.restored && metadata.work_completed ? 0 : 1;
}
