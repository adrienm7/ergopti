// tools/diagnostics/hs274-stream-source-test.cpp
// Exercise actual acquisition ownership, protocol readiness and stale callbacks.
#include "hs274-stream-source.hpp"
#include "hs274-stream-readiness.hpp"
#include <cstdio>
#include <optional>
#include <stdexcept>
#include <vector>

using hs274_stream_protocol::json;
using source = hs274_stream_protocol::source<4, 2, 2>;

void require(bool condition) {
  if (!condition) throw std::runtime_error("Source assertion failed");
}

template <typename Callback>
void rejects(Callback callback) {
  bool failed = false;
  try { callback(); } catch (const std::exception&) { failed = true; }
  require(failed);
}

json prepare(source& owner) {
  auto prepared = owner.request(7, {{"version", 1u}, {"action", "prepare"}});
  return {{"version", 1u}, {"action", "open"}, {"incarnation", prepared.at("incarnation")},
          {"preparation", prepared.at("preparation")}};
}
json pull_request(const json& opened) {
  return {{"version", 1u}, {"action", "pull"},
          {"incarnation", opened.at("incarnation")}, {"lease", opened.at("lease")}};
}

struct clock_fixture {
  using time_point = std::chrono::steady_clock::time_point;
  inline static time_point current{};
  static time_point now() { return current; }
};

struct client_fixture {
  std::vector<json> responses;
  clock_fixture::time_point deadline;
  std::chrono::milliseconds response_time{2};
  std::size_t requests = 0, pauses = 0;
  std::string failure{};

  json request(const json& input, clock_fixture::time_point received_deadline) {
    require(input == json({{"version", 1u}, {"action", "status"}}));
    require(received_deadline == deadline);
    ++requests;
    if (!failure.empty()) throw std::runtime_error(failure);
    clock_fixture::current += response_time;
    return responses.at(std::min(requests - 1, responses.size() - 1));
  }

  void pause(std::chrono::milliseconds interval) {
    require(interval.count() >= 0 && clock_fixture::current + interval <= deadline);
    ++pauses;
    clock_fixture::current += interval;
  }
};

void readiness_cases() {
  using namespace std::chrono_literals;
  source owner("readiness");
  auto opening = prepare(owner);
  const json status{{"version", 1u}, {"action", "status"}};
  auto empty = owner.request(7, status);
  require(!empty.at("ready").get<bool>() && empty.at("monitors").empty());
  rejects([&] { owner.request(0, status); });
  rejects([&] { owner.request(7, {{"version", true}, {"action", "status"}}); });
  rejects([&] { owner.request(7, {{"version", 1u}, {"action", "status"}, {"extra", true}}); });
  auto monitor = owner.attach(41);
  auto pending = owner.request(7, status);
  require(!pending.at("ready").get<bool>());
  monitor.started();
  auto ready = owner.request(7, status);
  require(ready.at("ready").get<bool>());
  auto opened = owner.request(7, opening);
  require(opened.at("lease") == "1");
  owner.request(8, status);
  require(owner.request(7, pull_request(opened)).at("records").empty());
  monitor.stopped();
  require(!owner.request(7, status).at("ready").get<bool>());

  clock_fixture::current = {};
  client_fixture success{{empty, pending, ready}, clock_fixture::current + 30ms};
  require(hs274_stream_protocol::await_readiness<clock_fixture>(success, 5ms, success.deadline) == "readiness");
  require(success.requests == 3 && success.pauses == 2);
  clock_fixture::current = {};
  client_fixture timeout{{pending}, clock_fixture::current + 12ms};
  bool expired = false;
  try { hs274_stream_protocol::await_readiness<clock_fixture>(timeout, 5ms, timeout.deadline); }
  catch (const std::runtime_error& error) { expired = std::string(error.what()) == "Capture readiness timeout"; }
  require(expired && timeout.requests == 2 && clock_fixture::current == timeout.deadline);
  clock_fixture::current = {};
  client_fixture late{{ready}, clock_fixture::current + 12ms, 12ms};
  rejects([&] { hs274_stream_protocol::await_readiness<clock_fixture>(late, 5ms, late.deadline); });
  clock_fixture::current = {};
  client_fixture disconnected{{pending}, clock_fixture::current + 12ms};
  disconnected.failure = "transport closed";
  bool propagated = false;
  try { hs274_stream_protocol::await_readiness<clock_fixture>(disconnected, 5ms, disconnected.deadline); }
  catch (const std::runtime_error& error) { propagated = std::string(error.what()) == "transport closed"; }
  require(propagated && disconnected.requests == 1 && disconnected.pauses == 0);

  for (const auto& field : {"version", "kind", "coverage", "incarnation", "ready", "exhausted", "monitors"}) {
    auto malformed = ready;
    malformed.erase(field);
    rejects([&] { hs274_stream_protocol::readiness{}.observe(malformed); });
  }
  auto inconsistent = empty;
  inconsistent["ready"] = true;
  rejects([&] { hs274_stream_protocol::readiness{}.observe(inconsistent); });
  auto duplicate = ready;
  duplicate["monitors"].push_back(duplicate.at("monitors").at(0));
  rejects([&] { hs274_stream_protocol::readiness{}.observe(duplicate); });
  auto exhausted = ready;
  exhausted["exhausted"] = true;
  rejects([&] { hs274_stream_protocol::readiness{}.observe(exhausted); });
  hs274_stream_protocol::readiness identity;
  require(!identity.observe(pending));
  auto replaced = ready;
  replaced["incarnation"] = "other";
  rejects([&] { identity.observe(replaced); });
}

