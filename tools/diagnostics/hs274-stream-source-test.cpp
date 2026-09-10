// tools/diagnostics/hs274-stream-source-test.cpp
// Exercise actual acquisition ownership, protocol readiness and stale callbacks.
#include "hs274-stream-source.hpp"
#include <cstdio>
#include <optional>
#include <stdexcept>

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

json open_request() { return {{"version", 1u}, {"action", "open"}}; }
json pull_request(const json& opened) {
  return {{"version", 1u}, {"action", "pull"},
          {"incarnation", opened.at("incarnation")}, {"lease", opened.at("lease")}};
}

int main() {
  source owner("first");
  rejects([&] { owner.request(7, open_request()); });
  rejects([&] { owner.attach(0); });
  auto first = owner.attach(41);
  rejects([&] { owner.attach(41); });
  rejects([&] { owner.request(7, open_request()); });
  first.started();
  rejects([&] { first.started(); });
  auto second = owner.attach(44);
  rejects([&] { owner.request(7, open_request()); });
  second.started();
  auto opened = owner.request(7, open_request());
  auto pull = pull_request(opened);
  first.append({41, 1, 1, true, true, 7, 41});
  second.append({44, 2, 1, true, true, 7, 44});
  auto pending = owner.request(7, pull);
  require(pending.at("records").size() == 2);
  second.stopped();
  pull["ack"] = "2";
  require(owner.request(7, pull).at("reason") == "interrupted");
  owner.peer_closed(7);
  rejects([&] { owner.request(7, open_request()); });
  second.started();
  auto successor = owner.request(7, open_request());
  rejects([&] { owner.request(7, pull); });
  pull = pull_request(successor);
  require(owner.request(7, pull).at("records").empty());
  first.append({44, 3, 1, true, true, 7, 44});
  require(owner.request(7, pull).at("reason") == "interrupted");
  owner.peer_closed(7);
  rejects([&] { owner.request(7, open_request()); });
  first.started();
  successor = owner.request(7, open_request());
  pull = pull_request(successor);
  second.retire();
  second.started();
  second.append({44, 4, 1, true, true, 7, 44});
  require(owner.request(7, pull).at("reason") == "interrupted");
  owner.peer_closed(7);
  {
    auto replacement = owner.attach(44);
    rejects([&] { owner.request(7, open_request()); });
    replacement.started();
    opened = owner.request(7, open_request());
    pull = pull_request(opened);
    second.stopped();
    require(owner.request(7, pull).at("records").empty());
  }
  require(owner.request(7, pull).at("reason") == "interrupted");
  owner.peer_closed(7);
  auto extra = owner.attach(45);
  extra.started();
  opened = owner.request(7, open_request());
  pull = pull_request(opened);
  rejects([&] { owner.attach(46); });
  require(owner.request(7, pull).at("reason") == "interrupted");
  owner.peer_closed(7);
  extra.retire();
  rejects([&] { owner.request(7, open_request()); });

  std::optional<source::monitor> old;
  {
    source previous("previous");
    old.emplace(previous.attach(41));
    old->started();
    previous.request(7, open_request());
  }
  source next("next");
  auto current = next.attach(41);
  current.started();
  opened = next.request(7, open_request());
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
