// Independent software oracles frozen before the Core receiver projection.
// Only exact original receiver callsite/helper slices are inserted below.
// Filesystem, permission and native device-start endpoints are explicit ports;
// this is not real Core, live OS ownership, or capture qualification.
#include "remap_runtime_auth_policy.hpp"
#include <iostream>
#include <optional>
#include <string>

namespace fixture_ports { inline bool configuration_exists = true; }
namespace filesystem_utility {
inline bool exists(const std::string&) { return fixture_ports::configuration_exists; }
}
namespace constants {
inline std::string get_system_core_configuration_file_path() { return "owned/core.json"; }
}
namespace logger {
struct sink { template<class... T> void info(T&&...) {} };
inline sink* get_logger() { static sink value; return &value; }
}

class receiver_ports {
public:
  int stops = 0, grabs = 0;
  bool permitted = true;
  std::optional<int> console_user_server_peer_id_ = 17;
  void* console_user_server_peer_ = this;
  bool required_permissions_granted() { return permitted; }
  void stop_device_grabber() { ++stops; }
  void start_device_grabber(const std::optional<std::string>&) { ++grabs; }
  void startup() {
// INSERT_EXACT_STARTUP_CALLSITE
  }
  void console_closed() {
// INSERT_EXACT_CONSOLE_LOSS_CALLSITE
  }
// INSERT_EXACT_ORIGINAL_SYSTEM_CONFIG_HELPER
  void admitted_request(ergoptiplus::remap::auth_policy::role peer, bool current_scope) {
    using namespace ergoptiplus::remap::auth_policy;
    const observation observed{route::daemon_server, role::core, peer, 0, 501, 501};
    // This portable predicate REQUIRES a real current owner frame. The current
    // frame boolean here is a disclosed test port, never native authority.
    if (operation_admission(observed, "start_device_grabber") !=
        admission::native_owner_frame_required || !current_scope) return;
    stop_device_grabber();
    start_device_grabber(std::string("owned/user/core.json"));
  }
};

int main() {
  int failures = 0;
  auto expect = [&](const char* name, bool accepted) {
    std::cout << (accepted ? "PASS " : "FAIL ") << name << '\n';
    if (!accepted) ++failures;
  };
  fixture_ports::configuration_exists = true;
  receiver_ports constructor;
  constructor.startup();
  expect("constructor_existing_owned_config_without_console_does_not_grab", constructor.grabs == 0);
  receiver_ports lost;
  lost.console_closed();
  expect("console_disconnect_existing_owned_config_stops_without_restart",
         lost.stops == 1 && lost.grabs == 0 && !lost.console_user_server_peer_id_ &&
         lost.console_user_server_peer_ == nullptr);
  fixture_ports::configuration_exists = false;
  receiver_ports missing;
  missing.startup();
  expect("absent_owned_config_never_grabs", missing.grabs == 0);
  using role = ergoptiplus::remap::auth_policy::role;
  receiver_ports admitted;
  admitted.admitted_request(role::console, true);
  expect("authenticated_current_console_start_retains_native_start",
         admitted.stops == 1 && admitted.grabs == 1);
  receiver_ports denied;
  denied.admitted_request(role::cli, true);
  denied.admitted_request(role::console, false);
  expect("wrong_role_or_stale_scope_refuses_console_start", denied.stops == 0 && denied.grabs == 0);
  return failures ? 1 : 0;
}
