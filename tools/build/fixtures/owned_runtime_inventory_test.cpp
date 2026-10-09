// Actual projected pqrs watcher/manager and actual assembled monitor/runtime.
// IOKit, CF run loop and dispatcher scheduling are explicitly modeled ports.
#include <pqrs/osx/iokit_hid_manager.hpp>
#include "hid_device_events_monitor.hpp"
#include "assembled_inventory_callback.hpp"
#include "actual_virtual_classifier.hpp"
#include <iostream>
#include <map>
#include <stdexcept>
using runtime = hs274_stream_protocol::runtime;
using hs274_stream_protocol::json;
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
json status(runtime& owner) { return owner.request(9, {{"version", 1u}, {"action", "status"}}); }
struct native_fixture {
  producer_ports::element key{7, 41, 141};
  producer_ports::device device;
  explicit native_fixture(std::uint64_t identity) {
    device.identity = identity;
    device.elements = {&key}; device.baseline = {{&key, 0, 1}};
  }
};
struct fixture_entry {
  std::shared_ptr<krbn::device_properties> properties;
  std::unique_ptr<krbn::hid_device_events_monitor> monitor;
  const auto& get_device_properties() const { return properties; }
};
struct inventory_callbacks {
  runtime& receiver;
  pqrs::osx::iokit_hid_manager* hid_manager_ = nullptr;
  std::map<krbn::device_id, std::shared_ptr<fixture_entry>> entries_;
#ifndef LEGACY_NATIVE_INVENTORY
  runtime::inventory_watch hs274_inventory_ = runtime::watch_inventory();
#endif
  std::shared_ptr<pqrs::cf::run_loop_thread> loop;
  bool premature = false, first_open_allowed = false, failed_inventory = false;
  unsigned delivered = 0, terminated = 0, errors = 0;
  std::uint64_t virtual_id = 0, mismatch_id = 0, omitted_monitor = 0;
  krbn::device_id make_device_id(const krbn::device_id& identity) const { return krbn::make_device_id(identity); }
  inventory_callbacks(runtime& owner, std::shared_ptr<pqrs::cf::run_loop_thread> run_loop)
      : receiver(owner), loop(std::move(run_loop)) {}
  void connect(pqrs::osx::iokit_hid_manager& manager) {
    hid_manager_ = &manager;
#ifndef LEGACY_NATIVE_INVENTORY
    connect_actual_inventory();
    manager.ergopti_inventory_changed.connect([this](auto&&, bool, bool failed) {
      failed_inventory = failed_inventory || failed;
      if (delivered == 1) premature = premature || status(receiver).at("ready").get<bool>();
    });
#endif
    manager.device_matched.connect([this](auto identity, auto device) {
      auto entry = std::make_shared<fixture_entry>();
      entry->properties = std::make_shared<krbn::device_properties>(krbn::device_properties{
          type_safe::get(identity) == mismatch_id ? krbn::device_id(type_safe::get(identity) + 1) : identity, "Ordinary physical interface", {krbn::iokit_utility::is_karabiner_virtual_hid_device(
              "pqrs.org", type_safe::get(identity) == virtual_id ? "Karabiner DriverKit VirtualHIDKeyboard" : "Ordinary physical interface")}});
      if (type_safe::get(identity) != omitted_monitor) entry->monitor = std::make_unique<krbn::hid_device_events_monitor>(
          std::weak_ptr<pqrs::dispatcher::dispatcher>{}, loop, *device, *entry->properties,
          krbn::hid_device_events_monitor::configuration{});
      entries_.insert_or_assign(identity, entry);
      if (entry->monitor) entry->monitor->async_start(0, std::chrono::milliseconds(0));
      ++delivered;
      // The first callback is still inside the real manager before its original
      // called-ID acknowledgement, while another enumerated ID remains pending.
      if (delivered == 1) {
        premature = status(receiver).at("ready").get<bool>();
        auto preparation = receiver.request(19, {{"version", 1u}, {"action", "prepare"}});
        try {
          receiver.request(19, {{"version", 1u}, {"action", "open"},
              {"incarnation", preparation.at("incarnation")}, {"preparation", preparation.at("preparation")}});
          first_open_allowed = true;
        } catch (const std::runtime_error&) {}
        receiver.peer_closed(19);
      }
    });
    manager.device_terminated.connect([this](auto identity) { entries_.erase(identity); ++terminated; });
    manager.error_occurred.connect([this](auto&&, auto&&) { ++errors; });
  }
#ifndef LEGACY_NATIVE_INVENTORY
  void connect_actual_inventory();
#endif
};
#ifndef LEGACY_NATIVE_INVENTORY
#include "assembled_inventory_callback_body.hpp"
#endif
json lease(runtime& receiver) {
  auto preparation = receiver.request(9, {{"version", 1u}, {"action", "prepare"}});
  auto opening = receiver.request(9, {{"version", 1u}, {"action", "open"},
      {"incarnation", preparation.at("incarnation")}, {"preparation", preparation.at("preparation")}});
  require(opening.at("coverage") == "fixture_only", "No native completeness may be claimed");
  auto request = json{{"version", 1u}, {"action", "baseline"}, {"incarnation", opening.at("incarnation")}, {"lease", opening.at("lease")}};
  auto page = receiver.request(9, request);
  for (;;) {
    request["baseline_ack"] = std::to_string(page.at("next").get<std::size_t>());
    auto receipt = receiver.request(9, request);
    if (receipt.at("kind") == "baseline_ready") break;
    page = receipt;
  }
  return opening;
}
json pull(runtime& receiver, const json& opening) {
  return receiver.request(9, {{"version", 1u}, {"action", "pull"}, {"incarnation", opening.at("incarnation")}, {"lease", opening.at("lease")}});
}
void refuse_open(runtime& receiver) {
  auto preparation = receiver.request(19, {{"version", 1u}, {"action", "prepare"}});
  bool refused = false;
  try { receiver.request(19, {{"version", 1u}, {"action", "open"},
      {"incarnation", preparation.at("incarnation")}, {"preparation", preparation.at("preparation")}}); }
  catch (const std::runtime_error&) { refused = true; }
  receiver.peer_closed(19);
  require(refused, "Actual open must refuse incomplete expected native inventory");
}
void watcher_restart_failure(const std::string& scenario) {
#ifdef LEGACY_NATIVE_INVENTORY
  (void)scenario;
  throw std::runtime_error("Predecessor has no owned watcher publication API");
#else
  native_fixture original(71), fresh(72);
  inventory_ports::dictionary dictionary{0};
  auto loop = std::make_shared<pqrs::cf::run_loop_thread>();
  auto& native = inventory_ports::watchers[0];
  if (scenario == "queued-identity-failure") original.device.identity_available = false;
  native.initial = {&original.device};
  pqrs::osx::iokit_service_monitor watcher(std::weak_ptr<pqrs::dispatcher::dispatcher>{}, loop, &dictionary);
  unsigned failures = 0, successes = 0;
  watcher.ergopti_inventory_failed.connect([&] { ++failures; });
  watcher.ergopti_initial_inventory.connect([&](bool success) { if (success) ++successes; });
  watcher.async_start(); pqrs::cf::run_loop_thread::pump();
  if (scenario.starts_with("native-entry-")) {
    pqrs::dispatcher::pump(std::chrono::milliseconds(0)); successes = 0;
    // The real old native callback runs after successor stop/start are queued,
    // but before either task executes on the modeled CF run-loop port.
    watcher.async_stop(); watcher.async_start();
    native.iterator_valid = scenario.ends_with("identity");
    original.device.identity_available = !scenario.ends_with("identity");
    inventory_ports::notify(0, scenario.starts_with("native-entry-terminated"), {&original.device});
    native.initial = {&fresh.device}; native.iterator_valid = true;
    pqrs::cf::run_loop_thread::pump(); pqrs::dispatcher::pump(std::chrono::milliseconds(0));
    require(failures == 0 && successes == 1, "Native callback entry must retain its original watcher ownership across queued stop/start");
    return;
  }
  if (scenario == "queued-iterator-failure") {
    pqrs::dispatcher::pump(std::chrono::milliseconds(0)); successes = 0;
    native.iterator_valid = false;
    inventory_ports::notify(0, false, {&original.device}); pqrs::cf::run_loop_thread::pump();
  }
  // Newly queued owned failures remain pending on the still-attached real
  // service object across stop/start; dispatcher destruction cannot hide them.
  watcher.async_stop(); pqrs::cf::run_loop_thread::pump();
  native.initial = {&fresh.device}; native.iterator_valid = true;
  watcher.async_start(); pqrs::cf::run_loop_thread::pump();
  pqrs::dispatcher::pump(std::chrono::milliseconds(0));
  require(failures == 0 && successes == 1, "Retired watcher failures may not poison its successor incarnation");
#endif
}
int main(int argc, char** argv) {
  try {
    require(argc == 2, "One independent inventory scenario is required");
    const std::string scenario = argv[1];
    const std::vector<std::string> scenarios{"late-duplicate", "late-absent-termination", "pending", "pending-open", "failed-watcher", "failed-port", "failed-run-loop-source", "failed-terminated-watcher", "invalid-iterator", "invalid-drain", "create-failure", "missing-identity", "entry-mismatch", "missing-monitor", "capacity", "duplicate", "virtual", "consumer-only", "terminated-during-delay", "stop-restart-stale", "hotplug-lease", "hotplug-pending-baseline", "later-invalid-notification", "later-invalid-scan", "later-scan-error", "native-element-read-failure", "native-value-read-failure", "zero-native-identity", "stale-owner-publication", "same-watch-create-error", "create-error-recovery", "queued-identity-failure", "queued-iterator-failure", "native-entry-matched-iterator", "native-entry-terminated-iterator", "native-entry-matched-identity", "native-entry-terminated-identity"};
    require(std::find(scenarios.begin(), scenarios.end(), scenario) != scenarios.end(), "Unknown independent inventory scenario");
    if (scenario == "queued-identity-failure" || scenario == "queued-iterator-failure" || scenario.starts_with("native-entry-")) {
      watcher_restart_failure(scenario);
      std::cout << "PASS actual assembled inventory " << scenario << "; modeled platform ports only\n";
      return 0;
    }
    native_fixture first(41), second(42);
    std::vector<std::unique_ptr<native_fixture>> many;
    auto& native = inventory_ports::watchers;
    native[0].initial = {&first.device};
    native[1].initial = {&second.device};
    if (scenario == "failed-watcher") native[6].match_ok = false;
    if (scenario == "failed-port") native[6].port_ok = false;
    if (scenario == "failed-run-loop-source") native[6].source_ok = false;
    if (scenario == "failed-terminated-watcher") native[6].terminate_ok = false;
    if (scenario == "invalid-iterator") native[6].iterator_valid = false;
    if (scenario == "invalid-drain") native[6].invalidate_on_exhaustion = true;
    if (scenario == "create-failure" || scenario == "create-error-recovery" || scenario == "same-watch-create-error") inventory_ports::create_failures[&second.device] = true;
    if (scenario == "native-element-read-failure") second.device.enumerated = false;
    if (scenario == "native-value-read-failure") second.device.baseline.clear();
    if (scenario == "zero-native-identity") second.device.identity = 0;
    if (scenario == "missing-identity") second.device.identity_available = false;
    if (scenario == "duplicate" || scenario == "late-absent-termination") native[2].initial = {&first.device};
    if (scenario == "consumer-only") { second.key.page = 12; second.key.usage = 128; }
    if (scenario == "capacity") {
      native[0].initial.clear(); native[1].initial.clear();
      for (unsigned i = 0; i < 65; ++i) {
        many.push_back(std::make_unique<native_fixture>(i + 100)); native[0].initial.push_back(&many.back()->device);
      }
    }
    auto loop = std::make_shared<pqrs::cf::run_loop_thread>();
    std::array<inventory_ports::dictionary, 7> dictionaries;
    std::vector<pqrs::cf::cf_ptr<CFDictionaryRef>> matching;
    for (unsigned i = 0; i < 7; ++i) { dictionaries[i].index = i; matching.emplace_back(&dictionaries[i]); }
    runtime receiver;
    inventory_callbacks callbacks(receiver, loop);
    if (scenario == "virtual" || scenario == "entry-mismatch") callbacks.virtual_id = 42;
    if (scenario == "entry-mismatch") callbacks.mismatch_id = 42;
    if (scenario == "missing-monitor") callbacks.omitted_monitor = 42;
    auto manager = std::make_unique<pqrs::osx::iokit_hid_manager>(
        std::weak_ptr<pqrs::dispatcher::dispatcher>{}, loop, matching, std::chrono::milliseconds(1000));
    callbacks.connect(*manager);
    manager->async_start();
    pqrs::dispatcher::pump(std::chrono::milliseconds(0));
    inventory_ports::quiesce();
    require(!status(receiver).at("ready").get<bool>(), "No delayed callback may be replaced by a started clock");
    if (scenario == "terminated-during-delay") {
      inventory_ports::notify(1, true, {&second.device}); inventory_ports::quiesce();
    }
    if (scenario == "stop-restart-stale") {
      manager->async_stop(); pqrs::dispatcher::pump(std::chrono::milliseconds(0));
      manager->async_start(); pqrs::dispatcher::pump(std::chrono::milliseconds(0)); inventory_ports::quiesce();
    }
    if (scenario == "capacity") require(callbacks.failed_inventory, "Expected interface capacity must refuse before any monitor callback");
    pqrs::dispatcher::pump(std::chrono::milliseconds(999));
    require(callbacks.delivered == 0, "Original 1000ms native delivery delay must survive");
    pqrs::dispatcher::pump(std::chrono::milliseconds(1000));
    if (scenario == "pending" || scenario == "pending-open") {
      if (scenario == "pending") require(!callbacks.premature, "A started registration must not admit unresolved expected native interfaces");
      if (scenario == "pending-open") require(!callbacks.first_open_allowed, "Actual open must not admit pending native interfaces even if status is unused");
      require(callbacks.delivered == 2 && status(receiver).at("ready").get<bool>(),
              "Ordinary admission must recover after all exact interfaces settle");
    } else if (scenario == "failed-watcher" || scenario == "invalid-iterator" ||
               scenario == "create-failure" || scenario == "missing-identity" || scenario == "entry-mismatch" || scenario == "invalid-drain" ||
               scenario == "failed-port" || scenario == "failed-run-loop-source" || scenario == "failed-terminated-watcher" ||
               scenario == "missing-monitor" || scenario == "capacity" || scenario == "create-error-recovery" || scenario == "same-watch-create-error" ||
               scenario == "native-element-read-failure" || scenario == "native-value-read-failure" || scenario == "zero-native-identity") {
      require(!status(receiver).at("ready").get<bool>(), "Invalid or missing native inventory must refuse admission");
      refuse_open(receiver);
    } else if (scenario == "terminated-during-delay") {
      require(callbacks.delivered == 1 && callbacks.terminated == 0 && status(receiver).at("ready").get<bool>(),
              "A native termination before delay must not deliver an orphan callback or invented termination");
    } else {
      require(status(receiver).at("ready").get<bool>(), "Successful empty watchers must permit exact settled admission");
      require(callbacks.delivered == 2, "Duplicate matches must retain exactly two original callbacks");
      require(status(receiver).at("monitors").size() == (scenario == "virtual" ? 1 : 2),
              "Actual virtual classifier must conserve selected registration cardinality");
    }
    if (scenario == "late-duplicate") {
      auto opening = lease(receiver);
      inventory_ports::notify(2, false, {&first.device}); inventory_ports::quiesce();
      require(status(receiver).at("ready").get<bool>() && callbacks.delivered == 2,
              "A late native alias match must conserve the settled expected set and original dedupe");
      require(pull(receiver, opening).at("kind") == "batch", "Unchanged aliased topology must preserve the admitted lease");
      receiver.peer_closed(9);
    }
    if (scenario == "late-absent-termination") {
      inventory_ports::notify(0, true, {&first.device}); inventory_ports::quiesce();
      require(status(receiver).at("ready").get<bool>() && callbacks.terminated == 1,
              "The genuine first termination must settle the remaining expected interface");
      auto opening = lease(receiver);
      // A second original matching watcher retained this same native alias.
      // Its genuine termination signal now finds no manager device to remove.
      inventory_ports::notify(2, true, {&first.device}); inventory_ports::quiesce();
      require(status(receiver).at("ready").get<bool>() && callbacks.terminated == 1,
              "A late absent native termination must conserve exact remaining topology");
      require(pull(receiver, opening).at("kind") == "batch", "Absent termination may not interrupt the current lease");
      receiver.peer_closed(9);
    }
    if (scenario == "later-invalid-notification" || scenario == "later-invalid-scan" || scenario == "later-scan-error") {
      auto opening = lease(receiver);
      if (scenario == "later-scan-error") native[0].scan_ok = false; else native[0].iterator_valid = false;
      if (scenario == "later-invalid-notification") inventory_ports::notify(0, false, {&first.device});
      else {
        require(pqrs::dispatcher::extra_timer::instances.at(0)->cadence_ == std::chrono::milliseconds(3000),
                "The original periodic scan cadence must remain 3000ms");
        pqrs::dispatcher::extra_timer::instances.at(0)->fire();
      }
      inventory_ports::quiesce();
      require(!status(receiver).at("ready").get<bool>(), "Failed later native inventory must revoke admission");
      require(pull(receiver, opening).at("kind") == "lost", "Failed later inventory must interrupt the actual old lease");
      receiver.peer_closed(9);
    }
    if (scenario == "hotplug-pending-baseline") {
      auto preparation = receiver.request(9, {{"version", 1u}, {"action", "prepare"}});
      auto opening = receiver.request(9, {{"version", 1u}, {"action", "open"},
          {"incarnation", preparation.at("incarnation")}, {"preparation", preparation.at("preparation")}});
      native_fixture third(43); inventory_ports::notify(2, false, {&third.device}); inventory_ports::quiesce();
      auto baseline = receiver.request(9, {{"version", 1u}, {"action", "baseline"},
          {"incarnation", opening.at("incarnation")}, {"lease", opening.at("lease")}});
      require(baseline.at("kind") == "lost" && baseline.at("reason") == "interrupted",
              "Native inventory invalidation must retire the actual retained baseline before delivery");
      inventory_ports::notify(2, true, {&third.device}); inventory_ports::quiesce(); receiver.peer_closed(9);
    }
    if (scenario == "hotplug-lease") {
      auto opening = lease(receiver);
      native_fixture third(43);
      inventory_ports::notify(2, false, {&third.device}); inventory_ports::quiesce();
      require(callbacks.delivered == 2 && !status(receiver).at("ready").get<bool>(),
              "Native inventory invalidation must precede original delayed hotplug delivery");
      auto retired = pull(receiver, opening);
      require(retired.at("kind") == "lost" && retired.at("reason") == "interrupted",
              "The existing controller must interrupt the actual admitted old lease immediately");
      pqrs::dispatcher::pump(std::chrono::milliseconds(2000));
      require(callbacks.delivered == 3 && status(receiver).at("ready").get<bool>(),
              "Ordinary settled hotplug inventory must admit a fresh exact lease");
      receiver.peer_closed(9);
      auto recovered = lease(receiver); require(pull(receiver, recovered).at("kind") == "batch", "Fresh ordinary lease must recover");
      inventory_ports::notify(2, true, {&third.device}); inventory_ports::quiesce();
      require(callbacks.terminated == 1 && status(receiver).at("ready").get<bool>(),
              "Original termination callback and exact remaining set must settle");
      receiver.peer_closed(9);
    }
    if (scenario == "stale-owner-publication") {
#ifndef LEGACY_NATIVE_INVENTORY
      callbacks.hs274_inventory_.retire();
      auto successor = runtime::watch_inventory();
      successor.publish({41, 42}, true, false);
      require(status(receiver).at("ready").get<bool>(), "A fresh inventory owner must admit the exact registered set");
      callbacks.hs274_inventory_.publish({999}, false, true);
      require(status(receiver).at("ready").get<bool>(), "A retired predecessor may not invalidate successor ownership");
      auto opening = lease(receiver); require(pull(receiver, opening).at("kind") == "batch", "Successor lease must remain usable");
      receiver.peer_closed(9);
#endif
    }
    if (scenario == "create-error-recovery") {
      manager.reset(); inventory_ports::quiesce(); callbacks.entries_.clear();
#ifndef LEGACY_NATIVE_INVENTORY
      callbacks.hs274_inventory_.retire();
#endif
      inventory_ports::create_failures[&second.device] = false;
      inventory_callbacks fresh(receiver, loop);
      auto replacement = std::make_unique<pqrs::osx::iokit_hid_manager>(
          std::weak_ptr<pqrs::dispatcher::dispatcher>{}, loop, matching, std::chrono::milliseconds(1000));
      fresh.connect(*replacement); replacement->async_start(); inventory_ports::quiesce();
      require(!status(receiver).at("ready").get<bool>(), "Recovery must not bypass new native enumeration and delay");
      pqrs::dispatcher::pump(std::chrono::milliseconds(2000));
      require(fresh.delivered == 2 && status(receiver).at("ready").get<bool>(), "A create failure needs a fresh complete owner to recover");
      auto opening = lease(receiver); require(pull(receiver, opening).at("kind") == "batch", "Recovered ordinary lease must execute");
      receiver.peer_closed(9); replacement.reset(); inventory_ports::quiesce(); fresh.entries_.clear();
    }
    if (scenario == "same-watch-create-error") {
      manager.reset(); inventory_ports::quiesce(); callbacks.entries_.clear();
      inventory_ports::create_failures[&second.device] = false;
      auto replacement = std::make_unique<pqrs::osx::iokit_hid_manager>(
          std::weak_ptr<pqrs::dispatcher::dispatcher>{}, loop, matching, std::chrono::milliseconds(1000));
      callbacks.connect(*replacement); replacement->async_start(); inventory_ports::quiesce();
      pqrs::dispatcher::pump(std::chrono::milliseconds(2000));
      require(callbacks.delivered == 3 && !status(receiver).at("ready").get<bool>(),
              "Manager restart with the same failed inventory watch may not clear owned failure");
      require(status(receiver).at("native_fault") == "none", "Inventory failure may not invent a sticky native device fault");
      replacement.reset(); inventory_ports::quiesce(); callbacks.entries_.clear();
    }
    manager.reset();
    inventory_ports::quiesce();
#ifndef LEGACY_NATIVE_INVENTORY
    require(!status(receiver).at("ready").get<bool>(), "Native stop must revoke inventory authority");
#endif
    callbacks.entries_.clear();
    require(inventory_ports::destroys == ((scenario == "stop-restart-stale" || scenario == "create-error-recovery" || scenario == "same-watch-create-error") ? 14u : (scenario == "failed-port" ? 6u : 7u)), "Original notification-port RAII must release each watcher exactly once");
    std::cout << "PASS actual assembled inventory " << scenario << "; modeled platform ports only\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
