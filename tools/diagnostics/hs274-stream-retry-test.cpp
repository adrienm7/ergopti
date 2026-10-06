// tools/diagnostics/hs274-stream-retry-test.cpp
// Independent retry controls: readiness must have a usable, current baseline.
#include "hs274-stream-source.hpp"
#include <iostream>
#include <string>

using hs274_stream_protocol::json;
using source = hs274_stream_protocol::source<8, 2, 2>;
using type = hs274_key_policy::keyboard_type;
std::size_t assertions = 0;
void require(bool condition) {
  ++assertions;
  if (!condition) throw std::runtime_error("Independent retry assertion failed");
}
template <typename Callback> void rejects(Callback callback) {
  bool refused = false;
  try { callback(); } catch (const std::exception&) { refused = true; }
  require(refused);
}
json status(source& owner) {
  return owner.request(7, {{"version", 1u}, {"action", "status"}});
}
source::sample consumer_sample(std::int64_t value) {
  return {12, 205, 17, {true, false, false, 1, 1, 0, 1},
          0, true, 17, value, 90, 100, 100};
}
void expect_pending(source& owner) {
  const auto observed = status(owner);
  require(observed.at("ready") == false);
  require(observed.at("monitors").at(0).at("started") == false);
  rejects([&] { owner.freeze(100); });
}
void expect_empty(source& owner, source::monitor& monitor) {
  const auto observed = status(owner);
  require(observed.at("ready") == true);
  require(observed.at("monitors").at(0).at("started") == true);
  const auto frozen = owner.freeze(100);
  require(frozen.size() == 1);
  require(frozen.read(0).at("rows") == json::array({{
      {"kind", "device"}, {"device", "42"}, {"keyboard", false},
      {"keyboard_type", "none"}, {"elements", 0}}}));
  rejects([&] { monitor.key_down(17); });
  // Empty means no stale cookie is silently retained or can update state.
  monitor.append({42, 110, 1, true, true, 12, 205, 0, true, 17});
  expect_pending(owner);
}
void rejected_inventory() {
  source owner("rejected-consumer", [] { return 100; });
  auto monitor = owner.attach(42, false, type::none);
  const auto invalid = consumer_sample(2);
  require(!monitor.started(&invalid, 1, true, false));
  expect_pending(owner);
  require(monitor.started(nullptr, 0, true, false));
  expect_empty(owner, monitor);
}
void invalidated_inventory() {
  source owner("invalidated-consumer", [] { return 100; });
  auto monitor = owner.attach(42, false, type::none);
  const auto valid = consumer_sample(1);
  require(monitor.started(&valid, 1, true, false));
  require(status(owner).at("ready") == true);
  require(monitor.key_down(17));
  const auto initial = owner.freeze(100).read(0).at("rows").at(1);
  require(initial.at("cookie") == 17 && initial.at("page") == 12 && initial.at("down") == true);
  monitor.append({42, 110, 1, true, true, 12, 205, 0, true, 999});
  expect_pending(owner);
  require(monitor.started(nullptr, 0, true, false));
  expect_empty(owner, monitor);
}
void healthy_empty() {
  source owner("healthy-empty-consumer", [] { return 100; });
  auto monitor = owner.attach(42, false, type::none);
  expect_pending(owner);
  require(monitor.started(nullptr, 0, true, false));
  expect_empty(owner, monitor);
}
int main(int argc, char** argv) {
  try {
    if (argc != 2) throw std::invalid_argument("Select one independent retry case");
    const std::string selected(argv[1]);
    if (selected == "rejected") rejected_inventory();
    else if (selected == "invalidated") invalidated_inventory();
    else if (selected == "healthy") healthy_empty();
    else throw std::invalid_argument("Unknown independent retry case");
    std::cout << selected << ": " << assertions << " independent retry assertions passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "Independent retry control failed after " << assertions << " assertions: " << error.what() << '\n';
    return 1;
  }
}
