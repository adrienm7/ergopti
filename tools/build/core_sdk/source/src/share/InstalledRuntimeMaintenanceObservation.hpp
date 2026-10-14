// Descriptive kernel/Security observations only; no owner or authority factory.
#pragma once
#include <bsm/audit.h>
#include <sys/types.h>
#include <cstdint>
#include <string>
#include <vector>

namespace ergoptiplus::installed_maintenance::detail {
// Descriptive native sample, constructed by the distinct retained maintenance
// socket sampler. Unlike ordinary auth policy, this does not classify installer
// as a CLI role or require both independently authenticated leaves to be equal.
struct native_code_observation {
  std::string identifier;
  std::vector<uint8_t> leaf;
};
struct native_peer_observation {
  audit_token_t token{};
  pid_t pid = 0;
  uid_t euid = 0;
  gid_t egid = 0;
  native_code_observation self, peer;
  uid_t self_euid = 0;
  gid_t self_egid = 0;
};
using observation = native_peer_observation;
} // namespace ergoptiplus::installed_maintenance::detail
