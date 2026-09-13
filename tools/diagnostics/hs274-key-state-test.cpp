// tools/diagnostics/hs274-key-state-test.cpp
// Exercise sampled state, queued prefixes and genuine subsequent transitions.
#include "hs274-key-state.hpp"
#include "fixtures/hs274-inventory-sample.hpp"
#include <fstream>
#include <vector>

using state = hs274_stream_protocol::key_state<4>;
using action = state::action;
using fault = state::fault;

void require(bool value) {
  if (!value) throw std::runtime_error("Keyboard state assertion failed");
}

template <typename Callback>
void rejects(Callback callback) {
  bool rejected = false;
  try { callback(); } catch (const std::exception&) { rejected = true; }
  require(rejected);
}

state::sample sample(std::uint32_t usage, std::uint32_t cookie, bool down = false) {
  return {usage, cookie, {true, false, true, 1, 32, 0, 1}, 0, true, cookie,
          down ? 1 : 0, 100, 100, 100};
}

hs274_raw_capture::record event(std::uint32_t cookie, std::int64_t value, std::uint64_t at,
                               std::int32_t usage = 44, std::uint64_t device = 41) {
  return {device, at, value, true, true, 7, usage, 0, true, cookie};
}

void replay_native(const char* path, bool held) {
  std::ifstream input(path);
  require(input.good());
  nlohmann::json evidence;
  input >> evidence;
  std::vector<state::sample> samples;
  // These fixtures retain the referenced leaves. Full enumeration is tested
  // independently against the complete shared native inventory corpus.
  if (held) {
    samples.push_back(hs274_test::inventory_sample<state::sample>(evidence.at("held_inventory_element")));
  } else {
    for (const auto& row : evidence.at("referenced_keyboard_elements")) {
      samples.push_back(hs274_test::inventory_sample<state::sample>(row));
    }
  }
  const auto& rows = evidence.at("capture").at("records");
  state owner(rows.at(0).at("device").get<std::uint64_t>());
  owner.initialize(samples.data(), samples.size(), true, false);
  require(owner.down(109) == held);
  unsigned presses = 0, releases = 0;
  for (const auto& row : rows) {
    const auto usage = row.at("usage").get<std::int32_t>();
    if (row.at("page") != 7 || usage < 4 || usage > 255) continue;
    auto value = event(row.at("cookie").get<std::uint32_t>(), row.at("value").get<std::int64_t>(),
                       row.at("timestamp").get<std::uint64_t>(), usage, row.at("device").get<std::uint64_t>());
    value.has_cookie = row.at("has_cookie").get<bool>();
    const auto result = owner.apply(value);
    require(result == action::pressed || result == action::released);
    if (result == action::pressed) ++presses;
    if (result == action::released) ++releases;
  }
  require(owner.healthy() && !owner.down(109));
  require(presses == (held ? 1u : 2u) && releases == 2);
}

