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
    return owned_queue_monitor(source.replace("hs274_probe_device_id_", "hs274_capture_device_id_"))


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
    return owned_queue_runtime(owned_inventory_runtime(source))


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
    return owned_queue_source(
        replace_once(
            source,
            "  void peer_closed(std::uint64_t peer) {",
            "  void inventory_changed() noexcept { state_->protocol.interrupt(); }\n\n  void peer_closed(std::uint64_t peer) {",
        )
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
    source = replace_once(
        source,
        "        IOHIDQueueStart(*input_values_queue_);\n      }\n    }\n  }\n",
        "        IOHIDQueueStart(*input_values_queue_);\n      }\n    }\n    return static_cast<bool>(input_values_queue_);\n  }\n",
    )
    return owned_queue_vendor(owned_input_values_queue_errors(source))


def owned_input_values_queue_errors(source):
    """Route active queue callback failures through the existing original signal."""
    source = replace_once(
        source,
        "  static void static_input_values_available_callback(void* context,\n"
        "                                                     IOReturn result,\n"
        "                                                     void* sender) {\n"
        "    if (result != kIOReturnSuccess) {\n"
        "      return;\n"
        "    }\n\n"
        "    auto self = static_cast<iokit_hid_device_events_monitor*>(context);\n"
        "    if (!self) {\n"
        "      return;\n"
        "    }\n\n"
        "    self->input_values_available_callback();\n"
        "  }\n",
        "  static void static_input_values_available_callback(void* context,\n"
        "                                                     IOReturn result,\n"
        "                                                     void* sender) {\n"
        "    auto self = static_cast<iokit_hid_device_events_monitor*>(context);\n"
        "    if (!self) {\n"
        "      return;\n"
        "    }\n\n"
        "    if (result != kIOReturnSuccess) {\n"
        "      self->input_values_error_callback(result);\n"
        "      return;\n"
        "    }\n\n"
        "    self->input_values_available_callback();\n"
        "  }\n",
    )
    return replace_once(
        source,
        "  void input_values_available_callback() {\n",
        "  void input_values_error_callback(IOReturn result) {\n"
        "    // IOKit may invoke callbacks while device open has failed or stopped.\n"
        "    // Preserve closed-device silence and the original dispatcher signal.\n"
        "    {\n"
        "      std::lock_guard<std::mutex> lock(open_options_mutex_);\n"
        "      if (!current_open_options_) {\n"
        "        return;\n"
        "      }\n"
        "    }\n\n"
        "    iokit_return r = result;\n"
        "    enqueue_to_dispatcher([this, r] {\n"
        '      error_occurred("input values callback error", r);\n'
        "    });\n"
        "  }\n\n"
        "  void input_values_available_callback() {\n",
    )


QUEUE_SOURCE_DECLARATIONS = '\n  class monitor;\n  class queue_interval;\n  class queue_snapshot final {\n  public:\n    queue_snapshot() = default;\n    bool current() const noexcept {\n      auto owner=owner_.lock();\n      return owner && token_ && owner->queue_revision==revision_ && owner->ready() && owner->find(token_);\n    }\n    std::uint64_t device() const noexcept { return frozen_.device; }\n    std::uint64_t cut_at() const noexcept { return boundary_; }\n  private:\n    friend class source;\n    friend class queue_interval;\n    queue_snapshot(std::weak_ptr<state> owner, std::uint64_t token, std::uint64_t revision,\n                   std::uint64_t boundary, typename baseline::device_state frozen)\n        : owner_(std::move(owner)), token_(token), revision_(revision), boundary_(boundary), frozen_(std::move(frozen)) {}\n    std::weak_ptr<state> owner_;\n    std::uint64_t token_=0, revision_=0, boundary_=0;\n    typename baseline::device_state frozen_{};\n  };\n  class queue_interval final {\n  public:\n    queue_interval() = default;\n    bool current() const noexcept {\n      auto owner=owner_.lock();\n      return owner && token_ && owner->queue_revision==revision_ && owner->ready() && owner->find(token_);\n    }\n    queue_snapshot freeze(std::uint64_t boundary) const {\n      if (!current()) throw std::logic_error("Native queue interval changed before folded snapshot");\n      auto owner=owner_.lock();\n      const auto current=owner->find(token_);\n      typename baseline::device_state frozen{current->device, current->keyboard,\n          current->keys ? current->keys->snapshot(boundary) : std::vector<typename baseline::element>{}, current->keyboard_type};\n      return queue_snapshot(owner,token_,revision_,boundary,std::move(frozen));\n    }\n  private:\n    friend class monitor;\n    queue_interval(std::weak_ptr<state> owner, std::uint64_t token) : owner_(std::move(owner)),token_(token) {\n      if (auto state=owner_.lock()) revision_=state->queue_revision;\n    }\n    std::weak_ptr<state> owner_;\n    std::uint64_t token_=0, revision_=0;\n  };\n  baseline freeze_queue_snapshots(const std::vector<queue_snapshot>& snapshots, std::uint64_t boundary) const {\n    if (!state_->ready()) throw std::logic_error("Queue snapshot source is not ready");\n    std::size_t count=0;\n    for (const auto& row:state_->monitors) count+=row.token!=0;\n    if (snapshots.size()!=count) throw std::logic_error("Queue snapshot interface set is incomplete");\n    std::vector<typename baseline::device_state> devices;\n    for (const auto& row:snapshots) {\n      if (!row.current() || row.boundary_>boundary || row.owner_.owner_before(state_) || state_.owner_before(row.owner_))\n        throw std::logic_error("Queue snapshot ownership or clock changed");\n      for (const auto& previous:devices) if (previous.device==row.device()) throw std::logic_error("Duplicate queue snapshot");\n      devices.push_back(row.frozen_);\n    }\n    return baseline(boundary,std::move(devices));\n  }\n'

QUEUE_VENDOR_DECLARATIONS = "\n  class owned_queue_receipt final {\n  public:\n    owned_queue_receipt() = default;\n    bool current() const noexcept {\n      const auto owner=owner_.lock();\n      return owner && owner->owned_queue_current(generation_);\n    }\n  private:\n    friend class iokit_hid_device_events_monitor;\n    owned_queue_receipt(const std::shared_ptr<iokit_hid_device_events_monitor>& owner, std::uint64_t generation)\n        : owner_(owner),generation_(generation) {}\n    std::weak_ptr<iokit_hid_device_events_monitor> owner_;\n    std::uint64_t generation_=0;\n  };\n\n  // Supply this exact native instance and retain its original signal receiver.\n  // Call only from that receiver's dispatcher. No input-report cut is claimed.\n  bool async_owned_queue_cut(std::shared_ptr<iokit_hid_device_events_monitor> owner,\n                             std::shared_ptr<void> receiver_lifetime,\n                             std::function<void(owned_queue_receipt)> completion) {\n    if (owner.get()!=this || !receiver_lifetime || !completion || !dispatcher_thread()) return false;\n    std::uint64_t generation;\n    {\n      std::lock_guard<std::mutex> lock(open_options_mutex_);\n      generation=requested_open_options_generation_;\n      if (!owned_queue_options_current(generation)) return false;\n    }\n    run_loop_thread_->enqueue(^{\n      auto values=std::make_shared<std::vector<cf::cf_ptr<IOHIDValueRef>>>();\n      bool complete=false;\n      try {\n        if (owner->owned_queue_current(generation) && owner->input_values_queue_) {\n          ergoptiplus::remap::queue_drain_budget<4096> budget;\n          while (budget.take()) {\n            auto value=cf::adopt_cf_ptr(IOHIDQueueCopyNextValueWithTimeout(*owner->input_values_queue_,0.0));\n            if (!value) { complete=budget.complete(); break; }\n            values->emplace_back(std::move(value));\n          }\n        }\n      } catch (...) { complete=false; }\n      // Previously queued value callbacks precede this handoff. This run-loop\n      // task enqueues its retained vector and receipt in one dispatcher action;\n      // callbacks subsequently enqueued cannot precede that folded snapshot.\n      const bool posted=owner->enqueue_to_dispatcher([owner,receiver_lifetime,completion,values,generation,complete] {\n        const bool before=owner->owned_queue_current(generation);\n        if (before && !values->empty()) owner->input_values_arrived(values);\n        if (before && complete && owner->owned_queue_current(generation))\n          completion(owned_queue_receipt(owner,generation));\n        else completion({});\n      });\n      // No callback is fabricated on dispatcher refusal. The original caller's\n      // finite request deadline must refuse unsettled work and retain its debt.\n      if (!posted || !complete) {\n        owner->run_loop_thread_->enqueue(^{ owner->input_values_available_callback(); });\n      }\n    });\n    return true;\n  }\n"

QUEUE_VENDOR_PRIVATE = "\n  bool owned_queue_options_current(std::uint64_t generation) const noexcept {\n    // Called only while holding the original acquisition mutex.\n    return generation && generation==requested_open_options_generation_ && generation==owned_queue_open_generation_ &&\n        requested_open_options_ && current_open_options_ &&\n        *requested_open_options_==*current_open_options_ && observe_input_values_ &&\n        input_report_buffer_.empty() && !owned_queue_failed_;\n  }\n  bool owned_queue_current(std::uint64_t generation) const noexcept {\n    std::lock_guard<std::mutex> lock(open_options_mutex_);\n    return owned_queue_options_current(generation);\n  }\n  bool owned_queue_failed_=false;\n  std::uint64_t owned_queue_open_generation_=0;\n"

QUEUE_MONITOR_DECLARATIONS = "\n  class owned_queue_cut final {\n  public:\n    owned_queue_cut() = default;\n    bool current() const noexcept { return native_.current() && folded_.current(); }\n    std::uint64_t device() const noexcept { return folded_.device(); }\n    const hs274_stream_protocol::runtime::queue_snapshot& snapshot() const noexcept { return folded_; }\n  private:\n    friend class hid_device_events_monitor;\n    owned_queue_cut(pqrs::osx::iokit_hid_device_events_monitor::owned_queue_receipt native,\n                    hs274_stream_protocol::runtime::queue_snapshot folded)\n        : native_(std::move(native)),folded_(std::move(folded)) {}\n    pqrs::osx::iokit_hid_device_events_monitor::owned_queue_receipt native_;\n    hs274_stream_protocol::runtime::queue_snapshot folded_;\n  };\n\n  // Preserve both original monitor lifetimes; retaining the native child alone\n  // would leave its signal callbacks with a dangling high-level receiver.\n  bool async_owned_queue_cut(std::shared_ptr<hid_device_events_monitor> owner,\n                            std::function<void(owned_queue_cut)> completion) {\n    if (owner.get()!=this || !completion || !dispatcher_thread()) return false;\n    auto interval=hs274_monitor_.capture_queue_interval();\n    if (!interval.current()) return false;\n    return device_events_monitor_->async_owned_queue_cut(device_events_monitor_,owner,\n        [owner,interval,completion](auto native) {\n          if (!native.current() || !interval.current()) { completion({}); return; }\n          hs274_stream_protocol::runtime::queue_snapshot folded;\n          try { folded=interval.freeze(mach_absolute_time()); }\n          catch (...) { completion({}); return; }\n          if (!native.current() || !folded.current()) { completion({}); return; }\n          completion(owned_queue_cut(std::move(native),std::move(folded)));\n        });\n  }\n"


def owned_queue_source(source):
    """Add separate queue-cut revisions and immutable folded snapshots."""
    source = replace_once(
        source,
        "    std::uint64_t serial = 0;",
        "    std::uint64_t serial = 0;\n    std::uint64_t queue_revision = 1;",
    )
    source = replace_once(
        source,
        "    void native_fail(native_fault reason) noexcept {",
        "    void invalidate_queue() noexcept {\n      if (queue_revision == UINT64_MAX) { exhausted=true; protocol.interrupt(); }\n      else ++queue_revision;\n    }\n\n    void native_fail(native_fault reason) noexcept {\n      invalidate_queue();",
    )
    # Every existing interrupted ownership path invalidates only the new cut.
    source = source.replace(
        "owner->protocol.interrupt();", "owner->invalidate_queue(); owner->protocol.interrupt();"
    )
    source = source.replace(
        "state_->protocol.interrupt();", "state_->invalidate_queue(); state_->protocol.interrupt();"
    )
    source = replace_once(
        source,
        "        current->ready = true;",
        "        owner->invalidate_queue();\n        current->ready = true;",
    )
    source = replace_once(
        source,
        "  baseline freeze(std::uint64_t boundary) const {",
        QUEUE_SOURCE_DECLARATIONS + "\n  baseline freeze(std::uint64_t boundary) const {",
    )
    return replace_once(
        source,
        "    native_owner_fence capture_fence() const noexcept { return native_owner_fence(owner_, token_); }",
        "    queue_interval capture_queue_interval() const noexcept { return queue_interval(owner_, token_); }\n    native_owner_fence capture_fence() const noexcept { return native_owner_fence(owner_, token_); }",
    ).replace(
        "    native_fault reason() const noexcept { return reason_; }",
        "    queue_interval capture_queue_interval() const noexcept { return active() ? owner_.capture_queue_interval() : queue_interval{}; }\n    native_fault reason() const noexcept { return reason_; }",
    )


def owned_queue_monitor(source):
    """Expose native queue receipts while retaining both actual monitor owners."""
    return replace_once(
        source,
        "  void async_start(IOOptionBits open_options,",
        QUEUE_MONITOR_DECLARATIONS + "\n  void async_start(IOOptionBits open_options,",
    )


def owned_queue_vendor(source):
    """Drain the real native queue on its existing serialized run loop."""
    source = replace_once(
        source,
        "#include <IOKit/hid/IOHIDQueue.h>",
        '#include <IOKit/hid/IOHIDQueue.h>\n#include "ergopti-owned-queue-fence.hpp"',
    )
    source = replace_once(
        source,
        "  [[nodiscard]] bool seized() const {",
        QUEUE_VENDOR_DECLARATIONS + "\n  [[nodiscard]] bool seized() const {",
    )
    source = replace_once(
        source,
        "private:\n  void schedule_device() {",
        "private:\n" + QUEUE_VENDOR_PRIVATE + "\n  void schedule_device() {",
    )
    source = replace_once(
        source,
        "    IOOptionBits open_options = kIOHIDOptionsTypeNone;",
        "    IOOptionBits open_options = kIOHIDOptionsTypeNone;\n    std::uint64_t owned_queue_open_generation=0;",
    )
    source = replace_once(
        source,
        "      open_options = *requested_open_options_;",
        "      open_options = *requested_open_options_;\n      owned_queue_open_generation=requested_open_options_generation_;",
    )
    source = replace_once(
        source,
        "      current_open_options_ = open_options;",
        "      current_open_options_ = open_options;\n      owned_queue_open_generation_=owned_queue_open_generation;",
    )
    source = replace_once(
        source,
        "      open_options = current_open_options_;",
        "      open_options = current_open_options_;\n      owned_queue_open_generation_=0;",
    )
    return replace_once(
        source,
        "  void input_values_error_callback(IOReturn result) {",
        "  void input_values_error_callback(IOReturn result) {\n    { std::lock_guard<std::mutex> lock(open_options_mutex_); if (current_open_options_) owned_queue_failed_=true; }",
    )


def owned_queue_runtime(source):
    """Expose folded snapshots; installed complete admission remains separate."""
    source = replace_once(
        source,
        "  using monitor = source_type::native_registration;",
        "  using monitor = source_type::native_registration;\n  using queue_snapshot = source_type::queue_snapshot;",
    )
    return replace_once(
        source,
        "  void peer_closed(std::uint64_t peer)",
        '  static source_type::baseline freeze_queue_snapshots(std::uint64_t peer, const std::vector<queue_snapshot>& snapshots) {\n    if (!active_) throw std::logic_error("Queue cut has no native runtime owner");\n    if (!active_->inventory_matches(active_->source_.request(peer, {{"version",1u},{"action","status"}})))\n      throw std::logic_error("Queue cut expected native interfaces changed");\n    return active_->source_.freeze_queue_snapshots(snapshots,mach_absolute_time());\n  }\n\n  void peer_closed(std::uint64_t peer)',
    )


def owned_idle_receiver(source):
    """Keep the Core idle until a current authenticated Console starts capture.

    A retained system configuration never grants capture admission at startup
    or after the Console lifetime ends. The original authenticated request,
    native device-start implementation and stop behavior remain unchanged.
    """
    source = replace_once(
        source,
        "\n    start_grabbing_if_system_core_configuration_file_exists();\n",
        "\n",
    )
    return replace_once(
        source,
        "      stop_device_grabber();\n"
        "      start_grabbing_if_system_core_configuration_file_exists();\n",
        "      stop_device_grabber();\n",
    )


def owned_idle_core_project(source):
    """Bind the signed idle-service revision to the actual gate-applied Core build."""
    if source.count("PRODUCT_BUNDLE_IDENTIFIER: com.ergoptiplus.remap.core") != 1:
        raise RuntimeError("Expected exact owned Core project identity")
    return replace_once(
        source,
        "      CODE_SIGN_ENTITLEMENTS: ''\n",
        "      INFOPLIST_KEY_ErgoptiOwnedCoreIdleAdmissionRevision: '1'\n"
        "      CODE_SIGN_ENTITLEMENTS: ''\n",
    )
