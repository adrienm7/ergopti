// Execute the actual assembled monitor, runtime and baseline acquisition with
// modeled native ports. No physical, Darwin queue or complete-coverage credit.
#include "hid_device_events_monitor.hpp"
#include "assembled_shutdown.hpp"
#include <dlfcn.h>
#include <iostream>
#include <stdexcept>
using hs274_stream_protocol::json;
using native_monitor = pqrs::osx::iokit_hid_device_events_monitor;
using runtime = hs274_stream_protocol::runtime;
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
struct fixture {
  producer_ports::element escape{7, 41, 141}, space{7, 44, 144}, consumer{12, 128, 228};
  producer_ports::device device;
  fixture() {
    device.elements = {&escape, &space, &consumer};
    device.baseline = {{&escape, 1, 5}, {&space, 0, 6}, {&consumer, 1, 7}};
  }
};
std::unique_ptr<krbn::hid_device_events_monitor> monitor(fixture& input) {
  return std::make_unique<krbn::hid_device_events_monitor>(
      std::weak_ptr<pqrs::dispatcher::dispatcher>{}, std::make_shared<pqrs::cf::run_loop_thread>(),
      &input.device, krbn::device_properties{41, "HS274 CI Keyboard", {}},
      krbn::hid_device_events_monitor::configuration{});
}
json status(runtime& owner) { return owner.request(9, {{"version", 1u}, {"action", "status"}}); }
json request_for(const json& opening, const char* action) {
  return {{"version", 1u}, {"action", action}, {"incarnation", opening.at("incarnation")},
          {"lease", opening.at("lease")}};
}
json open(runtime& owner) {
  auto preparation = owner.request(9, {{"version", 1u}, {"action", "prepare"}});
  auto opening = owner.request(9, {{"version", 1u}, {"action", "open"},
      {"incarnation", preparation.at("incarnation")}, {"preparation", preparation.at("preparation")}});
  require(opening.at("coverage") == "fixture_only", "Production must not claim complete coverage");
  require(opening.at("baseline").at("version") == 2u, "Baseline-v2 must remain active");
  auto request = request_for(opening, "baseline");
  auto page = owner.request(9, request);
  require(page.at("rows").size() == 4 && page.at("rows").at(0).at("kind") == "device",
          "Whole keyboard and consumer inventory must survive projection");
  require(page.at("rows").at(1).at("cookie") == 141 && page.at("rows").at(1).at("down") == true &&
          page.at("rows").at(1).at("timestamp") == "5", "Held Escape identity must survive");
  require(page.at("rows").at(3).at("page") == 12 && page.at("rows").at(3).at("cookie") == 228 &&
          page.at("rows").at(3).at("down") == true, "Held consumer identity must survive");
  request["baseline_ack"] = std::to_string(page.at("next").get<std::size_t>());
  require(owner.request(9, request).at("kind") == "baseline_ready", "Baseline must settle before raw input");
  return opening;
}
void route() {
  fixture input;
  runtime owner;
#ifndef TEST_DIAGNOSTIC_PROFILE
  auto inventory = runtime::watch_inventory();
  inventory.publish({input.device.identity}, input.device.enumerated, false);
#endif
  auto ordinary = monitor(input);
  unsigned original_started = 0, original_stopped = 0;
  std::size_t original_delivered = 0;
  ordinary->started.connect([&] { ++original_started; });
  ordinary->stopped.connect([&] { ++original_stopped; });
  ordinary->values_arrived.connect([&](auto values) { original_delivered += values->size(); });
  ordinary->async_start(0, std::chrono::milliseconds(1));
  require(original_started == 1 && status(owner).at("ready") == true,
          "Actual started callback must preserve ordinary delivery and qualified source");
  auto opening = open(owner);
  auto pull = request_for(opening, "pull");
  std::size_t delivered = 0;
  constexpr std::size_t count = 5000; // greater than the frozen 4096-value diagnostic mirror.
  while (delivered < count) {
    std::vector<producer_ports::value> values;
    const auto batch = std::min<std::size_t>(32, count - delivered);
    for (std::size_t index = 0; index < batch; ++index) {
      const auto ordinal = delivered + index;
      auto leaf = ordinal % 5 == 4 ? &input.consumer : &input.escape;
      const auto held = ordinal % 4 == 1 || ordinal % 4 == 2;
      values.push_back({leaf, held ? 1 : 0, 1000 + ordinal});
    }
    native_monitor::current->deliver(values);
    const auto response = owner.request(9, pull);
    require(response.at("kind") == "batch" && response.at("coverage") == "fixture_only" &&
            response.at("records").size() == batch, "Actual producer must retain every bounded batch");
    for (std::size_t index = 0; index < batch; ++index) {
      const auto& record = response.at("records").at(index);
      const auto ordinal = delivered + index;
      const auto& expected = values.at(index);
      require(record.at("sequence") == std::to_string(ordinal + 1) && record.at("device") == "41" &&
              record.at("timestamp") == std::to_string(expected.timestamp) &&
              record.at("value") == std::to_string(expected.integer) && record.at("has_cookie") == true &&
              record.at("cookie") == expected.leaf->cookie && record.at("page") == expected.leaf->page &&
              record.at("usage") == expected.leaf->usage, "Raw order, repeat and native element identity must survive");
    }
    delivered += batch;
    pull["ack"] = std::to_string(delivered);
  }
  require(original_delivered == count, "Ordinary remapping output must remain whole beyond finite capacity");
  require(owner.request(9, pull).at("records").empty(), "Final acknowledgement must drain the real producer");
#ifdef TEST_DIAGNOSTIC_PROFILE
  const auto mirror = hs274_raw_capture::fixture.read();
  require(mirror.seen == count && mirror.count == 4096 && mirror.overflow == count - 4096,
          "Independent original diagnostic finite mirror must remain whole");
  require(producer_ports::cached_reads == 5 && producer_ports::updated_reads == 2,
          "Original diagnostic two-key reference probe must remain whole");
#else
  require(producer_ports::cached_reads == 3 && producer_ports::updated_reads == 0,
          "Owned producer must not execute the diagnostic two-key reference probe");
  // Inspect a restored experimental sink if a causal mutant reintroduces it.
  // The normal owned projection defines no sink. This observes real runtime
  // state rather than accepting a source spelling as proof of no mirroring.
  if (auto sink = dlsym(nullptr, "_ZN17hs274_raw_capture7fixtureE")) {
    const auto mirror = static_cast<hs274_raw_capture::capture<4096>*>(sink)->read();
    require(mirror.seen == 0, "Owned producer must not mirror input into the finite diagnostic sink");
  }
#endif
  ordinary->async_stop();
  require(original_stopped == 1 && status(owner).at("ready") == false,
          "Real stopped callback must revoke readiness without suppressing the original callback");
  require(owner.request(9, pull).at("kind") == "lost", "Stop must invalidate the exact active lease");
  ordinary.reset();
  require(native_monitor::current == nullptr && status(owner).at("monitors").empty(),
          "Actual destructor must retire the source registration and native owner");
  owner.peer_closed(9);
}
void acquisition(const std::string& scenario) {
  fixture input;
  runtime owner;
#ifndef TEST_DIAGNOSTIC_PROFILE
  auto inventory = runtime::watch_inventory();
  inventory.publish({input.device.identity}, input.device.enumerated, false);
#endif
  auto ordinary = monitor(input);
  if (scenario == "changed-identity") input.device.identity = 42;
  if (scenario == "allocation") producer_ports::allocation_refused = true;
  ordinary->async_start(0, std::chrono::milliseconds(1));
  const auto observed = status(owner);
  if (scenario == "closed-stderr") {
    require(observed.at("ready") == true && observed.at("native_fault") == "none",
            "Owned baseline acquisition must not depend on raw diagnostic stderr receipts");
  } else if (scenario == "changed-identity") {
    require(observed.at("ready") == false && observed.at("monitors").at(0).at("refusal") ==
            "changed_native_provenance", "Actual provenance revalidation must remain fail closed");
  } else {
    require(observed.at("ready") == false && observed.at("native_fault") == "acquisition_resource_exhausted",
            "Actual acquisition resource fault must remain sticky");
  }
}
int main(int argc, char** argv) {
  try {
    require(argc == 2, "One bounded behavior scenario is required");
    const std::string scenario = argv[1];
    if (scenario == "route") route();
    else if (scenario == "shutdown") return assembled_shutdown();
    else acquisition(scenario);
    std::cout << "PASS actual assembled producer " << scenario << "; modeled native ports only\n";
    return 0;
  } catch (const std::exception& failure) {
    std::cerr << failure.what() << '\n'; return 1;
  }
}
