// This must fail to compile without the explicitly named test-only macro.
#include "core_service/daemon/receiver.hpp"
namespace ergoptiplus::installed_maintenance {
class native_observer_test final {
  using observer=core_endpoint::issuer_exit;
public:
  static bool forbidden() { observer value(detail::native_birth{}); return core_endpoint::arm_issuer_monitor(value); }
};
}
int main() { return ergoptiplus::installed_maintenance::native_observer_test::forbidden() ? 0 : 1; }
