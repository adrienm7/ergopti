"""Fixed owned producer projections; no profile or native-readiness authority.

The owned source factory supplies exact frozen experimental intermediate bytes.
The original experimental source, independent fixtures and oracle stay unchanged.
"""


def replace_once(source, before, after):
    if type(source) is not str or source.count(before) != 1:
        raise RuntimeError("Expected one fixed owned producer anchor")
    return source.replace(before, after, 1)


# The closed owned source factory selects these projections directly. The
# experimental functions and header bytes stay whole in their original files.
def owned_stream_monitor(source):
    """Keep genuine native capture hooks without the named finite fixture role."""
    source = replace_once(
        source,
        '        hs274_probe_owned_(type_safe::get(device_properties.get_product()) == "HS274 CI Keyboard"),\n',
        "",
    )
    source = replace_once(source, "  bool hs274_probe_owned_;\n", "")
    source = replace_once(
        source,
        "      if (hs274_probe_owned_) hs274_stream_protocol::runtime::reference(hs274_monitor_, device, hs274_probe_device_id_);\n",
        "",
    )
    source = replace_once(
        source,
        "hs274_stream_protocol::runtime::append(hs274_monitor_, hs274_probe_owned_, {",
        "hs274_stream_protocol::runtime::append(hs274_monitor_, {",
    )
    return source.replace("hs274_probe_device_id_", "hs274_capture_device_id_")


def owned_stream_shutdown(source):
    """Preserve the actual daemon's native lifetime and final return unchanged."""
    # Validate the same unique final return the experimental hook instruments,
    # then leave all native startup/cleanup bytes to their existing owner.
    return replace_once(source, "  return 0;", "  return 0;")


def owned_stream_runtime(source):
    """Project the closed native bridge without finite mirror/reference work."""
    source = replace_once(source, '#include "hs274-stream-input.hpp"\n', "")
    source = replace_once(
        source,
        "  static bool reference(monitor& owner, IOHIDDeviceRef device, std::uint64_t identity) {\n    const auto fence = owner.capture_fence();\n    if (!current(fence) || !owner.active()) return false;\n    if (fence.fault() != native_fault::none) { fence.stopped(); return false; }\n    return diagnostic_acquisition(owner, [fence](native_fault reason) { fence.fail(reason); }, [&] {\n      hs274_baseline_probe::capture(device, identity);\n      return current(fence);\n    }, current);\n  }\n\n",
        "",
    )
    source = replace_once(
        source,
        "  static void append(monitor& owner, bool is_reference, const value& input) noexcept {\n    // Retain the finite independent receipt during this fixture experiment.\n    append_input(owner, hs274_raw_capture::fixture, is_reference, input);\n  }\n",
        "  static void append(monitor& owner, const value& input) noexcept {\n"
        "    owner.append(input);\n"
        "  }\n",
    )
    source = replace_once(
        source,
        "hs274_baseline_probe::capture_inventory(device, captured.device())",
        "hs274_baseline_probe::capture_inventory(device)",
    )
    source = replace_once(
        source,
        "// Disposable native bridge; all access belongs to the shared dispatcher.",
        "// Owned native bridge; all access belongs to the shared dispatcher.",
    )
    source = replace_once(
        source,
        "  // The finite fixture has 20 values. Bound both backlog and per-response work;\n",
        "  // Bound producer backlog and per-response work independently of diagnostic fixtures;\n",
    )
    return owned_inventory_runtime(source)


