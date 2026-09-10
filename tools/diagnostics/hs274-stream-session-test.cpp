// tools/diagnostics/hs274-stream-session-test.cpp
// Behavioral coverage for the experimental physical-capture session owner.
#include "hs274-stream-session.hpp"
#include <cstdio>
#include <stdexcept>

void require(bool condition) {
  if (!condition) throw std::runtime_error("Session assertion failed");
}

template <typename Callback>
void rejects(Callback callback) {
  bool rejected = false;
  try { callback(); } catch (const std::logic_error&) { rejected = true; }
  require(rejected);
}

int main() {
  using session = hs274_stream::session<int, 3>;
  session owner;
  require(owner.append(99) == session::admission::inactive);
  rejects([&] { owner.acquire(0); });
  auto first = owner.acquire(7);
  rejects([&] { owner.acquire(8); });
  require(owner.read<2>(first).count == 0);
  rejects([&] { owner.acknowledge(first, 0); });
  require(owner.append(41) == session::admission::accepted);
  require(owner.append(44) == session::admission::accepted);
  auto batch = owner.read<2>(first);
  require(batch.count == 2 && batch.records[0].value == 41 && batch.records[1].value == 44);
  require(batch.records[0].sequence == 1 && batch.records[1].sequence == 2);
  rejects([&] { owner.read<2>(first); });
  rejects([&] { owner.acknowledge(first, 1); });
  rejects([&] { owner.acknowledge({8, first.lease}, 2); });
  require(owner.append(55) == session::admission::accepted);
  owner.acknowledge(first, 2);
  require(owner.append(66) == session::admission::accepted);
  batch = owner.read<2>(first);
  require(batch.count == 2 && batch.records[0].value == 55 && batch.records[1].value == 66);
  require(batch.records[0].sequence == 3 && batch.records[1].sequence == 4);
  owner.release(first);
  rejects([&] { owner.release(first); });
  require(owner.append(99) == session::admission::inactive);
  auto second = owner.acquire(7);
  require(second.lease != first.lease && owner.read<2>(second).count == 0);
  rejects([&] { owner.release(first); });
  rejects([&] { owner.acknowledge(first, 4); });
  rejects([&] { owner.read<2>(first); });
  for (int i = 0; i < 3; ++i) require(owner.append(i) == session::admission::accepted);
  require(owner.read<2>(second).count == 2);
  require(owner.append(3) == session::admission::lost);
  require(owner.status(second) == session::fault::overflow);
  rejects([&] { owner.acknowledge(second, 2); });
  rejects([&] { owner.read<2>(second); });
  require(owner.append(4) == session::admission::lost);
  owner.release(second);
  auto third = owner.acquire(8);
  require(owner.status(third) == session::fault::none && owner.read<1>(third).count == 0);

  require(owner.append(44) == session::admission::accepted);
  auto interrupted_batch = owner.read<1>(third);
  require(interrupted_batch.count == 1);
  owner.interrupt();
  owner.interrupt();
  require(owner.status(third) == session::fault::interrupted);
  rejects([&] { owner.acknowledge(third, interrupted_batch.records[0].sequence); });
  rejects([&] { owner.read<1>(third); });
  require(owner.append(55) == session::admission::lost);
  owner.release(third);
  owner.interrupt();
  auto fourth = owner.acquire(8);
  require(owner.status(fourth) == session::fault::none && owner.read<1>(fourth).count == 0);
  for (int i = 0; i < 4; ++i) owner.append(i);
  owner.interrupt();
  require(owner.status(fourth) == session::fault::overflow);
  owner.release(fourth);

  // Small serials exercise the same overflow guards without huge runs.
  using narrow_session = hs274_stream::session<int, 1, std::uint8_t>;
  narrow_session narrow;
  auto token = narrow.acquire(1);
  for (int i = 1; i <= 255; ++i) {
    require(narrow.append(i) == narrow_session::admission::accepted);
    auto item = narrow.read<1>(token);
    require(item.count == 1 && item.records[0].sequence == i && item.records[0].value == i);
    narrow.acknowledge(token, item.records[0].sequence);
  }
  require(narrow.append(256) == narrow_session::admission::lost);
  require(narrow.status(token) == narrow_session::fault::sequence_exhausted);
  narrow.release(token);
  for (int i = 2; i <= 255; ++i) {
    token = narrow.acquire(1);
    require(token.lease == i);
    narrow.release(token);
  }
  bool exhausted = false;
  try { narrow.acquire(1); } catch (const std::overflow_error&) { exhausted = true; }
  require(exhausted);
  std::puts("Session ownership, acknowledgement, wraparound, loss and exhaustion passed");
}
