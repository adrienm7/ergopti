// tools/diagnostics/hs274-baseline-v2-test.cpp
// Independent multi-page state, strict type and complete row schema controls.
#include "hs274-stream-source.hpp"
#include "hs274-stream-baseline-client.hpp"
#include <iostream>

using hs274_stream_protocol::json;
using state = hs274_stream_protocol::key_state<8>;
using pages = hs274_stream_protocol::baseline_pages<2, 3, 8>;
using source = hs274_stream_protocol::source<8, 2, 3>;
using type = hs274_key_policy::keyboard_type;
std::size_t assertions = 0;
void require(bool condition) {
  ++assertions;
  if (!condition) throw std::runtime_error("Baseline-v2 independent assertion failed");
}
template <typename Callback> void rejects(Callback callback) {
  bool refused = false;
  try { callback(); } catch (const std::exception&) { refused = true; }
  require(refused);
}
template <typename Sample = state::sample> Sample sample(std::uint32_t page, std::uint32_t usage, std::uint32_t cookie, bool down) {
  return {page, usage, cookie, {true, false, true, 1, 32, 0, 1}, 0, true, cookie,
          down ? 1 : 0, 90, 100, 100};
}
hs274_raw_capture::record event(std::uint32_t page, std::uint32_t usage, std::uint32_t cookie,
                                 std::int64_t value, std::uint64_t timestamp) {
  return {41, timestamp, value, true, true, static_cast<std::int32_t>(page),
          static_cast<std::int32_t>(usage), 0, true, cookie};
}
void state_cases() {
  const state::sample samples[] = {sample(7, 44, 1, true), sample(12, 3, 2, true),
      sample(255, 3, 3, true), sample(65281, 3, 4, false), sample(7, 44, 5, false)};
  state owner(41);
  owner.initialize(samples, 5, true, false);
  require(owner.healthy() && owner.down(1) && owner.down(2) && owner.down(3) && !owner.down(4));
  require(owner.apply(event(12, 3, 2, 0, 80)) == state::action::covered_by_snapshot);
  require(owner.down(2));
  require(owner.apply(event(12, 3, 2, 0, 110)) == state::action::released);
  require(owner.apply(event(255, 3, 3, 0, 111)) == state::action::released);
  require(owner.apply(event(65281, 3, 4, 1, 112)) == state::action::pressed);
  require(owner.apply(event(7, 44, 5, 1, 113)) == state::action::pressed);
  require(owner.down(1) && owner.down(5));
  const auto frozen = owner.snapshot(113);
  require(frozen[1].page == 12 && frozen[1].timestamp == 110 && !frozen[1].down);
  require(frozen[3].page == 65281 && frozen[3].timestamp == 112 && frozen[3].down);
  require(owner.apply(event(12, 3, 2, 1, 109)) == state::action::invalid);
  rejects([&] { owner.snapshot(120); });
  for (const auto page : {7u, 12u, 255u, 65281u}) {
    state changed(41);
    const auto leaf = sample(page, page == 7 ? 44 : 3, 1, false);
    changed.initialize(&leaf, 1, true, false);
    auto value = event(page, page == 7 ? 44 : 3, 1, 1, 110);
    value.page = page == 7 ? 12 : 7;
    require(changed.apply(value) == state::action::invalid);
    state unknown(41);
    unknown.initialize(&leaf, 1, true, false);
    require(unknown.apply(event(page, page == 7 ? 44 : 3, 999, 1, 110)) == state::action::invalid);
  }
  state error(41);
  const auto invalid = sample(7, 3, 1, true);
  rejects([&] { error.initialize(&invalid, 1, true, false); });
}
void page_cases() {
  const std::vector<pages::element> keyboard{{7, 44, 1, 90, true}, {12, 3, 2, 95, true}};
  const std::vector<pages::element> consumer{{255, 3, 1, 96, true}, {65281, 3, 2, 97, true}};
  pages frozen(100, {{41, true, keyboard, type::iso}, {42, false, consumer, type::none}});
  require(frozen.size() == 6);
  const auto first = frozen.read(0);
  require(first.at("rows").at(0) == json({{"kind", "device"}, {"device", "41"},
      {"keyboard", true}, {"keyboard_type", "iso"}, {"elements", 2}}));
  require(first.at("rows").at(1) == json({{"kind", "key"}, {"device", "41"},
      {"page", 7}, {"usage", 44}, {"cookie", 1}, {"timestamp", "90"}, {"down", true}}));
  require(frozen.read(2).at("rows").at(0).at("page") == 12);
  require(frozen.read(2).at("rows").at(1).at("keyboard_type") == "none");
  require(frozen.read(4).at("rows").at(1).at("page") == 65281);
  for (const auto kind : {type::none, type::unavailable})
    rejects([&] { pages invalid(100, {{41, true, keyboard, kind}}); });
  rejects([&] { pages invalid(100, {{41, false, keyboard, type::none}}); });
  rejects([&] { pages invalid(100, {{41, true, consumer, type::ansi}}); });
  rejects([&] { pages invalid(100, {{41, false, consumer, type::ansi}}); });
}
void source_cases() {
  source owner("baseline-v2-diagnostic", [] { return 100; });
  rejects([&] { owner.attach(41, true); });
  auto keyboard = owner.attach(41, true, type::jis);
  const source::sample keys[] = {sample<source::sample>(7, 44, 1, true), sample<source::sample>(12, 3, 2, true)};
  require(keyboard.started(keys, 2, true, false));
  auto consumer = owner.attach(42, false, type::none);
  const source::sample aux[] = {sample<source::sample>(255, 3, 1, true), sample<source::sample>(65281, 3, 2, true)};
  require(consumer.started(aux, 2, true, false));
  const auto prepared = owner.request(7, {{"version", 1u}, {"action", "prepare"}});
  const auto opened = owner.request(7, {{"version", 1u}, {"action", "open"},
      {"incarnation", prepared.at("incarnation")}, {"preparation", prepared.at("preparation")}});
  require(opened.at("version") == 1u && opened.at("baseline").at("version") == 2u);
  require(opened.at("coverage") == "fixture_only");
  std::size_t cursor = 0, published = 0;
  hs274_stream_protocol::transfer_baseline<2>(opened, [&](const json& request) {
    return owner.request(7, request);
  }, [&](const json& row) {
    ++published;
    if (row.at("kind") == "baseline") cursor = row.at("next").get<std::size_t>();
  }, [&](const json& acknowledgement) {
    require(acknowledgement.at("baseline_ack") == std::to_string(cursor));
  });
  require(cursor == 6 && published == 4);
  auto old = opened;
  old["baseline"]["version"] = 1u;
  bool requested_old = false;
  rejects([&] { hs274_stream_protocol::transfer_baseline<2>(old,
      [&](const json&) -> json { requested_old = true; throw std::runtime_error("Must refuse before request"); },
      [](const json&) { throw std::runtime_error("Must not publish"); },
      [](const json&) { throw std::runtime_error("Must not acknowledge"); }); });
  require(!requested_old);
}
int main() {
  state_cases(); page_cases(); source_cases();
  std::cout << assertions << " independent baseline-v2 assertions passed\n";
}
