// tools/build/fixtures/owned_runtime_queue_test.cpp
// Handwritten queue-acquisition controls on the genuine vendor class and T2 wrapper.
// All native/scheduler ports are modeled; no physical delivery or cutover qualification.
#include "hid_device_events_monitor.hpp"
#include <iostream>
#include <stdexcept>
#include <memory>
using runtime = hs274_stream_protocol::runtime;
using hs274_stream_protocol::json;
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
json status(runtime& owner) { return owner.request(9, {{"version", 1u}, {"action", "status"}}); }
json opening(runtime& owner) {
  const auto preparation = owner.request(9, {{"version", 1u}, {"action", "prepare"}});
  return owner.request(9, {{"version", 1u}, {"action", "open"},
      {"incarnation", preparation.at("incarnation")}, {"preparation", preparation.at("preparation")}});
}
void readable_cache(fixture& input) {
  const auto observed = hs274_baseline_probe::capture_inventory(&input.device);
  require(observed.enumerated && !observed.exhausted && observed.samples.size() == 3,
          "The failed-queue control must retain a healthy keyboard/consumer cached inventory");
  require(observed.samples[0].cookie == 141 && observed.samples[0].status == 0 &&
          observed.samples[0].returned_value && observed.samples[0].value == 1 && observed.samples[0].timestamp == 5,
          "Real cached baseline read must preserve held Escape despite queue-create failure");
  require(observed.samples[1].cookie == 144 && observed.samples[1].status == 0 && observed.samples[1].value == 0 &&
          observed.samples[2].cookie == 228 && observed.samples[2].status == 0 && observed.samples[2].value == 1,
          "Released Space and held consumer baseline remain independently readable");
}
void refused(runtime& owner) {
  require(status(owner).at("ready") == false, "Null queue creation must not qualify cached readiness");
  bool failed = false;
  try { (void)opening(owner); } catch (const std::exception&) { failed = true; }
  require(failed, "Null queue creation must not permit opening a capture lease");
  owner.peer_closed(9);
}
void acquired(runtime& owner, unsigned started) {
  require(started == 1 && status(owner).at("ready") == true, "Healthy native acquisition must preserve original started");
  const auto opened = opening(owner);
  require(opened.at("coverage") == "fixture_only", "Acquisition prerequisite must never claim complete coverage");
  require(queue_ports::creates == 1 && queue_ports::adds == 3 && queue_ports::queue_starts == 1 && queue_ports::opens == 1,
          "Healthy actual vendor class must create/add/start its queue before opening its device");
  require(queue_ports::order == std::vector<std::string>{"create", "queue-start", "device-open"},
          "The original queue-before-open order must remain whole");
}
void owned_case(const std::string& scenario) {
  queue_ports::reset();
  fixture input;
  runtime owner;
  auto watcher = runtime::watch_inventory();
  watcher.publish({41}, true, false);
  auto monitor = std::make_unique<krbn::hid_device_events_monitor>(
      std::weak_ptr<pqrs::dispatcher::dispatcher>{}, std::make_shared<pqrs::cf::run_loop_thread>(),
      &input.device, krbn::device_properties{41, "HS274 CI Keyboard", {}},
      krbn::hid_device_events_monitor::configuration{});
  unsigned started = 0, stopped = 0, errors = 0;
  std::string message;
  monitor->started.connect([&] { ++started; });
  monitor->stopped.connect([&] { ++stopped; });
  monitor->error_occurred.connect([&](const std::string& text, pqrs::osx::iokit_return result) {
    require(!result, "Queue null failure must never be reported as success"); ++errors; message = text;
  });
  if (scenario == "healthy") {
    monitor->async_start(0, std::chrono::milliseconds(1)); queue_ports::settle();
    acquired(owner, started); require(errors == 0, "Healthy creation must not emit a failure");
  } else {
    queue_ports::creation_fails = true;
    readable_cache(input);
    monitor->async_start(0, std::chrono::milliseconds(1)); queue_ports::settle();
    require(queue_ports::creates == 1 && queue_ports::opens == 0 && queue_ports::adds == 0 && queue_ports::queue_starts == 0,
            "Null IOHIDQueueCreate must refuse before native IOHIDDeviceOpen, add or start");
    require(started == 0 && errors == 1 && message == "IOHIDQueueCreate returned null.",
            "Failed acquisition must not emit started or invent a specific native error cause");
    refused(owner);
    if (scenario == "retry-recovery") {
      queue_ports::creation_fails = false;
      pqrs::dispatcher::extra::timer::tick(); queue_ports::settle();
      require(queue_ports::creates == 2 && queue_ports::opens == 1 && started == 1 && errors == 1,
              "Original retry owner must recover from null to a real nonnull acquisition without a new failure");
      require(status(owner).at("ready") == true && opening(owner).at("coverage") == "fixture_only",
              "Fresh healthy recovery remains only fixture coverage");
    } else if (scenario == "failed-stop-restart") {
      monitor->async_stop(); queue_ports::settle();
      require(stopped == 1 && queue_ports::closes == 0 && !monitor->seized(),
              "Stopping a failed unopened acquisition must preserve native stop without closing an unopened device");
      queue_ports::creation_fails = false;
      pqrs::dispatcher::extra::timer::tick(); queue_ports::settle();
      require(started == 0 && queue_ports::creates == 1 && queue_ports::opens == 0,
              "The stopped request must not recover when its old retry fires");
      monitor->async_start(kIOHIDOptionsTypeSeizeDevice, std::chrono::milliseconds(1)); queue_ports::settle();
      require(started == 1 && queue_ports::creates == 2 && queue_ports::opens == 1 && monitor->seized(),
              "A new requested acquisition may recover after the exact failed request stops");
      require(status(owner).at("ready") == true, "Healthy successor must qualify only through its own started callback");
    }
  }
  monitor->async_stop(); queue_ports::settle();
  require(status(owner).at("ready") == false, "Final actual stop must revoke source readiness");
  monitor.reset(); queue_ports::settle();
  require(status(owner).at("monitors").empty(), "Actual wrapper destructor must retire its native registration");
}
void unobserved_values() {
  queue_ports::reset(); queue_ports::creation_fails = true;
  fixture input;
  auto loop = std::make_shared<pqrs::cf::run_loop_thread>();
  pqrs::osx::iokit_hid_device_events_monitor::parameters options;
  options.observe_input_values = false;
  pqrs::osx::iokit_hid_device_events_monitor monitor({}, loop, &input.device, options);
  unsigned started = 0, errors = 0;
  monitor.started.connect([&] { ++started; });
  monitor.error_occurred.connect([&](auto&&, auto&&) { ++errors; });
  monitor.async_start(0, std::chrono::milliseconds(1)); queue_ports::settle();
  require(queue_ports::creates == 0 && queue_ports::opens == 1 && started == 1 && errors == 0,
          "Unobserved input values must preserve original queue-free open/started behavior");
  monitor.async_stop(); queue_ports::settle();
}
// This schedule drains the actual native start/stop jobs separately from the
// same-client dispatcher FIFO. It asserts no arbitrary cross-client ordering.
void pending_failure_before_dispatch() {
  queue_ports::reset();
  fixture input;
  runtime owner;
  auto watcher = runtime::watch_inventory();
  watcher.publish({41}, true, false);
  auto monitor = std::make_unique<krbn::hid_device_events_monitor>(
      std::weak_ptr<pqrs::dispatcher::dispatcher>{}, std::make_shared<pqrs::cf::run_loop_thread>(),
      &input.device, krbn::device_properties{41, "HS274 CI Keyboard", {}},
      krbn::hid_device_events_monitor::configuration{});
  std::vector<std::string> delivered;
  monitor->error_occurred.connect([&](const std::string& message, pqrs::osx::iokit_return result) {
    require(!result && message == "IOHIDQueueCreate returned null.", "Pending failure retains only the observed null cause");
    delivered.push_back("error");
  });
  monitor->stopped.connect([&] { delivered.push_back("stopped"); });
  monitor->started.connect([&] { delivered.push_back("started"); });
  queue_ports::creation_fails = true;
  readable_cache(input);
  monitor->async_start(0, std::chrono::milliseconds(1));
  queue_ports::run_loop();
  require(queue_ports::creates == 1 && queue_ports::opens == 0 && delivered.empty(),
          "Native failed create queues only its failure; no device open or dispatcher callback yet");
  monitor->async_stop();
  queue_ports::run_loop();
  require(queue_ports::closes == 0 && delivered.empty(), "Actual failed stop runs before successor and before dispatcher delivery");
  queue_ports::creation_fails = false;
  monitor->async_start(kIOHIDOptionsTypeSeizeDevice, std::chrono::milliseconds(1));
  queue_ports::run_loop();
  require(queue_ports::creates == 2 && queue_ports::queue_starts == 1 && queue_ports::opens == 1 &&
          monitor->seized() && delivered.empty() && status(owner).at("ready") == false,
          "Only the new healthy native acquisition opens; readiness still awaits its genuine started signal");
  queue_ports::dispatcher();
  require(delivered == std::vector<std::string>{"error", "stopped", "started"},
          "Same-client FIFO must deliver failed acquisition, completed stop, then healthy started in order");
  require(status(owner).at("ready") == true && opening(owner).at("coverage") == "fixture_only",
          "Final healthy owner recovers through actual started and preserves fixture_only coverage");
  monitor->async_stop(); queue_ports::settle(); monitor.reset(); queue_ports::settle();
  require(status(owner).at("ready") == false && status(owner).at("monitors").empty(), "Final stop and retirement preserve currentness");
}
int main(int argc, char** argv) {
  try {
    const std::string scenario = argc == 2 ? argv[1] : "";
    if (scenario == "null-queue" || scenario == "healthy" || scenario == "retry-recovery" || scenario == "failed-stop-restart")
      owned_case(scenario);
    else if (scenario == "unobserved-values") unobserved_values();
    else if (scenario == "pending-native-before-dispatch") pending_failure_before_dispatch();
    else throw std::runtime_error("Unknown independent queue acquisition scenario");
    std::cout << "PASS actual vendor queue acquisition " << scenario << "; modeled native ports only\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
