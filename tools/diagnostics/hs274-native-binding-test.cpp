// tools/diagnostics/hs274-native-binding-test.cpp
// Real SDK compilation and missing-object refusal, never native device correlation.
#include "hs274-stream-native-binding.hpp"
#include <cassert>
#include <cstdio>
#include <type_traits>
using binding = hs274_stream_protocol::native_binding;
static_assert(!std::is_copy_assignable_v<binding>);
static_assert(!std::is_constructible_v<binding, std::uint64_t, bool, hs274_key_policy::keyboard_type>);
static_assert(!std::is_default_constructible_v<binding>);
int main() {
  const binding missing(nullptr, 0);
  assert(missing.device() == 0);
  assert(!missing.keyboard());
  assert(missing.type() == hs274_key_policy::keyboard_type::unavailable);
  assert(missing.refusal() == hs274_stream_protocol::native_refusal::inventory_unavailable);
  assert(!missing.unchanged(nullptr, false));
  assert(!missing.unchanged(nullptr, true));
  const binding copied(missing);
  assert(copied.type() == hs274_key_policy::keyboard_type::unavailable);
  assert(copied.refusal() == hs274_stream_protocol::native_refusal::inventory_unavailable);
  assert(!copied.unchanged(nullptr, false));
  std::puts("PASS native binding missing-object controls assertions=9; native device correlation unexecuted");
}