int main(int argc, char** argv) {
  require(argc == 3);
  replay_native(argv[1], false);
  replay_native(argv[2], true);
  rejects([] { state invalid(0); });
  const auto held = sample(44, 109, true);
  state owner(41);
  owner.initialize(&held, 1, true, false);
  rejects([&] { owner.initialize(&held, 1, true, false); });
  require(owner.down(109));
  require(owner.apply(event(109, 1, 80)) == action::covered_by_snapshot);
  require(owner.apply(event(109, 0, 90)) == action::covered_by_snapshot);
  require(owner.apply(event(109, 1, 100)) == action::covered_by_snapshot);
  require(owner.down(109));
  require(owner.apply(event(109, 0, 120)) == action::released);
  require(owner.apply(event(109, 1, 130)) == action::pressed);
  require(owner.apply(event(109, 1, 130)) == action::unchanged);
  require(owner.apply(event(109, 1, 140)) == action::unchanged);
  require(owner.apply(event(109, 0, 150)) == action::released);
  require(!owner.down(109));
  rejects([&] { owner.down(999); });

  const state::sample independent[] = {sample(224, 24), sample(224, 289)};
  state elements(41);
  elements.initialize(independent, 2, true, false);
  require(elements.apply(event(24, 1, 200, 224)) == action::pressed);
  // Device-wide timestamp order is not a per-element ordering guarantee.
  require(elements.apply(event(289, 1, 190, 224)) == action::pressed);
  require(elements.apply(event(24, 0, 210, 224)) == action::released);
  require(!elements.down(24) && elements.down(289));
  state other_device(42);
  const auto released = sample(44, 109);
  other_device.initialize(&released, 1, true, false);
  require(other_device.apply(event(109, 1, 120, 44, 42)) == action::pressed);
  require(other_device.down(109) && !owner.down(109));

  for (unsigned variant = 0; variant < 10; ++variant) {
    state invalid(41);
    invalid.initialize(&held, 1, true, false);
    auto value = event(109, 0, 120);
    auto expected = fault::element_identity;
    switch (variant) {
      case 0: value.has_cookie = false; break;
      case 1: value.cookie = 999; break;
      case 2: value.usage = 41; break;
      case 3: value.device = 42; expected = fault::device; break;
      case 4: value.value = 2; expected = fault::value; break;
      case 5: value.has_usage = false; break;
      case 6: value.usage = 256; break;
      case 7: value.timestamp = 100; expected = fault::chronology; break;
      case 8:
        require(invalid.apply(event(109, 0, 120)) == action::released);
        value = event(109, 1, 110); expected = fault::chronology; break;
      case 9:
        require(invalid.apply(event(109, 0, 120)) == action::released);
        value = event(109, 1, 120); expected = fault::chronology; break;
    }
    require(invalid.apply(value) == action::invalid && invalid.failure() == expected);
    require(!invalid.healthy());
    require(invalid.apply(event(109, 1, 200)) == action::invalid && invalid.failure() == expected);
    rejects([&] { invalid.down(109); });
    rejects([&] { invalid.initialize(&held, 1, true, false); });
  }
  state early(41);
  require(early.apply(event(109, 1, 120)) == action::invalid);
  rejects([&] { early.initialize(&held, 1, true, false); });
  auto observed = sample(44, 109);
  observed.started = 200;
  observed.finished = 210;
  for (const auto timestamp : {150u, 200u}) {
    state contradicted(41);
    contradicted.initialize(&observed, 1, true, false);
    require(contradicted.apply(event(109, 1, timestamp)) == action::invalid);
    require(contradicted.failure() == fault::chronology);
  }
  state during_query(41);
  during_query.initialize(&observed, 1, true, false);
  require(during_query.apply(event(109, 0, 100)) == action::covered_by_snapshot);
  require(during_query.apply(event(109, 1, 205)) == action::pressed);
  require(during_query.apply(event(109, 0, 220)) == action::released);
  for (const auto count : {0u, 5u}) {
    state invalid(41);
    rejects([&] { invalid.initialize(&held, count, true, false); });
    require(!invalid.healthy());
  }
  for (unsigned variant = 0; variant < 5; ++variant) {
    state invalid(41);
    auto value = held;
    if (variant == 0) value.status = -1;
    if (variant == 1) value.element.relative = true;
    rejects([&] { invalid.initialize(variant == 2 ? nullptr : &value, 1, variant != 3, variant == 4); });
    require(!invalid.healthy() && invalid.failure() == fault::initialization);
  }
  const state::sample error_keys[] = {sample(1, 66), sample(44, 109)};
  state errors(41);
  errors.initialize(error_keys, 2, true, false);
  require(errors.apply(event(66, 0, 120, 1)) == action::unchanged);
  require(errors.apply(event(0, 17, 130, -1)) == action::auxiliary);
  require(errors.apply(event(66, 1, 140, 1)) == action::invalid);
  require(errors.failure() == fault::hid_error);
  std::puts("Native state replay, queued prefixes, distinct cookies and explicit faults passed");
}