def owned_stream_baseline_probe(source):
    """Retain per-element baseline-v2 acquisition without raw diagnostic I/O."""
    source = replace_once(
        source,
        '\ninline void capture(IOHIDDeviceRef device, std::uint64_t identity) {\n  elements_owner elements{IOHIDDeviceCopyMatchingElements(device, nullptr, kIOHIDOptionsTypeNone)};\n  json result{{"device", std::to_string(identity)}, {"coverage", "fixture_only"},\n              {"enumerated", elements.value != nullptr}, {"exhausted", false}, {"elements", json::array()}};\n  if (elements.value) {\n    for (CFIndex i = 0; i < CFArrayGetCount(elements.value); ++i) {\n      auto element = static_cast<IOHIDElementRef>(const_cast<void*>(CFArrayGetValueAtIndex(elements.value, i)));\n      const auto page = IOHIDElementGetUsagePage(element);\n      const auto usage = IOHIDElementGetUsage(element);\n      const auto type = IOHIDElementGetType(element);\n      // The independent fixture uses Escape and Space. This deliberately does\n      // not pretend that two sampled usages inventory an arbitrary keyboard.\n      if (page != 7 || (usage != 41 && usage != 44) ||\n          type < kIOHIDElementTypeInput_Misc || type > kIOHIDElementTypeInput_ScanCodes) continue;\n      if (result["elements"].size() == 2) {\n        result["exhausted"] = true;\n        break;\n      }\n      result["elements"].push_back({\n          {"page", page}, {"usage", usage}, {"cookie", static_cast<std::uint32_t>(IOHIDElementGetCookie(element))},\n          {"cached", read(device, element, kIOHIDDeviceGetValueWithoutUpdate)},\n          {"updated", read(device, element, kIOHIDDeviceGetValueWithUpdate)}});\n    }\n  }\n  const auto encoded = result.dump();\n  if (std::fprintf(stderr, "HS274_BASELINE_PROBE %s\\n", encoded.c_str()) < 0 || std::fflush(stderr) != 0) {\n    throw hs274_stream_protocol::native_acquisition_error(hs274_stream_protocol::native_fault::reference_receipt_write_failed);\n  }\n}',
        "",
    )
    source = replace_once(
        source,
        "capture_inventory(IOHIDDeviceRef device, std::uint64_t identity)",
        "capture_inventory(IOHIDDeviceRef device)",
    )
    source = replace_once(
        source,
        '  json result{{"version", 2u}, {"device", std::to_string(identity)}, {"coverage", "fixture_only"},\n              {"capacity", hs274_stream_protocol::keyboard_inventory_capacity},\n              {"enumerated", elements.value != nullptr}, {"exhausted", false}, {"elements", json::array()}};\n',
        "  observation.enumerated = elements.value != nullptr;\n",
    )
    source = replace_once(
        source,
        'if (inventory.full()) { result["exhausted"] = true; break; }',
        "if (inventory.full()) { observation.exhausted = true; break; }",
    )
    source = replace_once(
        source,
        '      result["elements"].push_back({{"page", page}, {"usage", usage}, {"cookie", cookie}, {"sample", sample},\n          {"relative", descriptor.relative}, {"array", descriptor.array}, {"bits", descriptor.bits},\n          {"count", descriptor.count}, {"minimum", descriptor.minimum}, {"maximum", descriptor.maximum}});\n',
        "",
    )
    source = replace_once(
        source,
        '  result["readable"] = inventory.finish(result.at("enumerated").get<bool>(), result.at("exhausted").get<bool>());\n  const auto encoded = result.dump();\n  if (std::fprintf(stderr, "HS274_KEY_INVENTORY %s\\n", encoded.c_str()) < 0 || std::fflush(stderr) != 0) {\n    throw hs274_stream_protocol::native_acquisition_error(hs274_stream_protocol::native_fault::inventory_receipt_write_failed);\n  }\n  observation.enumerated = result.at("enumerated").get<bool>();\n  observation.exhausted = result.at("exhausted").get<bool>();\n',
        "  inventory.finish(observation.enumerated, observation.exhausted);\n",
    )
    return replace_once(
        source,
        "// Disposable fixture acquisition probe, never a complete-coverage declaration.",
        "// Owned per-element acquisition, never a native queue fence or complete-coverage declaration.",
    )


def owned_stream_record(source):
    """Retain the shared raw value and finite capture type, without a global sink."""
    return replace_once(
        source,
        '// Bound only this short fixture observation. Any exhaustion invalidates coverage.\ninline capture<4096> fixture;\n\ninline bool finish() {\n  const auto state = fixture.read();\n  std::printf("HS274_RAW_CAPTURE {\\"coverage\\":\\"fixture_only\\",\\"seen\\":%" PRIu64\n              ",\\"overflow\\":%" PRIu64 ",\\"contention\\":%" PRIu64 ",\\"records\\":[",\n              state.seen, state.overflow, state.contention);\n  for (std::size_t i = 0; i < state.count; ++i) {\n    const auto& r = state.records[i];\n    std::printf("%s{\\"device\\":%" PRIu64 ",\\"timestamp\\":%" PRIu64 ",\\"value\\":%" PRId64\n                ",\\"has_page\\":%s,\\"has_usage\\":%s,\\"page\\":%" PRId32\n                ",\\"usage\\":%" PRId32 ",\\"sequence\\":%" PRIu64\n                ",\\"has_cookie\\":%s,\\"cookie\\":%" PRIu32 "}",\n                i ? "," : "", r.device, r.timestamp, r.value,\n                r.has_page ? "true" : "false", r.has_usage ? "true" : "false",\n                r.page, r.usage, r.sequence, r.has_cookie ? "true" : "false", r.cookie);\n  }\n  std::printf("]}\\n");\n  return std::fflush(stdout) == 0 && !std::ferror(stdout);\n}\n',
        "",
    )


