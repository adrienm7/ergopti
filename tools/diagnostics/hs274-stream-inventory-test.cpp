// tools/diagnostics/hs274-stream-inventory-test.cpp
// Reject incomplete, duplicated and failed initial key observations.
#include "hs274-stream-inventory.hpp"
#include <stdexcept>

using inventory = hs274_stream_protocol::key_inventory<256>;

void require(bool value) {
  if (!value) throw std::runtime_error("Keyboard inventory assertion failed");
}

inventory::sample key(std::uint32_t usage) {
  return {usage, usage + 100, {true, false, true, 1, 6, 0, 1}, 0, true,
          usage + 100, 0, 0, usage * 2, usage * 2 + 1};
}

int main() {
  inventory all;
  for (std::uint32_t usage = 1; usage <= 255; ++usage) all.append(key(usage));
  require(all.finish(true, false));
  bool duplicate_finish = false;
  try { all.finish(true, false); } catch (const std::logic_error&) { duplicate_finish = true; }
  require(duplicate_finish);
  bool late_append = false;
  try { all.append(key(44)); } catch (const std::logic_error&) { late_append = true; }
  require(late_append);
  for (int variant = 0; variant < 15; ++variant) {
    inventory invalid;
    auto sample = key(44);
    switch (variant) {
      case 0: sample.status = -536870165; break;
      case 1: sample.returned_value = false; break;
      case 2: sample.value_cookie++; break;
      case 3: sample.value = 2; break;
      case 4: sample.timestamp = sample.finished + 1; break;
      case 5: sample.started = sample.finished + 1; break;
      case 6: sample.element.relative = true; break;
      case 7: sample.element.bits = 8; break;
      case 8: sample.element.input = false; break;
      case 9: sample.usage = 256; break;
      case 10: sample.usage = 0; break;
      case 11: sample.usage = 1; sample.value = 1; break;
      case 12: invalid.append(sample); break;
      case 13: invalid.append(key(45)); break;
      case 14: invalid.append(key(41)); sample.cookie = 141; sample.value_cookie = 141; break;
    }
    invalid.append(sample);
    require(!invalid.finish(true, false));
  }
  for (int variant = 0; variant < 3; ++variant) {
    inventory incomplete;
    if (variant != 0) incomplete.append(key(44));
    require(!incomplete.finish(variant != 1, variant == 2));
  }
  inventory held;
  auto space = key(44);
  space.value = 1;
  space.timestamp = 42;
  held.append(space);
  require(held.finish(true, false));
  inventory bounded;
  for (std::uint32_t usage = 1; usage <= 256; ++usage) bounded.append(key(usage));
  require(bounded.full());
  bool overflow = false;
  try { bounded.append(key(44)); } catch (const std::overflow_error&) { overflow = true; }
  require(overflow && !bounded.finish(true, true));
  hs274_stream_protocol::key_inventory<1> limited;
  const hs274_stream_protocol::key_inventory<1>::sample single{
      44, 144, {true, false, false, 1, 1, 0, 1}, 0, true, 144, 1, 42, 88, 89};
  limited.append(single);
  overflow = false;
  try { limited.append(single); } catch (const std::overflow_error&) { overflow = true; }
  require(overflow && !limited.finish(true, false));
}