void preparation_cases() {
  source owner("preparation");
  const json status{{"version", 1u}, {"action", "status"}};
  owner.request(7, status);
  require(!owner.observing());
  auto monitor = owner.attach(41);
  monitor.started();
  rejects([&] { owner.request(7, {{"version", 1u}, {"action", "open"}}); });
  rejects([&] { owner.request(0, {{"version", 1u}, {"action", "prepare"}}); });
  rejects([&] { owner.request(7, {{"version", true}, {"action", "prepare"}}); });
  rejects([&] { owner.request(7, {{"version", 1u}, {"action", "prepare"}, {"extra", 0}}); });
  require(!owner.observing());
  auto opening = prepare(owner);
  require(owner.observing());
  rejects([&] { prepare(owner); });
  rejects([&] { owner.request(8, {{"version", 1u}, {"action", "prepare"}}); });
  rejects([&] { owner.request(8, opening); });
  owner.peer_closed(8);
  require(owner.observing());
  monitor.append({41, 1, 1, true, true, 7, 41});
  auto opened = owner.request(7, opening);
  require(owner.request(7, pull_request(opened)).at("records").empty());
  monitor.append({41, 2, 1, true, true, 7, 41});
  auto cancel = opening;
  cancel["action"] = "cancel";
  auto wrong = cancel;
  wrong["incarnation"] = "other";
  rejects([&] { owner.request(7, wrong); });
  require(owner.observing());
  require(owner.request(7, cancel).at("kind") == "cancelled");
  require(!owner.observing());
  rejects([&] { owner.request(7, pull_request(opened)); });
  opening = prepare(owner);
  require(opening.at("preparation") == "2");
  rejects([&] { owner.request(7, cancel); });
  require(owner.observing());
  opened = owner.request(7, opening);
  auto pull = pull_request(opened);
  require(owner.request(7, pull).at("records").empty());
  auto close = pull;
  close["action"] = "close";
  owner.request(7, close);
  require(!owner.observing());
  prepare(owner);
  owner.peer_closed(7);
  require(!owner.observing());
  prepare(owner);
  rejects([&] { owner.request(7, close); });
  require(owner.observing());
}

int main() {
  preparation_cases();
  readiness_cases();
  source owner("first");
  auto opening = prepare(owner);
  rejects([&] { owner.request(7, opening); });
  rejects([&] { owner.attach(0); });
  auto first = owner.attach(41);
  rejects([&] { owner.attach(41); });
  rejects([&] { owner.request(7, opening); });
  first.started();
  rejects([&] { first.started(); });
  auto second = owner.attach(44);
  rejects([&] { owner.request(7, opening); });
  second.started();
  auto opened = owner.request(7, opening);
  auto pull = pull_request(opened);
  first.append({41, 1, 1, true, true, 7, 41});
  second.append({44, 2, 1, true, true, 7, 44});
  auto pending = owner.request(7, pull);
  require(pending.at("records").size() == 2);
  second.stopped();
  pull["ack"] = "2";
  require(owner.request(7, pull).at("reason") == "interrupted");
  owner.peer_closed(7);
  opening = prepare(owner);
  rejects([&] { owner.request(7, opening); });
  second.started();
  auto successor = owner.request(7, opening);
  rejects([&] { owner.request(7, pull); });
  pull = pull_request(successor);
  require(owner.request(7, pull).at("records").empty());
  first.append({44, 3, 1, true, true, 7, 44});
  require(owner.request(7, pull).at("reason") == "interrupted");
  owner.peer_closed(7);
  opening = prepare(owner);
  rejects([&] { owner.request(7, opening); });
  first.started();
  successor = owner.request(7, opening);
  pull = pull_request(successor);
  second.retire();
  second.started();
  second.append({44, 4, 1, true, true, 7, 44});
  require(owner.request(7, pull).at("reason") == "interrupted");
  owner.peer_closed(7);
  opening = prepare(owner);
  {
    auto replacement = owner.attach(44);
    rejects([&] { owner.request(7, opening); });
    replacement.started();
    opened = owner.request(7, opening);
    pull = pull_request(opened);
    second.stopped();
    require(owner.request(7, pull).at("records").empty());
  }
  require(owner.request(7, pull).at("reason") == "interrupted");
  owner.peer_closed(7);
  opening = prepare(owner);
  auto extra = owner.attach(45);
  extra.started();
  opened = owner.request(7, opening);
  pull = pull_request(opened);
  rejects([&] { owner.attach(46); });
  require(owner.request(7, pull).at("reason") == "interrupted");
  owner.peer_closed(7);
  opening = prepare(owner);
  extra.retire();
  rejects([&] { owner.request(7, opening); });

  std::optional<source::monitor> old;
  {
    source previous("previous");
    old.emplace(previous.attach(41));
    old->started();
    previous.request(7, prepare(previous));
  }
  source next("next");
  auto current = next.attach(41);
  current.started();
  opened = next.request(7, prepare(next));
  pull = pull_request(opened);
  old->stopped();
  old->started();
  old->append({41, 5, 1, true, true, 7, 41});
  old.reset();
  require(next.request(7, pull).at("records").empty());
  current.append({41, 6, 1, true, true, 7, 41});
  require(next.request(7, pull).at("records").size() == 1);
  std::puts("Source readiness, multi-device interruption, bounded inventory and stale callbacks passed");
}