def owned_inventory_source(source):
    """Expose only the original controller interruption to owned topology changes."""
    return replace_once(
        source,
        "  void peer_closed(std::uint64_t peer) {",
        "  void inventory_changed() noexcept { state_->protocol.interrupt(); }\n\n  void peer_closed(std::uint64_t peer) {",
    )


def owned_inventory_runtime(source):
    """Require an independently settled expected set before existing admission."""
    source = replace_once(
        source,
        '#include "hs274-stream-source.hpp"',
        '#include "hs274-stream-source.hpp"\n#include "ergopti-owned-native-inventory.hpp"',
    )
    source = replace_once(
        source,
        "  using monitor = source_type::native_registration;",
        "  using monitor = source_type::native_registration;\n  using inventory_type = ergoptiplus::remap::native_inventory<ergoptiplus::remap::native_interface_capacity>;\n  using inventory_watch = inventory_type::watch;",
    )
    source = replace_once(
        source,
        "  runtime() : source_(make_incarnation(), [] { return mach_absolute_time(); }) {",
        "  runtime() : source_(make_incarnation(), [] { return mach_absolute_time(); }),\n      inventory_(&source_, [](void* receiver) noexcept { static_cast<source_type*>(receiver)->inventory_changed(); }) {",
    )
    source = replace_once(
        source,
        "  json request(std::uint64_t peer, const json& input) { return source_.request(peer, input); }",
        """  json request(std::uint64_t peer, const json& input) {
    if (input.is_object() && input.contains("action") && input.at("action").is_string()) {
      const auto action = input.at("action").get<std::string>();
      if (action == "status") {
        auto result = source_.request(peer, input);
        result["ready"] = result.at("ready").get<bool>() && inventory_matches(result);
        return result;
      }
      if (action == "open" && !inventory_matches(source_.request(peer, {{"version", 1u}, {"action", "status"}})))
        throw std::runtime_error("Native interface inventory has not settled to the registered monitors");
    }
    return source_.request(peer, input);
  }

  static inventory_watch watch_inventory() {
    if (!active_) throw std::logic_error("Native inventory has no receiver owner");
    return active_->inventory_.begin();
  }""",
    )
    source = replace_once(
        source,
        "private:\n  static bool current",
        """private:
  bool inventory_matches(const json& status) const {
    std::vector<std::uint64_t> registrations;
    for (const auto& monitor : status.at("monitors")) registrations.push_back(decimal(monitor.at("device")));
    return inventory_.matches(registrations);
  }

  static bool current""",
    )
    source = replace_once(
        source,
        "source<4096, 64, 64>",
        "source<4096, 64, ergoptiplus::remap::native_interface_capacity>",
    )
    return replace_once(
        source,
        "  source_type source_;",
        "  source_type source_;\n  inventory_type inventory_;",
    )


