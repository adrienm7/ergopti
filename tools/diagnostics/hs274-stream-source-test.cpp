// tools/diagnostics/hs274-stream-source-test.cpp
// Exercise actual acquisition ownership, protocol readiness and stale callbacks.
#include "hs274-stream-source.hpp"
#include "hs274-stream-input.hpp"
#include "hs274-stream-readiness.hpp"
#include "hs274-stream-baseline-client.hpp"
#include <cstdio>
#include <optional>
#include <stdexcept>
#include <vector>

using hs274_stream_protocol::json;
using source = hs274_stream_protocol::source<4, 2, 2>;
std::uint64_t acquisition_time() { return 1000; }

bool start(source::monitor& monitor) {
  const source::sample samples[] = {
      {41, 41, {true, false, true, 1, 32, 0, 1}, 0, true, 41, 0, 0, 0, 0},
      {44, 44, {true, false, true, 1, 32, 0, 1}, 0, true, 44, 0, 0, 0, 0}};
  return monitor.started(samples, 2, true, false);
}

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

json open_ready(source& owner, const json& opening) {
  auto opened = owner.request(7, opening);
  auto request = pull_request(opened);
  request["action"] = "baseline";
  std::size_t cursor = 0;
  for (;;) {
    const auto response = owner.request(7, request);
    if (response.at("kind") == "baseline_ready") break;
    require(response.at("kind") == "baseline" && response.at("offset") == cursor);
    const auto next = response.at("next").get<std::size_t>();
    require(next > cursor && response.at("rows").size() == next - cursor);
    cursor = next;
    request["baseline_ack"] = std::to_string(cursor);
  }
  require(cursor == opened.at("baseline").at("rows"));
  return opened;
}

void baseline_session_cases() {
  source owner("baseline-session", acquisition_time);
  auto keyboard = owner.attach(41, true);
  require(start(keyboard));
  const auto opened = owner.request(7, prepare(owner));
  require(opened.at("baseline").at("boundary") == "1000");
  auto request = pull_request(opened);
  rejects([&] { owner.request(7, request); });
  request["action"] = "baseline";
  rejects([&] { owner.request(8, request); });
  request["baseline_ack"] = "0";
  rejects([&] { owner.request(7, request); });
  request.erase("baseline_ack");
  const auto first = owner.request(7, request);
  require(first.at("next") == 2 && first.at("complete") == false);
  rejects([&] { owner.request(7, request); });
  keyboard.append({41, 1001, 1, true, true, 7, 44, 0, true, 44});
  keyboard.append({41, 1002, 0, true, true, 7, 44, 0, true, 44});
  request["baseline_ack"] = "1";
  rejects([&] { owner.request(7, request); });
  request["baseline_ack"] = "2";
  const auto last = owner.request(7, request);
  require(last.at("complete") == true && last.at("next") == 3);
  require(last.at("rows").at(0).at("down") == false);
  rejects([&] { owner.request(7, request); });
  rejects([&] { owner.request(7, pull_request(opened)); });
  request["baseline_ack"] = "3";
  require(owner.request(7, request).at("kind") == "baseline_ready");
  rejects([&] { owner.request(7, request); });
  const auto raw = owner.request(7, pull_request(opened));
  require(raw.at("records").size() == 2);
  require(raw.at("records").at(0).at("sequence") == "1");
  require(raw.at("records").at(1).at("value") == "0");

  for (unsigned mode = 0; mode < 3; ++mode) {
    source failed("baseline-failure", acquisition_time);
    auto monitor = failed.attach(41, true);
    require(start(monitor));
    const auto lease = failed.request(7, prepare(failed));
    auto page = pull_request(lease);
    page["action"] = "baseline";
    require(failed.request(7, page).at("next") == 2);
    page["baseline_ack"] = "2";
    if (mode == 0) monitor.stopped();
    if (mode == 1) {
      for (unsigned i = 0; i < 5; ++i) monitor.append({41, 1001 + i, i % 2,
          true, true, 7, 44, 0, true, 44});
    }
    if (mode == 2) {
      failed.peer_closed(7);
      rejects([&] { failed.request(7, page); });
      const auto successor = open_ready(failed, prepare(failed));
      require(successor.at("lease") != lease.at("lease"));
      rejects([&] { failed.request(7, page); });
    } else {
      require(failed.request(7, page).at("reason") == (mode == 0 ? "interrupted" : "overflow"));
      require(failed.request(7, pull_request(lease)).at("kind") == "lost");
    }
  }
}

