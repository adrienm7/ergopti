// tools/diagnostics/hs274-raw-capture-test.cpp
// Portable invariants for bounded pre-normalization observation.
#include "hs274-raw-capture.hpp"
#include <cassert>
#include <thread>

int main() {
  using namespace hs274_raw_capture;
  capture<2> small;
  small.append({10, 100, 1, true, true, 7, 41});
  const auto first = small.read();
  small.append({10, 90, 0, false, false, 0, 0});
  small.append({11, 110, 1, true, true, 7, 44});
  const auto full = small.read();
  assert(first.count == 1 && first.records[0].timestamp == 100);
  assert(full.count == 2 && full.seen == 3 && full.overflow == 1 && full.contention == 0);
  assert(full.records[1].timestamp == 90 && full.records[1].value == 0);
  assert(!full.records[1].has_page && !full.records[1].has_usage);
  assert(full.records[0].sequence == 1 && full.records[1].sequence == 2);

  record signed_metadata{10, 80, 0, true, true, 0, 0};
  signed_metadata.page = -1;
  signed_metadata.usage = -2;
  capture<1> signed_values;
  signed_values.append(signed_metadata);
  const auto signed_result = signed_values.read();
  assert(static_cast<std::int64_t>(signed_result.records[0].page) == -1);
  assert(static_cast<std::int64_t>(signed_result.records[0].usage) == -2);

  capture<128> concurrent;
  auto write = [&] {
    for (int i = 0; i < 10000; ++i) concurrent.append({12, 123, 1, true, true, 7, 44});
  };
  std::thread one(write), two(write);
  for (int i = 0; i < 1000; ++i) {
    const auto current = concurrent.read();
    for (std::size_t j = 0; j < current.count; ++j) {
      assert(current.records[j].sequence == j + 1);
      assert(current.records[j].device == 12 && current.records[j].timestamp == 123);
    }
  }
  one.join();
  two.join();
  const auto final = concurrent.read();
  assert(final.count == 128 && final.seen == 20000);
  assert(final.seen == final.count + final.overflow + final.contention);
  fixture.append({10, 100, 1, true, true, 7, 41});
  fixture.append({10, 90, 0, false, false, 0, 0});
  fixture.append(signed_metadata);
  assert(finish());
  std::puts("Bounded capture ordering, timestamps, metadata, overflow and publication passed.");
}