def owned_inventory_grabber(source):
    """Resolve the manager's exact native set through the genuine entry classifier."""
    source = replace_once(
        source,
        '#include "device_grabber_details/entry.hpp"',
        '#include "device_grabber_details/entry.hpp"\n#include "hs274-stream-runtime.hpp"',
    )
    source = replace_once(
        source,
        "    hid_manager_->device_matched.connect",
        """    hid_manager_->ergopti_inventory_changed.connect([this](const auto& native_ids, bool settled, bool failed) {
      std::vector<std::uint64_t> selected;
      try {
        if (settled && !failed) {
          for (auto identity : native_ids) {
          const auto it = entries_.find(make_device_id(identity));
          if (it == entries_.end()) { failed = true; break; }
          if (type_safe::get(it->second->get_device_properties()->get_device_id()) != type_safe::get(identity)) { failed = true; break; }
          if (!it->second->get_device_properties()->get_device_identifiers().get_is_virtual_device())
            selected.push_back(type_safe::get(it->second->get_device_properties()->get_device_id()));
          }
        }
      } catch (...) { failed = true; }
      hs274_inventory_.publish(selected, settled, failed);
    });

    hid_manager_->device_matched.connect""",
    )
    source = replace_once(
        source,
        "      hid_manager_ = nullptr;",
        "      hs274_inventory_.retire();\n      hid_manager_ = nullptr;",
    )
    return replace_once(
        source,
        "  std::unique_ptr<pqrs::osx::iokit_hid_manager> hid_manager_;",
        "  hs274_stream_protocol::runtime::inventory_watch hs274_inventory_ = hs274_stream_protocol::runtime::watch_inventory();\n  std::unique_ptr<pqrs::osx::iokit_hid_manager> hid_manager_;",
    )


def owned_inventory_service_monitor(source):
    """Publish successful initial iterator settlement behind real native callbacks."""
    source = replace_once(
        source,
        "  // Methods\n",
        "  nod::signal<void(bool)> ergopti_initial_inventory;\n  nod::signal<void()> ergopti_inventory_failed;\n\n  // Methods\n",
    )
    source = replace_once(
        source,
        "  void start() {\n",
        "  void start() {\n    bool ergopti_initial_valid = true;\n    if (!ergopti_inventory_live_) ergopti_inventory_live_ = std::make_shared<bool>(true);\n",
    )
    source = replace_once(
        source,
        "        matched_callback(make_services(matched_notification_));",
        "        ergopti_initial_valid = ergopti_initial_valid && matched_notification_.valid();\n        matched_callback(make_services(matched_notification_));\n        ergopti_initial_valid = ergopti_initial_valid && matched_notification_.valid();",
    )
    source = replace_once(
        source,
        "        terminated_callback(make_services(terminated_notification_));",
        "        ergopti_initial_valid = ergopti_initial_valid && terminated_notification_.valid();\n        terminated_callback(make_services(terminated_notification_));\n        ergopti_initial_valid = ergopti_initial_valid && terminated_notification_.valid();",
    )
    source = replace_once(
        source,
        "    //\n    // Setup scan timer",
        """    const bool ergopti_success = ergopti_initial_valid && matched_notification_.get() && terminated_notification_.get();
    enqueue_to_dispatcher([this, weak = std::weak_ptr<bool>(ergopti_inventory_live_), ergopti_success] {
      const auto live = weak.lock();
      if (!live || !*live) return;
      ergopti_initial_inventory(ergopti_success);
    });

    //
    // Setup scan timer""",
    )
    source = replace_once(
        source,
        "  void stop() {\n",
        "  void stop() {\n    ergopti_inventory_live_.reset();\n",
    )
    source = replace_once(
        source,
        "          invoke_service_matched(*registry_entry_id, s);\n        });\n      }",
        "          invoke_service_matched(*registry_entry_id, s);\n        });\n      } else {\n        enqueue_to_dispatcher([this, weak = std::weak_ptr<bool>(ergopti_inventory_live_)] { const auto live = weak.lock(); if (live && *live) ergopti_inventory_failed(); });\n      }",
    )
    source = replace_once(
        source,
        "          invoke_service_terminated(*registry_entry_id);\n        });\n      }",
        "          invoke_service_terminated(*registry_entry_id);\n        });\n      } else {\n        enqueue_to_dispatcher([this, weak = std::weak_ptr<bool>(ergopti_inventory_live_)] { const auto live = weak.lock(); if (live && *live) ergopti_inventory_failed(); });\n      }",
    )
    if source.count("    auto services = make_services(iokit_iterator(iterator));") != 2:
        raise RuntimeError("Expected both fixed native notification iterator anchors")
    source = source.replace(
        "    auto services = make_services(iokit_iterator(iterator));",
        "    const auto ergopti_entry_owner = std::weak_ptr<bool>(self->ergopti_inventory_live_);\n    const auto ergopti_iterator = iokit_iterator(iterator);\n    const bool ergopti_valid_before = ergopti_iterator.valid();\n    auto services = make_services(iokit_iterator(iterator));\n    const bool ergopti_valid = ergopti_valid_before && ergopti_iterator.valid();",
    )
    source = replace_once(
        source,
        "      self->matched_callback(services);",
        "      const auto ergopti_live = ergopti_entry_owner.lock();\n      if (!ergopti_live || !*ergopti_live) return;\n      if (!ergopti_valid) self->enqueue_to_dispatcher([self, weak = ergopti_entry_owner] { const auto live = weak.lock(); if (live && *live) self->ergopti_inventory_failed(); });\n      self->matched_callback(services);",
    )
    source = replace_once(
        source,
        "      self->terminated_callback(services);",
        "      const auto ergopti_live = ergopti_entry_owner.lock();\n      if (!ergopti_live || !*ergopti_live) return;\n      if (!ergopti_valid) self->enqueue_to_dispatcher([self, weak = ergopti_entry_owner] { const auto live = weak.lock(); if (live && *live) self->ergopti_inventory_failed(); });\n      self->terminated_callback(services);",
    )
    source = replace_once(
        source,
        "              auto services = make_services(adopt_iokit_iterator(it));",
        "              const auto ergopti_iterator = iokit_iterator(it);\n              const bool ergopti_valid_before = ergopti_iterator.valid();\n              auto services = make_services(adopt_iokit_iterator(it));\n              if (!ergopti_valid_before || !ergopti_iterator.valid()) ergopti_inventory_failed();",
    )
    source = replace_once(
        source,
        "                  invoke_service_matched(*registry_entry_id, s);\n                }",
        "                  invoke_service_matched(*registry_entry_id, s);\n                } else {\n                  ergopti_inventory_failed();\n                }",
    )
    return replace_once(
        source,
        "  pqrs::not_null_shared_ptr_t<cf::run_loop_thread> run_loop_thread_;",
        "  std::shared_ptr<bool> ergopti_inventory_live_;\n  pqrs::not_null_shared_ptr_t<cf::run_loop_thread> run_loop_thread_;",
    )


