// Private controls exercise the genuine native queue-cut body with modeled ports.
#define main preserved_queue_main
#include "owned_runtime_queue_test.cpp"
#undef main
int main(int argc, char** argv) {
  try {
    const std::string scenario = argc == 2 ? argv[1] : "";
    require(scenario == "cut-healthy" || scenario == "cut-off-dispatcher" || scenario == "cut-wrong-dispatcher" || scenario == "cut-enqueue-refused",
            "Unknown independent dispatcher cut scenario");
    queue_ports::reset();
    fixture input;
    runtime owner;
    auto watcher = runtime::watch_inventory(); watcher.publish({41}, true, false);
    auto dispatcher = std::make_shared<pqrs::dispatcher::dispatcher>();
    auto monitor = std::make_shared<krbn::hid_device_events_monitor>(dispatcher,
        std::make_shared<pqrs::cf::run_loop_thread>(), &input.device,
        krbn::device_properties{41, "HS274 CI Keyboard", {}},
        krbn::hid_device_events_monitor::configuration{});
    unsigned started = 0, completions = 0;
    bool current = false;
    monitor->started.connect([&] { ++started; });
    monitor->async_start(0, std::chrono::milliseconds(1)); queue_ports::settle();
    require(started == 1 && status(owner).at("ready") == true, "Healthy acquisition must precede queue-cut controls");
    auto completion = [&](auto receipt) { ++completions; current = receipt.current(); };
    if (scenario == "cut-wrong-dispatcher") {
      auto other = std::make_shared<pqrs::dispatcher::dispatcher>();
      queue_ports::dispatcher_scope scope(other.get());
      require(!monitor->async_owned_queue_cut(monitor, completion), "A cut on another dispatcher must refuse");
      require(queue_ports::run_loop_jobs.empty() && completions == 0, "Wrong-dispatcher refusal must create no work");
    } else if (scenario == "cut-off-dispatcher") {
      require(!monitor->async_owned_queue_cut(monitor, completion), "A cut called off the dispatcher must refuse");
      require(queue_ports::run_loop_jobs.empty() && queue_ports::queue_reads == 0 && completions == 0,
              "Off-dispatcher refusal must not fabricate queue work or completion");
    } else {
      { queue_ports::dispatcher_scope scope(dispatcher.get());
        require(monitor->async_owned_queue_cut(monitor, completion), "An admitted cut must use the real vendor acquisition"); }
      require(completions == 0, "Native admission must not fabricate a synchronous cut receipt");
      if (scenario == "cut-enqueue-refused") dispatcher->terminating = true;
      queue_ports::run_loop(); queue_ports::dispatcher();
      if (scenario == "cut-healthy")
        require(completions == 1 && current && queue_ports::queue_reads == 1,
                "Healthy real queue drain must issue exactly one current folded receipt after observing empty");
      else
        require(completions == 0 && queue_ports::dispatcher_jobs.empty() && queue_ports::queue_reads >= 1,
                "Genuine failed enqueue must leave completion unsettled without a fabricated receipt");
      dispatcher->terminating = false;
    }
    monitor->async_stop(); queue_ports::settle(); monitor.reset(); queue_ports::settle();
    require(status(owner).at("monitors").empty(), "Live modeled owner must retire after controls");
    std::cout << "PASS actual vendor dispatcher cut " << scenario << "; modeled native ports only\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
