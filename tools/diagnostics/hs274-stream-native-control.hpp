// tools/diagnostics/hs274-stream-native-control.hpp
// Explicit refusal states, never a physical-coverage or permission grant.
#pragma once
#include "hs274-stream-key-policy.hpp"
#include <cstdint>
namespace hs274_stream_protocol {
enum class native_refusal : std::uint8_t {
  none, inventory_unavailable, identity_unavailable, identity_mismatch,
  keyboard_type_unavailable, changed_native_provenance
};
inline const char* refusal_name(native_refusal reason) noexcept {
  switch (reason) {
    case native_refusal::none: return "none";
    case native_refusal::inventory_unavailable: return "inventory_unavailable";
    case native_refusal::identity_unavailable: return "identity_unavailable";
    case native_refusal::identity_mismatch: return "identity_mismatch";
    case native_refusal::keyboard_type_unavailable: return "keyboard_type_unavailable";
    case native_refusal::changed_native_provenance: return "changed_native_provenance";
  }
  return "invalid_refusal";
}
} // namespace hs274_stream_protocol