def owned_inventory_hid_manager(source):
    """Settle all original watchers and delayed matches, without a timer guess."""
    source = replace_once(
        source,
        "#include <unordered_map>",
        '#include <unordered_map>\n#include "ergopti-owned-native-inventory.hpp"',
    )
    source = replace_once(
        source,
        "  // Methods\n",
        "  nod::signal<void(const std::vector<iokit_registry_entry_id::value_t>&, bool, bool)> ergopti_inventory_changed;\n\n  // Methods\n",
    )
    source = replace_once(
        source,
        "    for (const auto& matching_dictionary : matching_dictionaries_) {",
        "    ergopti_inventory_live_ = std::make_shared<bool>(true);\n    ergopti_watcher_count_ = matching_dictionaries_.size();\n    for (const auto& matching_dictionary : matching_dictionaries_) {",
    )
    source = replace_once(
        source,
        "        monitor->service_matched.connect([this](auto&& registry_entry_id, auto&& service_ptr) {",
        """        monitor->ergopti_initial_inventory.connect([this, weak = std::weak_ptr<bool>(ergopti_inventory_live_), identity = pqrs::unwrap_not_null(monitor).get()](bool success) {
          const auto live = weak.lock();
          if (!live || !*live) return;
          if (!success) ergopti_failed_ = true;
          try { ergopti_completed_watchers_.insert(identity); } catch (...) { ergopti_failed_ = true; }
          ergopti_publish();
        });
        monitor->ergopti_inventory_failed.connect([this, weak = std::weak_ptr<bool>(ergopti_inventory_live_)] { const auto live = weak.lock(); if (live && *live) { ergopti_failed_ = true; ergopti_publish(); } });
        monitor->service_matched.connect([this](auto&& registry_entry_id, auto&& service_ptr) {""",
    )
    source = replace_once(
        source,
        "          if (devices_.find(registry_entry_id) == std::end(devices_)) {",
        "          if (devices_.find(registry_entry_id) == std::end(devices_)) {\n            ergopti_publish(false);",
    )
    source = replace_once(
        source,
        "                  [this, registry_entry_id, device_ptr] {",
        "                  [this, registry_entry_id, device_ptr, weak = std::weak_ptr<bool>(ergopti_inventory_live_)] {\n                    const auto live = weak.lock();\n                    if (!live || !*live) return;",
    )
    source = replace_once(
        source,
        "                    device_matched_called_ids_.insert(registry_entry_id);",
        "                    device_matched_called_ids_.insert(registry_entry_id);\n                    ergopti_publish();",
    )
    source = replace_once(
        source,
        "                  when);\n            }",
        "                  when);\n            } else {\n              ergopti_failed_ = true;\n              ergopti_publish();\n            }",
    )
    source = replace_once(
        source,
        "          if (it != std::end(devices_)) {",
        "          if (it != std::end(devices_)) {\n            ergopti_publish(false);",
    )
    source = replace_once(
        source,
        "              // (The device is disconnected before `deviec_matched` is called.)\n              return;",
        "              // (The device is disconnected before `deviec_matched` is called.)\n              ergopti_publish();\n              return;",
    )
    source = replace_once(
        source,
        "            device_matched_called_ids_.erase(registry_entry_id);",
        "            device_matched_called_ids_.erase(registry_entry_id);\n            ergopti_publish();",
    )
    source = replace_once(
        source,
        "        monitor->error_occurred.connect([this](auto&& message, auto&& r) {",
        "        monitor->error_occurred.connect([this](auto&& message, auto&& r) {\n          ergopti_failed_ = true;\n          ergopti_publish();",
    )
    source = replace_once(
        source,
        "      }\n    }\n  }\n\n  // This method is executed in the dispatcher thread.\n  void stop()",
        "      } else {\n        ergopti_failed_ = true;\n      }\n    }\n    ergopti_publish();\n  }\n\n  // This method is executed in the dispatcher thread.\n  void stop()",
    )
    source = replace_once(
        source,
        "  void stop() {\n",
        "  void stop() {\n    ergopti_inventory_live_.reset();\n    ergopti_inventory_changed({}, false, ergopti_failed_);\n",
    )
    source = replace_once(
        source,
        "    device_matched_called_ids_.clear();",
        "    device_matched_called_ids_.clear();\n    ergopti_completed_watchers_.clear();\n    ergopti_watcher_count_ = 0;\n    ergopti_failed_ = false;",
    )
    return replace_once(
        source,
        "  pqrs::not_null_shared_ptr_t<cf::run_loop_thread> run_loop_thread_;",
        """  void ergopti_publish(bool may_settle = true) noexcept {
    bool settled = may_settle && ergopti_watcher_count_ && ergopti_completed_watchers_.size() == ergopti_watcher_count_;
    if (devices_.size() > ergoptiplus::remap::native_interface_capacity) ergopti_failed_ = true;
    try {
      std::vector<iokit_registry_entry_id::value_t> identities;
      if (!ergopti_failed_) {
        identities.reserve(devices_.size());
        for (const auto& [identity, device] : devices_) {
          settled = settled && device_matched_called_ids_.contains(identity);
          identities.push_back(identity);
        }
      }
      ergopti_inventory_changed(identities, settled && !ergopti_failed_, ergopti_failed_);
    } catch (...) {
      ergopti_failed_ = true;
      ergopti_inventory_changed({}, false, true);
    }
  }

  std::shared_ptr<bool> ergopti_inventory_live_;
  std::unordered_set<const iokit_service_monitor*> ergopti_completed_watchers_;
  std::size_t ergopti_watcher_count_ = 0;
  bool ergopti_failed_ = false;
  pqrs::not_null_shared_ptr_t<cf::run_loop_thread> run_loop_thread_;""",
    )


def owned_input_values_queue_acquisition(source):
    """Refuse a missing native queue before device open or started publication."""
    source = replace_once(
        source,
        "    if (observe_input_values_) {\n      start_input_values_queue();\n    }\n",
        '    if (observe_input_values_ && !start_input_values_queue()) {\n      enqueue_to_dispatcher([this] {\n        // A null create has no native IOReturn; report only the observed failure.\n        error_occurred("IOHIDQueueCreate returned null.", kIOReturnError);\n      });\n      // Preserve the existing open timer\'s retry and requested-options ownership.\n      return;\n    }\n',
    )
    source = replace_once(
        source,
        "  void start_input_values_queue() {",
        "  bool start_input_values_queue() {",
    )
    return replace_once(
        source,
        "        IOHIDQueueStart(*input_values_queue_);\n      }\n    }\n  }\n",
        "        IOHIDQueueStart(*input_values_queue_);\n      }\n    }\n    return static_cast<bool>(input_values_queue_);\n  }\n",
    )
