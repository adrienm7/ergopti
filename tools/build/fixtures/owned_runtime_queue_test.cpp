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
// Independent queue-error controls frozen before the owned error projection.
// Actual vendor callback/drain bodies execute through modeled IOKit ports only.
constexpr IOReturn injected_queue_error = -73;
constexpr IOReturn injected_open_error = -79;
struct queue_error_control {
  fixture input;
  runtime owner;
  runtime::inventory_watch watcher;
  std::unique_ptr<krbn::hid_device_events_monitor> monitor;
  producer_ports::value escape_release{&input.escape, 0, 1000};
  producer_ports::value space_press{&input.space, 1, 1001};
  unsigned started = 0, stopped = 0, delivered_values = 0;
  std::vector<std::string> delivered, messages;
  std::vector<pqrs::osx::iokit_return> results;
  queue_error_control() : watcher(runtime::watch_inventory()) {
    watcher.publish({41}, true, false);
    monitor = std::make_unique<krbn::hid_device_events_monitor>(
        std::weak_ptr<pqrs::dispatcher::dispatcher>{}, std::make_shared<pqrs::cf::run_loop_thread>(),
        &input.device, krbn::device_properties{41, "HS274 CI Keyboard", {}},
        krbn::hid_device_events_monitor::configuration{});
    monitor->started.connect([&] { ++started; delivered.push_back("started"); });
    monitor->stopped.connect([&] { ++stopped; delivered.push_back("stopped"); });
    monitor->values_arrived.connect([&](auto values) {
      delivered.push_back("values");
      require(values->size() == 2 && values->at(0).get_usage() == 41 &&
              values->at(0).get_integer_value() == 0 && values->at(0).get_time_stamp() == 1000 &&
              values->at(1).get_usage() == 44 && values->at(1).get_integer_value() == 1 &&
              values->at(1).get_time_stamp() == 1001,
              "The original remapping callback must retain both independent values in order");
      delivered_values += values->size();
    });
    monitor->error_occurred.connect([&](const std::string& message, pqrs::osx::iokit_return result) {
      require(!result, "An injected nonzero native callback result must never become success");
      delivered.push_back("error"); messages.push_back(message); results.push_back(result);
    });
  }
  void start() {
    monitor->async_start(0, std::chrono::milliseconds(1)); queue_ports::settle();
    require(started == 1 && messages.empty() && status(owner).at("ready") == true,
            "The actual healthy acquisition must precede every active queue-error control");
    require(queue_ports::native_queue.callback != nullptr && queue_ports::native_queue.context != nullptr,
            "The test must use the callback registered by the actual vendor class");
  }
  json lease() {
    auto opened = opening(owner);
    require(opened.at("coverage") == "fixture_only", "Queue-error controls never qualify complete coverage");
    json request{{"version", 1u}, {"action", "baseline"}, {"incarnation", opened.at("incarnation")},
                 {"lease", opened.at("lease")}};
    const auto page = owner.request(9, request);
    require(page.at("rows").size() == 4, "The existing complete fixture baseline remains unchanged");
    request["baseline_ack"] = std::to_string(page.at("next").get<std::size_t>());
    require(owner.request(9, request).at("kind") == "baseline_ready", "The exact lease must acknowledge its own baseline");
    return {{"version", 1u}, {"action", "pull"}, {"incarnation", opened.at("incarnation")},
            {"lease", opened.at("lease")}};
  }
  void callback(IOReturn result) {
    auto& queue = queue_ports::native_queue;
    require(queue.callback && queue.context, "A real registered callback and live context are mandatory");
    queue.callback(queue.context, result, &queue);
  }
  void values() {
    queue_ports::native_queue.values = {&escape_release, &space_press};
    callback(kIOReturnSuccess);
    require(queue_ports::queue_reads == 3 && queue_ports::native_queue.values.empty(),
            "The actual unchanged vendor loop must copy both modeled values then observe null");
  }
  void error(const json& pull) {
    require(messages.empty(), "No earlier native failure may satisfy the queue-error assertion");
    callback(injected_queue_error);
    require(messages.empty() && status(owner).at("ready") == true,
            "The original error signal and revocation remain dispatcher-owned");
    queue_ports::dispatcher();
    require(messages == std::vector<std::string>{"input values callback error"} &&
            results.size() == 1 && results[0] == pqrs::osx::iokit_return(injected_queue_error),
            "An active queue error must forward exactly its original nonzero IOReturn");
    require(status(owner).at("ready") == false && owner.request(9, pull).at("kind") == "lost",
            "The actual wrapper must revoke physical readiness and the exact active lease on queue error");
    require(queue_ports::closes == 0 && queue_ports::creates == 1 && queue_ports::opens == 1 && started == 1,
            "A queue error must not close, reopen or manufacture a successful acquisition");
  }
  void finish() {
    monitor->async_stop(); queue_ports::settle(); monitor.reset(); queue_ports::settle();
    require(status(owner).at("ready") == false && status(owner).at("monitors").empty(),
            "Final settled fixture stop and registration retirement must remain whole");
    owner.peer_closed(9);
  }
};
void queue_error_case(const std::string& scenario) {
  queue_ports::reset();
  queue_error_control control;
  if (scenario == "error-unopened") {
    queue_ports::open_result = injected_open_error;
    control.monitor->async_start(0, std::chrono::milliseconds(1)); queue_ports::settle();
    require(control.started == 0 && control.messages == std::vector<std::string>{"IOHIDDeviceOpen is failed."} &&
            control.results.size() == 1 && control.results[0] == pqrs::osx::iokit_return(injected_open_error) &&
            status(control.owner).at("ready") == false,
            "The genuine queue-before-open path must retain its independent native open refusal");
    control.callback(injected_queue_error); queue_ports::dispatcher();
    require(control.messages.size() == 1 && control.started == 0 && queue_ports::queue_reads == 0 &&
            status(control.owner).at("ready") == false,
            "A callback error from an unopened device must not add an error or grant readiness");
  } else {
    control.start();
    auto pull = control.lease();
    if (scenario == "error-healthy-values") {
      control.values(); queue_ports::dispatcher();
      const auto batch = control.owner.request(9, pull);
      require(batch.at("kind") == "batch" && batch.at("records").size() == 2 &&
              batch.at("records")[0].at("cookie") == 141 && batch.at("records")[0].at("sequence") == "1" &&
              batch.at("records")[0].at("timestamp") == "1000" && batch.at("records")[0].at("value") == "0" &&
              batch.at("records")[1].at("cookie") == 144 && batch.at("records")[1].at("sequence") == "2" &&
              batch.at("records")[1].at("timestamp") == "1001" && batch.at("records")[1].at("value") == "1" &&
              control.delivered_values == 2 && control.messages.empty() && status(control.owner).at("ready") == true,
              "Successful queue delivery must preserve raw identities, timestamps, order and readiness");
    } else if (scenario == "error-stopped") {
      control.monitor->async_stop(); queue_ports::settle();
      control.callback(injected_queue_error); queue_ports::dispatcher();
      require(control.messages.empty() && control.started == 1 && control.stopped == 1 &&
              status(control.owner).at("ready") == false && control.owner.request(9, pull).at("kind") == "lost",
              "A retained callback with a live closed monitor must not add failure or revive its stopped lease");
    } else if (scenario == "error-pending-values") {
      control.values(); control.callback(injected_queue_error);
      require(control.delivered == std::vector<std::string>{"started"} && control.messages.empty(),
              "No dispatcher callback may be manufactured by modeled native enqueue");
      queue_ports::dispatcher();
      require(control.delivered == std::vector<std::string>{"started", "values", "error"} &&
              control.messages == std::vector<std::string>{"input values callback error"} && control.results.size() == 1 &&
              control.results[0] == pqrs::osx::iokit_return(injected_queue_error) && control.delivered_values == 2 &&
              status(control.owner).at("ready") == false && control.owner.request(9, pull).at("kind") == "lost",
              "Same-client FIFO must deliver original values before the error revokes its exact physical lease");
    } else {
      control.error(pull);
      if (scenario == "error-active") {
        control.values(); queue_ports::dispatcher();
        require(control.delivered_values == 2 && control.messages.size() == 1 && status(control.owner).at("ready") == false,
                "Later original remapping values must not silently recover physical readiness after queue error");
      } else if (scenario == "error-restart") {
        // Loss keeps the old preparation owned until the caller retires it.
        control.owner.peer_closed(9);
        control.monitor->async_stop(); queue_ports::settle();
        control.monitor->async_start(kIOHIDOptionsTypeSeizeDevice, std::chrono::milliseconds(1)); queue_ports::settle();
        require(control.delivered == std::vector<std::string>{"started", "error", "stopped", "started"} &&
                control.started == 2 && control.stopped == 1 && control.monitor->seized() &&
                status(control.owner).at("ready") == true && opening(control.owner).at("coverage") == "fixture_only",
                "Only a genuine fresh stopped/started acquisition may recover through its own baseline");
      } else throw std::runtime_error("Unknown independent queue-error scenario");
    }
  }
  control.finish();
}
int main(int argc, char** argv) {
  try {
    const std::string scenario = argc == 2 ? argv[1] : "";
    if (scenario == "null-queue" || scenario == "healthy" || scenario == "retry-recovery" || scenario == "failed-stop-restart")
      owned_case(scenario);
    else if (scenario == "unobserved-values") unobserved_values();
    else if (scenario == "pending-native-before-dispatch") pending_failure_before_dispatch();
    else if (scenario == "error-healthy-values" || scenario == "error-active" || scenario == "error-unopened" ||
             scenario == "error-stopped" || scenario == "error-restart" || scenario == "error-pending-values") queue_error_case(scenario);
    else throw std::runtime_error("Unknown independent queue acquisition scenario");
    std::cout << "PASS actual vendor queue acquisition " << scenario << "; modeled native ports only\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
