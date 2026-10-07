// TEST-ONLY fixed official broker observation through the actual owned upper
// and lower client graph. Requires separately qualified same-UID root Guardian.
// This fixture never initializes devices, installs/activates a DEXT or captures.
#include <pqrs/karabiner/driverkit/virtual_hid_device_service/client.hpp>
#include <pqrs/dispatcher/extra/shared_dispatcher.hpp>
#include <atomic>
#include <chrono>
#include <iostream>
#include <memory>
#include <thread>
#include <unistd.h>

int main() {
  if (::geteuid() != 0) {
    std::cout << "{\"qualification\":\"UNQUALIFIED\",\"reason\":\"official_broker_root_worker_required\"}\n";
    return 66;
  }
  namespace vhd = ergoptiplus::remap::vhd;
  using client = pqrs::karabiner::driverkit::virtual_hid_device_service::client;
  using namespace std::chrono_literals;
  pqrs::dispatcher::extra::initialize_shared_dispatcher();
  auto owner = vhd::broker_owner::acquire();
  auto cohort = std::make_unique<client>(owner);
  std::atomic<unsigned> connected{0}, warnings{0};
  cohort->connected.connect([&] { ++connected; });
  cohort->warning_reported.connect([&](const std::string&) { ++warnings; });
  cohort->async_start();
  const auto observe_until = std::chrono::steady_clock::now() + 4s;
  while (connected == 0 && warnings == 0 && std::chrono::steady_clock::now() < observe_until)
    std::this_thread::sleep_for(10ms);
  cohort->async_stop();
  owner->retire();
  const auto retire_until = std::chrono::steady_clock::now() + 4s;
  while (!owner->retired() && std::chrono::steady_clock::now() < retire_until)
    std::this_thread::sleep_for(10ms);
  const bool acknowledged = owner->retired();
  // Failure keeps both cohort and owner alive until process retirement. A caller
  // must obtain the actual Guardian process ACK before retiring its credentials.
  if (!acknowledged) {
    cohort.release();
    std::cout << "{\"qualification\":\"UNQUALIFIED\",\"reason\":\"official_broker_native_retirement_unqualified\"}\n";
    return 70;
  }
  cohort.reset();
  pqrs::dispatcher::extra::terminate_shared_dispatcher();
  const bool observed = connected == 1;
  std::cout << "{\"qualification\":\"" << (observed ? "BROKER_OBSERVATION_ONLY" : "UNQUALIFIED")
            << "\",\"connected_callbacks\":" << connected << ",\"warnings\":" << warnings
            << ",\"native_broker_executed\":1,\"actual_native_close_ack\":true,\"capture_qualified\":false}\n";
  return observed ? 0 : 66;
}
