// tools/diagnostics/hs274-native-refusal-test.cpp
// Refused native provenance remains an owned pending monitor, never an empty baseline.
#include "hs274-stream-source.hpp"
#include "hs274-stream-readiness.hpp"
#include <cassert>
int main() {
  using namespace hs274_stream_protocol;
  source<64, 8, 4> receiver("refusal-fixture", [] { return 100ULL; });
  auto ordinary = receiver.attach(1, false, hs274_key_policy::keyboard_type::none);
  assert(ordinary.started(nullptr, 0, true, false));
  auto refused = receiver.refuse(2, native_refusal::keyboard_type_unavailable);
  assert(!refused.started(nullptr, 0, true, false));
  refused.stopped();
  assert(!refused.started(nullptr, 0, true, false));
  const auto status = receiver.request(3, {{"version", 1u}, {"action", "status"}});
  assert(status.at("ready") == false);
  assert(status.at("monitors").size() == 2);
  assert(status.at("monitors").at(1).at("refusal") == "keyboard_type_unavailable");
  bool explained = false;
  try { readiness{}.observe(status); }
  catch (const std::runtime_error& error) { explained = std::string(error.what()) ==
      "Capture native provenance refused: keyboard_type_unavailable"; }
  assert(explained);
  auto forged = status;
  forged["monitors"][1]["refusal"] = "guessed_ansi";
  bool malformed = false;
  try { readiness{}.observe(forged); } catch (const std::invalid_argument&) { malformed = true; }
  assert(malformed);
  forged = status;
  forged["monitors"][1]["started"] = true;
  malformed = false;
  try { readiness{}.observe(forged); } catch (const std::invalid_argument&) { malformed = true; }
  assert(malformed);
  bool rejected = false;
  try { receiver.freeze(100); } catch (const std::logic_error&) { rejected = true; }
  assert(rejected);
  const auto prepared = receiver.request(3, {{"version", 1u}, {"action", "prepare"}});
  rejected = false;
  try { receiver.request(3, {{"version", 1u}, {"action", "open"},
      {"incarnation", prepared.at("incarnation")}, {"preparation", prepared.at("preparation")}}); }
  catch (const std::runtime_error&) { rejected = true; }
  assert(rejected);
  refused.retire();
  assert(receiver.request(3, {{"version", 1u}, {"action", "status"}}).at("ready") == true);
  auto retry = receiver.attach(2, false, hs274_key_policy::keyboard_type::none);
  assert(retry.started(nullptr, 0, true, false));
  retry.refuse(native_refusal::changed_native_provenance);
  assert(!retry.started(nullptr, 0, true, false));
  assert(receiver.request(3, {{"version", 1u}, {"action", "status"}}).at("ready") == false);
}