void baseline_client_cases() {
  for (unsigned mode = 0; mode < 5; ++mode) {
    source owner("baseline-client", acquisition_time);
    auto keyboard = owner.attach(41, true);
    require(start(keyboard));
    const auto opened = owner.request(7, prepare(owner));
    std::vector<json> published, receipts;
    std::size_t requests = 0;
    const auto transfer = [&] {
      hs274_stream_protocol::transfer_baseline<2>(opened, [&](const json& request) {
        ++requests;
        if (requests > 1) require(receipts.size() == requests - 1);
        json response = owner.request(7, request);
        if (requests == 1) {
          if (mode == 1) response["lease"] = "999";
          if (mode == 2) response["next"] = 1u;
        }
        return response;
      }, [&](const json& response) { published.push_back(response); }, [&](const json& receipt) {
        require(receipt.contains("baseline_ack") && !receipt.contains("ack"));
        require(published.size() == receipts.size() + 1);
        if (mode == 3) throw std::runtime_error("Downstream refused baseline");
        receipts.push_back(receipt);
        if (mode == 4) keyboard.stopped();
      });
    };
    if (mode == 0) {
      transfer();
      require(requests == 3 && receipts.size() == 2 && published.size() == 3);
      require(published.back().at("kind") == "baseline_ready");
      require(owner.request(7, pull_request(opened)).at("records").empty());
    } else {
      rejects(transfer);
      if (mode <= 2) require(published.empty() && receipts.empty());
      if (mode == 3) require(requests == 1 && receipts.empty());
      if (mode == 4) require(requests == 2 && published.back().at("kind") == "lost");
    }
  }
}

