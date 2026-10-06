// tools/diagnostics/hs274-native-capacity-test.cpp
// Portable registration fixtures prove diagnostic exhaustion preserves ordinary callbacks.
#include "hs274-stream-source.hpp"
#include <cassert>
#include <cstdio>
#include <vector>
using namespace hs274_stream_protocol;
using receiver_type = source<4096, 64, 64>;
#ifdef HS274_TEST_ORIGINAL
using handle_type = receiver_type::monitor;
handle_type acquire(receiver_type& receiver, unsigned identity) {
  return receiver.refuse(identity, native_refusal::keyboard_type_unavailable);
}
#else
using handle_type = receiver_type::native_registration;
handle_type acquire(receiver_type& receiver, unsigned identity) {
  return receiver.native_attach(identity, false, hs274_key_policy::keyboard_type::none,
                                native_refusal::keyboard_type_unavailable);
}
#endif
int main() {
  receiver_type receiver("capacity", [] { return 100ULL; });
  std::vector<handle_type> owned;
  unsigned ordinary_constructed = 0;
  try {
    for (unsigned i = 1; i <= 65; ++i) {
      owned.push_back(acquire(receiver, i));
      ++ordinary_constructed;
    }
  } catch (const std::overflow_error&) {
    std::printf("FAIL ordinary monitor constructions=%u expected=65\n", ordinary_constructed);
    return 1;
  }
  assert(ordinary_constructed == 65);
  const auto status = receiver.request(1, {{"version", 1u}, {"action", "status"}});
  assert(status.at("ready") == false);
  assert(status.at("exhausted") == true);
  assert(status.at("monitors").size() == 64);
#ifndef HS274_TEST_ORIGINAL
  assert(!owned.back().active());
  assert(owned.back().reason() == native_fault::registration_capacity_exhausted);
  assert(receiver.native_fault_reason() == native_fault::registration_capacity_exhausted);
  assert(status.at("native_fault") == "registration_capacity_exhausted");
  assert(!owned.back().started(nullptr, 0, true, false));
  owned.back().retire();
  owned.front().retire();
  auto retry = acquire(receiver, 66);
  assert(!retry.active());
  assert(receiver.request(1, {{"version", 1u}, {"action", "status"}}).at("ready") == false);
  bool denied = false;
  try { receiver.freeze(100); } catch (const std::logic_error&) { denied = true; }
  assert(denied);
#endif
  std::puts("PASS ordinary monitor constructions=65; capture remains exhausted and denied");
}
