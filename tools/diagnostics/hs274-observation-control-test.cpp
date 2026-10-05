// tools/diagnostics/hs274-observation-control-test.cpp
// Pure callback-order, canonical argument and reference-result controls.
#include "hs274-observation-control.hpp"
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string_view>

namespace {
using namespace hs274_observation_control;
using hs274_key_policy::keyboard_type;
unsigned assertions = 0;
void require(bool valid, const char* reason) {
  ++assertions;
  if (!valid) throw std::runtime_error(reason);
}
void identifiers() {
  require(parse_registry_id("1") == 1, "One is canonical and positive");
  require(parse_registry_id("40") == 40, "Decimal registry ID is accepted");
  require(parse_registry_id("18446744073709551615") == std::numeric_limits<std::uint64_t>::max(),
          "UINT64 maximum is parsed without rounding");
  for (const auto value : {"", "0", "00", "01", "00040", "-1", "+1", " 1", "1 ", "1\n", "1\r", "1\t",
                          "1.0", "1e3", "0x40", "40x", "nan", "18446744073709551616",
                          "99999999999999999999", "184467440737095516150"}) {
    require(!parse_registry_id(value), "Malformed, noncanonical and overflowing ID refuses");
  }
  require(!parse_registry_id(std::string_view("1\0secret", 8)), "Embedded NUL cannot truncate parsed identity");
}
void guard() {
  // These callbacks model a PURE control boundary, never Darwin framework calls.
  // Actual native availability and object retirement require the separate Mac tests.
  for (unsigned scenario = 0; scenario != 7; ++scenario) {
    unsigned acquired = 0, queried = 0, read = 0;
    const bool has_device = scenario != 0;
    const std::uint64_t expected = scenario == 3 ? 0 : scenario == 4 ? 99 : 42;
    const auto result = observe_exact_identity(has_device, expected,
        [&] { ++acquired; return scenario == 1 ? 0U : 7U; },
        [&](unsigned service, std::uint64_t& identity) {
          ++queried; require(service == 7, "Query uses only the acquired service");
          identity = 42; return scenario != 2;
        },
        [&](unsigned service) {
          ++read; require(service == 7, "Property read uses only the acquired service");
          return scenario == 5 ? observation{status::property_missing}
                               : observation{status::supported, keyboard_type::iso};
        });
    const status expected_status[] = {status::no_device, status::no_service, status::identity_unavailable,
        status::identity_mismatch, status::identity_mismatch, status::property_missing, status::supported};
    require(result.state == expected_status[scenario], "Each refusal keeps its closed native-observation state");
    require(acquired == (scenario == 0 ? 0U : 1U), "No-device boundary acquires no service");
    require(queried == (scenario < 2 ? 0U : 1U), "Unavailable service never reaches identity query");
    require(read == (scenario < 5 ? 0U : 1U), "Refused identity never reads the property");
    require(result.property_read_attempted == (scenario >= 5), "Read-attempt witness follows the actual callback");
    require(result.type == (scenario == 6 ? keyboard_type::iso : keyboard_type::unavailable),
            "Refusal never fabricates keyboard type");
  }
}
void release_results() {
  const observation supported{status::supported, keyboard_type::ansi, true};
  require(probe_exit(supported, reference_release::released) == 0, "Supported observation requires acquired reference release");
  require(probe_exit(supported, reference_release::refused) == 3, "Native release refusal cannot become diagnostic success");
  require(probe_exit(supported, reference_release::not_acquired) == 3, "Unacquired service cannot close a supported observation");
  require(probe_exit(supported, static_cast<reference_release>(127)) == 3, "Malformed release state refuses");
  require(probe_exit({status::supported, keyboard_type::unavailable, true}, reference_release::released) == 3,
          "Supported label cannot fabricate an unavailable type");
  require(probe_exit({status::supported, keyboard_type::none, true}, reference_release::released) == 3,
          "Type observation cannot fabricate none");
  require(probe_exit({status::supported, keyboard_type::ansi, false}, reference_release::released) == 3,
          "Supported label without actual property-read attempt refuses");
  for (const auto state : {status::no_device, status::no_service, status::identity_unavailable,
                          status::identity_mismatch, status::property_missing, status::property_wrong_type,
                          status::property_noninteger, status::property_conversion_refused,
                          status::property_unsupported, status::matching_unavailable,
                          status::acquisition_unavailable, status::service_class_refused,
                          status::device_creation_refused}) {
    require(probe_exit({state}, reference_release::released) == 3, "Cleanup success never rewrites a refused observation");
  }
}
} // namespace

int main() {
  try {
    identifiers(); guard(); release_results();
    std::cout << "PASS pure observation controls assertions=" << assertions << "; native framework calls unexecuted\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL " << error.what() << '\n';
    return 1;
  }
}
