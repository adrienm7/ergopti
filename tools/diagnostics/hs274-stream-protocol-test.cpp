// tools/diagnostics/hs274-stream-protocol-test.cpp
// Exercise real JSON/MessagePack boundaries and peer-owned capture lifecycle.
#include "hs274-stream-protocol.hpp"
#include <cstdio>
#include <fstream>
#include <stdexcept>

using hs274_stream_protocol::json;

void require(bool condition) {
  if (!condition) throw std::runtime_error("Protocol assertion failed");
}

template <typename Callback>
void rejects(Callback callback) {
  bool failed = false;
  try { callback(); } catch (const std::exception&) { failed = true; }
  require(failed);
}

int main(int argc, char** argv) {
  require(argc == 2);
  using controller = hs274_stream_protocol::controller<3, 2>;
  controller owner("first-process");
  auto open = json::from_msgpack(json::to_msgpack(json{{"version", 1u}, {"action", "open"}}));
  rejects([&] { owner.request(7, {{"version", true}, {"action", "open"}}); });
  auto opened = owner.request(7, open);
  require(opened.at("kind") == "opened" && opened.at("coverage") == "fixture_only");
  rejects([&] { owner.request(8, open); });
  json pull{{"version", 1u}, {"action", "pull"}, {"incarnation", "first-process"}, {"lease", opened.at("lease")}};
  require(owner.request(7, pull).at("records").empty());
  owner.append({UINT64_MAX, UINT64_MAX, INT64_MIN, true, true, 7, 41});
  auto batch = owner.request(7, pull);
  auto wire = json::parse(batch.dump());
  require(wire.at("records").at(0).at("device") == "18446744073709551615");
  require(wire.at("records").at(0).at("timestamp") == "18446744073709551615");
  require(wire.at("records").at(0).at("value") == "-9223372036854775808");
  rejects([&] { owner.request(7, pull); });
  rejects([&] { owner.request(8, pull); });
  owner.peer_closed(8);
  pull["ack"] = "1";
  require(owner.request(7, pull).at("records").empty());
  owner.peer_closed(7);
  rejects([&] { owner.request(7, pull); });
  auto successor = owner.request(7, open);
  require(successor.at("lease") != opened.at("lease"));
  rejects([&] { owner.request(7, pull); });
  pull.erase("ack");
  pull["lease"] = successor.at("lease");
  require(owner.request(7, pull).at("records").empty());
  for (int i = 0; i < 4; ++i) owner.append({1, 1, i, true, true, 7, 41});
  require(owner.request(7, pull).at("kind") == "lost");
  require(owner.request(7, pull).at("reason") == "overflow");
  auto close = pull;
  close["action"] = "close";
  require(owner.request(7, close).at("kind") == "closed");
  controller restarted("second-process");
  restarted.request(7, open);
  rejects([&] { restarted.request(7, pull); });
  for (const auto& text : {"", "01", "-1", "+1", " 1", "1x", "18446744073709551616"}) {
    rejects([&] { hs274_stream_protocol::decimal(text); });
  }
  rejects([] { hs274_stream_protocol::decimal(1u); });
  require(hs274_stream_protocol::decimal("18446744073709551615") == UINT64_MAX);
  std::ifstream fixture(argv[1]);
  require(fixture.is_open());
  json captured;
  fixture >> captured;
  require(captured.at("records").size() == 20);
  hs274_stream_protocol::controller<32, 4> replay("native-replay");
  const auto receipt = replay.request(9, open);
  for (const auto& record : captured.at("records")) {
    replay.append({record.at("device").get<std::uint64_t>(), record.at("timestamp").get<std::uint64_t>(),
                   record.at("value").get<std::int64_t>(), record.at("has_page").get<bool>(),
                   record.at("has_usage").get<bool>(), record.at("page").get<std::int32_t>(),
                   record.at("usage").get<std::int32_t>()});
  }
  json request{{"version", 1u}, {"action", "pull"}, {"incarnation", "native-replay"}, {"lease", receipt.at("lease")}};
  std::size_t index = 0;
  for (;;) {
    const auto response = json::parse(replay.request(9, request).dump());
    require(response.at("kind") == "batch");
    if (response.at("records").empty()) break;
    require(response.at("records").size() <= 4);
    for (const auto& record : response.at("records")) {
      const auto& original = captured.at("records").at(index++);
      require(record.at("sequence") == std::to_string(index));
      for (const auto* field : {"device", "timestamp"}) {
        require(record.at(field) == std::to_string(original.at(field).get<std::uint64_t>()));
      }
      require(record.at("value") == std::to_string(original.at("value").get<std::int64_t>()));
      for (const auto* field : {"has_page", "has_usage", "page", "usage"}) require(record.at(field) == original.at(field));
    }
    request["ack"] = response.at("records").back().at("sequence");
  }
  require(index == 20);
  std::puts("Protocol peer lifetime, precise integers, acknowledgements and loss passed");
}