void baseline_page_cases() {
  source owner("baseline-pages", acquisition_time);
  rejects([&] { owner.freeze(100); });
  auto keyboard = owner.attach(41, true);
  require(start(keyboard));
  auto consumer = owner.attach(42, false);
  rejects([&] { owner.freeze(100); });
  require(consumer.started(nullptr, 0, true, false));
  const auto frozen = owner.freeze(100);
  const auto first = frozen.read(0);
  require(first.at("rows").size() == 2 && first.at("next") == 2 && first.at("total") == 4);
  require(first.at("rows").at(0).at("kind") == "device");
  require(first.at("rows").at(0).at("elements") == 2);
  keyboard.append({41, 101, 1, true, true, 7, 44, 0, true, 44});
  const auto second = frozen.read(2);
  require(second.at("complete") == true && second.at("next") == 4);
  require(second.at("rows").at(0).at("cookie") == 44);
  require(second.at("rows").at(0).at("down") == false);
  require(second.at("rows").at(1).at("kind") == "device");
  require(second.at("rows").at(1).at("keyboard") == false);
  require(second.at("rows").at(1).at("elements") == 0);
  require(frozen.read(0) == first);
  require(owner.freeze(101).read(2).at("rows").at(0).at("down") == true);
  rejects([&] { frozen.read(4); });
  keyboard.stopped();
  rejects([&] { owner.freeze(102); });
  // The owning protocol must fence this retained copy after topology loss.
  require(frozen.read(2) == second);

  using pages = hs274_stream_protocol::baseline_pages<64, 2, 1024>;
  std::vector<pages::element> keys;
  for (std::uint32_t cookie = 0; cookie < 1024; ++cookie) {
    keys.push_back({255, UINT32_MAX - cookie, UINT64_MAX, true});
  }
  const pages maximum(UINT64_MAX, {{UINT64_MAX, true, keys}, {UINT64_MAX - 1, true, keys}});
  std::size_t offset = 0, count = 0;
  for (;;) {
    const auto page = maximum.read(offset);
    require(page.at("rows").size() <= 64 && !page.at("rows").empty());
    require(page.dump().size() < 16 * 1024);
    count += page.at("rows").size();
    const auto next = page.at("next").get<std::size_t>();
    require(next > offset && page.at("offset") == offset);
    offset = next;
    if (page.at("complete") == true) break;
  }
  require(count == 2050 && offset == count);
  rejects([&] { pages invalid(100, {}); });
  rejects([&] { pages invalid(UINT64_MAX, {{1, true, keys}, {1, true, keys}}); });
  rejects([&] { pages invalid(UINT64_MAX, {{1, false, keys}}); });
  rejects([&] { pages invalid(UINT64_MAX, {{1, true, {}}}); });
  rejects([&] { pages invalid(100, {{1, true, keys}}); });
  keys[1].cookie = keys[0].cookie;
  rejects([&] { pages invalid(UINT64_MAX, {{1, true, keys}}); });
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
  source owner("readiness", acquisition_time);
  auto opening = prepare(owner);
  const json status{{"version", 1u}, {"action", "status"}};
  auto empty = owner.request(7, status);
  require(!empty.at("ready").get<bool>() && empty.at("monitors").empty());
  rejects([&] { owner.request(0, status); });
  rejects([&] { owner.request(7, {{"version", true}, {"action", "status"}}); });
  rejects([&] { owner.request(7, {{"version", 1u}, {"action", "status"}, {"extra", true}}); });
  auto monitor = owner.attach(41, true);
  auto pending = owner.request(7, status);
  require(!pending.at("ready").get<bool>());
  start(monitor);
  auto ready = owner.request(7, status);
  require(ready.at("ready").get<bool>());
  auto opened = open_ready(owner, opening);
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

void observation_policy_cases() {
  source owner("policy", acquisition_time);
  auto monitor = owner.attach(41, true);
  require(!owner.observes(41, false, false));
  auto opening = prepare(owner);
  // Pending monitors must be eligible before readiness can ever become true.
  require(owner.observes(41, false, false));
  for (bool seize : {false, true}) {
    for (bool temporary : {false, true}) {
      require(owner.observes(41, seize, temporary) == (!seize && !temporary));
      require(!owner.observes(0, seize, temporary));
      require(!owner.observes(42, seize, temporary));
    }
  }
  owner.peer_closed(8);
  require(owner.observes(41, false, false));
  start(monitor);
  auto opened = open_ready(owner, opening);
  require(owner.observes(41, false, false));
  auto close = pull_request(opened);
  close["action"] = "close";
  owner.request(7, close);
  require(!owner.observes(41, false, false));
  opening = prepare(owner);
  require(owner.observes(41, false, false));
  monitor.stopped();
  require(owner.observes(41, false, false));
  monitor.retire();
  require(!owner.observes(41, false, false));
  auto replacement = owner.attach(41, true);
  require(owner.observes(41, false, false));
  auto cancel = opening;
  cancel["action"] = "cancel";
  owner.request(7, cancel);
  require(!owner.observes(41, false, false));
  prepare(owner);
  owner.peer_closed(7);
  require(!owner.observes(41, false, false));
  prepare(owner);
  auto second = owner.attach(42, true);
  rejects([&] { owner.attach(43, true); });
  require(!owner.observes(41, false, false));
  require(!owner.observes(42, false, false));
}

void preparation_cases() {
  source owner("preparation", acquisition_time);
  const json status{{"version", 1u}, {"action", "status"}};
  owner.request(7, status);
  require(!owner.observing());
  auto monitor = owner.attach(41, true);
  start(monitor);
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
  monitor.append({41, 1, 1, true, true, 7, 41, 0, true, 41});
  auto opened = open_ready(owner, opening);
  require(owner.request(7, pull_request(opened)).at("records").empty());
  monitor.append({41, 2, 1, true, true, 7, 41, 0, true, 41});
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
  opened = open_ready(owner, opening);
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

void reference_routing_cases() {
  source owner("reference-routing", acquisition_time);
  auto first = owner.attach(41, true);
  auto second = owner.attach(42, true);
  start(first);
  start(second);
  auto opened = open_ready(owner, prepare(owner));
  hs274_raw_capture::capture<1> reference;
  hs274_stream_protocol::append_input(second, reference, false, {42, 1, 1, true, true, 7, 44, 0, true, 44});
  hs274_stream_protocol::append_input(first, reference, true, {41, 2, 1, true, true, 7, 41, 0, true, 41});
  auto records = owner.request(7, pull_request(opened)).at("records");
  require(records.size() == 2 && records[0].at("device") == "42" && records[1].at("device") == "41");
  require(records[0].at("sequence") == "1" && records[1].at("sequence") == "2");
  auto captured = reference.read();
  require(captured.seen == 1 && captured.count == 1 && captured.overflow == 0);
  require(captured.records[0].device == 41 && captured.records[0].timestamp == 2 && captured.records[0].sequence == 1);
}

void sampled_state_cases() {
  source owner("sampled-state", acquisition_time);
  auto first = owner.attach(41, true);
  auto second = owner.attach(42, true);
  const source::sample held{44, 44, {true, false, true, 1, 32, 0, 1}, 0, true, 44, 1, 0, 0, 0};
  require(first.started(&held, 1, true, false));
  require(first.key_down(44));
  first.append({41, 1, 0, true, true, 7, 44, 0, true, 44});
  require(!first.key_down(44));
  first.append({41, 2, 1, true, true, 7, 44, 0, true, 44});
  require(first.key_down(44));
  require(start(second));
  auto opened = open_ready(owner, prepare(owner));
  require(owner.request(7, pull_request(opened)).at("records").empty());
  // State classification must not remove unchanged raw observations.
  first.append({41, 3, 1, true, true, 7, 44, 0, true, 44});
  first.append({41, 4, 0, true, true, 7, 44, 0, true, 44});
  require(owner.request(7, pull_request(opened)).at("records").size() == 2);
  owner.peer_closed(7);
  first.append({41, 5, 1, true, true, 7, 44, 0, true, 44});
  require(first.key_down(44));
  opened = open_ready(owner, prepare(owner));
  require(owner.request(7, pull_request(opened)).at("records").empty());
  first.append({41, 6, 0, true, true, 7, 44});
  require(owner.request(7, pull_request(opened)).at("reason") == "interrupted");
  rejects([&] { first.key_down(44); });
  require(start(first));
  require(!first.key_down(44));
  require(owner.request(7, pull_request(opened)).at("reason") == "interrupted");

  source mixed("consumer-state", acquisition_time);
  auto keyboard = mixed.attach(41, true);
  auto consumer = mixed.attach(42, false);
  require(!keyboard.started(nullptr, 0, true, false));
  require(start(keyboard));
  require(!consumer.started(nullptr, 0, false, false));
  require(!consumer.started(nullptr, 0, true, true));
  require(!consumer.started(&held, 1, true, false));
  require(consumer.started(nullptr, 0, true, false));
  rejects([&] { consumer.key_down(44); });
  opened = open_ready(mixed, prepare(mixed));
  consumer.append({42, 1, 1, true, true, 12, 205, 0, true, 1});
  const auto records = mixed.request(7, pull_request(opened)).at("records");
  require(records.size() == 1 && records.at(0).at("page") == 12);
  consumer.append({42, 2, 1, true, true, 7, 44, 0, true, 44});
  require(mixed.request(7, pull_request(opened)).at("reason") == "interrupted");
}

int main() {
  baseline_client_cases();
  baseline_session_cases();
  baseline_page_cases();
  sampled_state_cases();
  reference_routing_cases();
  observation_policy_cases();
  preparation_cases();
  readiness_cases();
  source owner("first", acquisition_time);
  auto opening = prepare(owner);
  rejects([&] { owner.request(7, opening); });
  rejects([&] { owner.attach(0, true); });
  auto first = owner.attach(41, true);
  rejects([&] { owner.attach(41, true); });
  rejects([&] { owner.request(7, opening); });
  start(first);
  rejects([&] { start(first); });
  auto second = owner.attach(44, true);
  rejects([&] { owner.request(7, opening); });
  start(second);
  auto opened = open_ready(owner, opening);
  auto pull = pull_request(opened);
  first.append({41, 1, 1, true, true, 7, 41, 0, true, 41});
  second.append({44, 2, 1, true, true, 7, 44, 0, true, 44});
  auto pending = owner.request(7, pull);
  require(pending.at("records").size() == 2);
  second.stopped();
  pull["ack"] = "2";
  require(owner.request(7, pull).at("reason") == "interrupted");
  owner.peer_closed(7);
  opening = prepare(owner);
  rejects([&] { owner.request(7, opening); });
  start(second);
  auto successor = open_ready(owner, opening);
  rejects([&] { owner.request(7, pull); });
  pull = pull_request(successor);
  require(owner.request(7, pull).at("records").empty());
  first.append({44, 3, 1, true, true, 7, 44, 0, true, 44});
  require(owner.request(7, pull).at("reason") == "interrupted");
  owner.peer_closed(7);
  opening = prepare(owner);
  rejects([&] { owner.request(7, opening); });
  start(first);
  successor = open_ready(owner, opening);
  pull = pull_request(successor);
  second.retire();
  start(second);
  second.append({44, 4, 1, true, true, 7, 44, 0, true, 44});
  require(owner.request(7, pull).at("reason") == "interrupted");
  owner.peer_closed(7);
  opening = prepare(owner);
  {
    auto replacement = owner.attach(44, true);
    rejects([&] { owner.request(7, opening); });
    start(replacement);
    opened = open_ready(owner, opening);
    pull = pull_request(opened);
    second.stopped();
    require(owner.request(7, pull).at("records").empty());
  }
  require(owner.request(7, pull).at("reason") == "interrupted");
  owner.peer_closed(7);
  opening = prepare(owner);
  auto extra = owner.attach(45, true);
  start(extra);
  opened = open_ready(owner, opening);
  pull = pull_request(opened);
  rejects([&] { owner.attach(46, true); });
  require(owner.request(7, pull).at("reason") == "interrupted");
  owner.peer_closed(7);
  opening = prepare(owner);
  extra.retire();
  rejects([&] { owner.request(7, opening); });

  std::optional<source::monitor> old;
  {
    source previous("previous", acquisition_time);
    old.emplace(previous.attach(41, true));
    start(*old);
    open_ready(previous, prepare(previous));
  }
  source next("next", acquisition_time);
  auto current = next.attach(41, true);
  start(current);
  opened = open_ready(next, prepare(next));
  pull = pull_request(opened);
  old->stopped();
  start(*old);
  old->append({41, 5, 1, true, true, 7, 41, 0, true, 41});
  old.reset();
  require(next.request(7, pull).at("records").empty());
  current.append({41, 6, 1, true, true, 7, 41, 0, true, 41});
  require(next.request(7, pull).at("records").size() == 1);
  std::puts("Source readiness, multi-device interruption, bounded inventory and stale callbacks passed");
}
